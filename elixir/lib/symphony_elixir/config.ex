defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec selected_repository() :: struct() | nil
  def selected_repository do
    settings!()
    |> selected_repository()
  end

  @spec selected_repository(Schema.t()) :: struct() | nil
  def selected_repository(%Schema{} = settings) do
    Schema.selected_repository(settings.repositories)
  end

  @spec repository_options() :: [map()]
  def repository_options do
    settings!()
    |> repository_options()
  end

  @spec repository_options(Schema.t()) :: [map()]
  def repository_options(%Schema{} = settings) do
    settings.repositories.allowed
    |> Enum.map(fn repo ->
      %{
        id: repo.id,
        name: repo.name || repo.id,
        url: repo.url,
        selected: repo.id == settings.repositories.selected
      }
    end)
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  @spec codex_command_for_tool_surface(String.t(), atom() | String.t() | nil) :: String.t()
  def codex_command_for_tool_surface(command, surface) when is_binary(command) do
    flags =
      settings!()
      |> then(&tool_allowlist_flags(&1.codex.tool_allowlist, surface))

    insert_command_flags(command, flags)
  end

  @spec ponytail_policy() :: map()
  def ponytail_policy do
    settings!().agent.ponytail
    |> normalize_ponytail_policy()
  end

  defp validate_semantics(settings) do
    case validate_repository_selection(settings) do
      :ok -> validate_tracker_semantics(settings)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_tracker_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not linear_auth_configured?(settings.tracker) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        :ok
    end
  end

  defp validate_repository_selection(%Schema{} = settings) do
    repositories = settings.repositories
    allowed = repositories.allowed
    selected_repository = selected_repository(settings)

    cond do
      allowed == [] ->
        :ok

      not is_binary(repositories.selected) ->
        {:error, :missing_selected_repository}

      is_nil(selected_repository) ->
        {:error, {:unknown_selected_repository, repositories.selected}}

      missing_repository_url?(selected_repository) ->
        {:error, {:invalid_repository, repositories.selected, :missing_url}}

      duplicate_repository_ids?(allowed) ->
        {:error, :duplicate_repository_ids}

      true ->
        :ok
    end
  end

  defp missing_repository_url?(repository), do: repository.url in [nil, ""]

  defp duplicate_repository_ids?(repositories) do
    ids = Enum.map(repositories, & &1.id)
    ids != Enum.uniq(ids)
  end

  defp linear_auth_configured?(tracker) do
    is_binary(tracker.api_key) or is_binary(tracker.oauth_access_token)
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end

  defp tool_allowlist_flags(allowlist, surface) when is_map(allowlist) do
    surface_config =
      allowlist
      |> map_get("surfaces")
      |> case do
        %{} = surfaces -> map_get(surfaces, surface_name(surface)) || %{}
        _ -> %{}
      end

    allowed_mcp = normalize_allowlist_map(map_get(surface_config, "mcp_servers"))
    allowed_plugins = normalize_allowlist_map(map_get(surface_config, "plugins"))

    mcp_disable_flags(map_get(allowlist, "mcp_server_blocklist"), allowed_mcp) ++
      mcp_enable_flags(allowed_mcp) ++
      plugin_flags(map_get(allowlist, "plugin_blocklist"), allowed_plugins)
  end

  defp tool_allowlist_flags(_allowlist, _surface), do: []

  defp mcp_disable_flags(blocklist, allowed) do
    blocklist
    |> normalize_string_list()
    |> Enum.reject(&Map.has_key?(allowed, &1))
    |> Enum.map(&config_flag("mcp_servers.#{&1}.enabled=false"))
  end

  defp mcp_enable_flags(allowed) do
    Enum.map(allowed, fn
      {server, %{} = config} ->
        config_flag("mcp_servers.#{server}=#{toml_value(Map.put(config, "enabled", true))}")

      {server, true} ->
        config_flag("mcp_servers.#{server}.enabled=true")

      {server, _value} ->
        config_flag("mcp_servers.#{server}.enabled=true")
    end)
  end

  defp plugin_flags(blocklist, allowed) do
    cond do
      map_size(allowed) > 0 ->
        [config_flag("features.plugins=true")] ++
          (blocklist
           |> normalize_string_list()
           |> Enum.reject(&Map.has_key?(allowed, &1))
           |> Enum.map(&config_flag("plugins.#{toml_quoted_key(&1)}.enabled=false"))) ++
          Enum.map(allowed, fn {plugin, _value} -> config_flag("plugins.#{toml_quoted_key(plugin)}.enabled=true") end)

      normalize_string_list(blocklist) != [] ->
        [config_flag("features.plugins=false")]

      true ->
        []
    end
  end

  defp normalize_allowlist_map(nil), do: %{}

  defp normalize_allowlist_map(values) when is_list(values) do
    values
    |> normalize_string_list()
    |> Map.new(&{&1, true})
  end

  defp normalize_allowlist_map(values) when is_map(values) do
    Map.new(values, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_allowlist_map(_values), do: %{}

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&(to_string(&1) |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_string_list(_values), do: []

  defp surface_name(nil), do: "root"
  defp surface_name(surface) when is_atom(surface), do: surface |> Atom.to_string() |> String.trim()
  defp surface_name(surface), do: surface |> to_string() |> String.trim()

  defp insert_command_flags(command, []), do: command

  defp insert_command_flags(command, flags) do
    flag_text = Enum.join(flags, " ")

    case Regex.run(~r/^(.*?)(\s+app-server\s*)$/, command) do
      [_, prefix, suffix] -> String.trim_trailing(prefix) <> " " <> flag_text <> suffix
      _ -> command <> " " <> flag_text
    end
  end

  defp config_flag(config), do: "--config #{shell_quote(config)}"

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp toml_value(value) when is_binary(value), do: Jason.encode!(value)
  defp toml_value(value) when is_boolean(value), do: to_string(value)
  defp toml_value(value) when is_integer(value) or is_float(value), do: to_string(value)

  defp toml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &toml_value/1) <> "]"
  end

  defp toml_value(values) when is_map(values) do
    "{ " <>
      Enum.map_join(values, ", ", fn {key, value} -> "#{toml_key(key)} = #{toml_value(value)}" end) <> " }"
  end

  defp toml_value(value), do: value |> to_string() |> toml_value()

  defp toml_key(key) do
    key = to_string(key)
    if Regex.match?(~r/^[A-Za-z0-9_-]+$/, key), do: key, else: toml_quoted_key(key)
  end

  defp toml_quoted_key(key), do: Jason.encode!(to_string(key))

  defp map_get(%{} = map, key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp map_get(_map, _key), do: nil

  defp normalize_ponytail_policy(nil), do: %{"enabled" => true, "mode" => "full", "cohort" => "ponytail:full"}

  defp normalize_ponytail_policy(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      mode when mode in ["off", "false", "disabled", "none"] ->
        %{"enabled" => false, "mode" => "off", "cohort" => "ponytail:off"}

      mode when mode in ["lite", "full", "ultra"] ->
        %{"enabled" => true, "mode" => mode, "cohort" => "ponytail:#{mode}"}

      _ ->
        %{"enabled" => true, "mode" => "full", "cohort" => "ponytail:full"}
    end
  end

  defp normalize_ponytail_policy(%{} = value) do
    enabled = map_get(value, "enabled")
    mode = map_get(value, "mode") || map_get(value, "level") || "full"
    cohort = map_get(value, "cohort")

    policy = normalize_ponytail_policy(to_string(mode))
    policy = Map.put(policy, "enabled", enabled_value(enabled, policy["enabled"]))

    policy
    |> Map.put("cohort", normalize_ponytail_cohort(cohort, policy))
  end

  defp normalize_ponytail_policy(_value), do: normalize_ponytail_policy(nil)

  defp enabled_value(nil, default), do: default

  defp enabled_value(value, _default)
       when value in [false, "false", "False", "off", "Off", "disabled", "Disabled", "0"],
       do: false

  defp enabled_value(_value, _default), do: true

  defp normalize_ponytail_cohort(cohort, _policy) when is_binary(cohort) and cohort != "", do: cohort
  defp normalize_ponytail_cohort(_cohort, %{"enabled" => false}), do: "ponytail:off"
  defp normalize_ponytail_cohort(_cohort, %{"mode" => mode}), do: "ponytail:#{mode}"
end
