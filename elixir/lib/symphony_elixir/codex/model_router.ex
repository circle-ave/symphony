defmodule SymphonyElixir.Codex.ModelRouter do
  @moduledoc """
  Chooses the Codex launch command for a root agent session.
  """

  require Logger

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue}

  @read_only_turn_sandbox %{
    "type" => "readOnly",
    "networkAccess" => true
  }

  @type route :: %{
          profile: String.t(),
          command: String.t(),
          reason: String.t() | nil,
          confidence: number() | nil,
          source: :default | :router | :fallback
        }

  @spec route(Issue.t(), Path.t(), keyword()) :: {:ok, route()}
  def route(%Issue{} = issue, workspace, opts \\ []) when is_binary(workspace) do
    settings = Config.settings!()
    router_config = settings.codex.model_router || %{}
    profiles = profiles(router_config)
    default_route = default_route(settings, router_config, profiles)

    if router_enabled?(router_config) and map_size(profiles) > 0 do
      route_with_model(issue, workspace, opts, router_config, profiles, default_route)
    else
      {:ok, default_route}
    end
  end

  @doc false
  @spec route_for_test(Issue.t(), Path.t(), keyword()) :: {:ok, route()}
  def route_for_test(%Issue{} = issue, workspace, opts), do: route(issue, workspace, opts)

  defp route_with_model(issue, workspace, opts, router_config, profiles, default_route) do
    prompt = router_prompt(issue, opts, router_config, profiles, default_route)
    turn_runner = Keyword.get(opts, :turn_runner, &run_router_turn/4)
    worker_host = Keyword.get(opts, :worker_host)

    runner_opts = [
      command: router_command(router_config, default_route.command),
      worker_host: worker_host,
      approval_policy: router_approval_policy(router_config),
      thread_sandbox: router_thread_sandbox(router_config),
      turn_sandbox_policy: router_turn_sandbox_policy(router_config)
    ]

    case turn_runner.(workspace, prompt, issue, runner_opts) do
      {:ok, output} ->
        route_from_output(output, profiles, default_route)

      {:error, reason} ->
        Logger.warning("Model router failed for #{issue_context(issue)}: #{inspect(reason)}")
        {:ok, fallback_route(default_route, "model router failed: #{inspect(reason)}")}
    end
  end

  defp route_from_output(output, profiles, default_route) when is_binary(output) do
    with {:ok, decision} <- decode_router_decision(output),
         profile_id when is_binary(profile_id) <- decision_profile(decision),
         %{command: command} = profile <- Map.get(profiles, profile_id) do
      {:ok,
       %{
         profile: profile.id,
         command: command,
         reason: decision_reason(decision) || profile.description,
         confidence: decision_confidence(decision),
         source: :router
       }}
    else
      _ ->
        {:ok, fallback_route(default_route, "model router returned no usable profile")}
    end
  end

  defp route_from_output(_output, _profiles, default_route) do
    {:ok, fallback_route(default_route, "model router returned no text")}
  end

  defp run_router_turn(workspace, prompt, issue, opts) do
    ref = make_ref()
    parent = self()

    on_message = fn message ->
      send(parent, {ref, message})
    end

    opts = Keyword.put(opts, :on_message, on_message)
    opts = Keyword.put(opts, :tool_executor, &reject_router_tool_call/2)

    with {:ok, session} <- AppServer.start_session(workspace, opts) do
      try do
        case AppServer.run_turn(session, prompt, issue, opts) do
          {:ok, _result} ->
            {:ok, router_output(ref)}

          {:error, reason} ->
            {:error, reason}
        end
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp reject_router_tool_call(tool, _arguments) do
    %{
      "success" => false,
      "output" => "Model routing is classification-only; tool #{inspect(tool)} is unavailable."
    }
  end

  defp router_output(ref) do
    ref
    |> drain_router_messages([])
    |> Enum.flat_map(&message_text_parts/1)
    |> Enum.join("")
  end

  defp drain_router_messages(ref, acc) do
    receive do
      {^ref, message} -> drain_router_messages(ref, [message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp router_prompt(issue, opts, router_config, profiles, default_route) do
    profile_lines =
      profiles
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map_join("\n", fn profile ->
        "- #{profile.id}: #{profile.description || "No description provided."}"
      end)

    labels = Enum.join(issue.labels || [], ", ")
    blockers = Enum.map_join(issue.blocked_by || [], ", ", &blocker_label/1)

    """
    You are Symphony's model router. Pick the least expensive model profile that is still likely to complete the root agent session well.

    Return JSON only, with this shape:
    {"profile":"#{default_route.profile}","confidence":0.0,"reason":"short rationale"}

    Valid profiles:
    #{profile_lines}

    Cascade guidance:
    - Use the highest-capability profile when the ticket is ambiguous, high-risk, customer-facing, security-sensitive, cross-cutting, blocked by prior failed attempts, or likely to need architecture judgment.
    - Use a lower-cost profile only for clearly mechanical changes, small docs/config edits, or narrow test updates.
    - Retry attempts, rework states, review comments, stale acceptance evidence, migrations, production incidents, and broad refactors should usually escalate.
    - If uncertain, choose a more capable profile.

    Runtime signals:
    - Attempt: #{Keyword.get(opts, :attempt) || 0}
    - Comment reply mode: #{Keyword.get(opts, :comment_reply, false)}
    - Default profile: #{default_route.profile}
    - Router note: #{map_get(router_config, "note") || "none"}

    Issue:
    - Identifier: #{issue.identifier}
    - Title: #{issue.title}
    - State: #{issue.state}
    - Priority: #{inspect(issue.priority)}
    - Labels: #{labels}
    - Blocked by: #{blockers}
    - URL: #{issue.url}

    Description:
    #{issue.description || "No description provided."}
    """
  end

  defp decode_router_decision(output) do
    output
    |> json_candidates()
    |> Enum.find_value(fn candidate ->
      case Jason.decode(candidate) do
        {:ok, %{} = decoded} -> {:ok, decoded}
        _ -> nil
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, decoded}
      nil -> {:error, :no_json_decision}
    end
  end

  defp json_candidates(output) when is_binary(output) do
    trimmed = String.trim(output)
    fenced = Regex.scan(~r/```(?:json)?\s*(\{.*?\})\s*```/s, output, capture: :all_but_first)

    [
      [trimmed],
      List.flatten(fenced),
      json_object_slice(trimmed),
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(String.starts_with?(&1, "{") and String.ends_with?(&1, "}")))
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp json_object_slice(output) do
    with {start, _} <- :binary.match(output, "{"),
         {last_start, _} <- output |> :binary.matches("}") |> List.last() do
      [String.slice(output, start, last_start - start + 1)]
    else
      _ -> []
    end
  end

  defp message_text_parts(%{payload: payload}), do: text_parts(payload)
  defp message_text_parts(%{raw: raw}) when is_binary(raw), do: raw_text_parts(raw)
  defp message_text_parts(%{"payload" => payload}), do: text_parts(payload)
  defp message_text_parts(%{"raw" => raw}) when is_binary(raw), do: raw_text_parts(raw)
  defp message_text_parts(message) when is_map(message), do: text_parts(message)
  defp message_text_parts(_message), do: []

  defp raw_text_parts(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> text_parts(decoded)
      _ -> []
    end
  end

  defp text_parts(payload) when is_map(payload) do
    text_paths()
    |> Enum.flat_map(fn path -> content_text(map_path(payload, path)) end)
  end

  defp text_parts(_payload), do: []

  defp text_paths do
    [
      ["params", "msg", "textDelta"],
      ["params", "msg", "text"],
      ["params", "msg", "message"],
      ["params", "msg", "content"],
      ["params", "msg", "payload", "textDelta"],
      ["params", "msg", "payload", "text"],
      ["params", "msg", "payload", "message"],
      ["params", "msg", "payload", "content"],
      ["params", "item", "content"],
      ["params", "textDelta"],
      ["params", "text"],
      ["params", "message"],
      ["params", "content"],
      ["textDelta"],
      ["text"],
      ["message"],
      ["content"]
    ]
  end

  defp content_text(value) when is_binary(value), do: [value]
  defp content_text(values) when is_list(values), do: Enum.flat_map(values, &content_text/1)

  defp content_text(%{} = value) do
    ["text", "message", "content", "summary"]
    |> Enum.flat_map(fn key -> content_text(map_get(value, key)) end)
  end

  defp content_text(_value), do: []

  defp profiles(%{} = router_config) do
    router_config
    |> map_get("profiles")
    |> normalize_profiles()
  end

  defp profiles(_router_config), do: %{}

  defp normalize_profiles(profiles) when is_map(profiles) do
    profiles
    |> Enum.flat_map(fn {id, value} ->
      case normalize_profile(to_string(id), value) do
        nil -> []
        profile -> [{profile.id, profile}]
      end
    end)
    |> Map.new()
  end

  defp normalize_profiles(_profiles), do: %{}

  defp normalize_profile(id, command) when is_binary(command) do
    %{id: id, command: command, description: nil}
  end

  defp normalize_profile(id, %{} = attrs) do
    case map_get(attrs, "command") do
      command when is_binary(command) and command != "" ->
        %{id: id, command: command, description: map_get(attrs, "description")}

      _ ->
        nil
    end
  end

  defp normalize_profile(_id, _attrs), do: nil

  defp default_route(settings, router_config, profiles) do
    profile_id =
      map_get(router_config, "default_profile") ||
        map_get(router_config, "fallback_profile") ||
        "default"

    profile =
      Map.get(profiles, profile_id) ||
        Map.get(profiles, "default") ||
        profiles |> Map.values() |> List.first()

    if profile do
      %{
        profile: profile.id,
        command: profile.command,
        reason: profile.description,
        confidence: nil,
        source: :default
      }
    else
      %{
        profile: "default",
        command: settings.codex.command,
        reason: "model router disabled or has no valid profiles",
        confidence: nil,
        source: :default
      }
    end
  end

  defp fallback_route(default_route, reason) do
    %{default_route | reason: reason, confidence: nil, source: :fallback}
  end

  defp router_enabled?(%{} = router_config), do: truthy?(map_get(router_config, "enabled"))
  defp router_enabled?(_router_config), do: false

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_value), do: false

  defp router_command(router_config, default_command) do
    case map_get(router_config, "router_command") || map_get(router_config, "command") do
      command when is_binary(command) and command != "" -> command
      _ -> default_command
    end
  end

  defp router_approval_policy(router_config) do
    map_get(router_config, "approval_policy") || "never"
  end

  defp router_thread_sandbox(router_config) do
    map_get(router_config, "thread_sandbox")
  end

  defp router_turn_sandbox_policy(router_config) do
    case map_get(router_config, "turn_sandbox_policy") do
      %{} = policy -> policy
      _ -> @read_only_turn_sandbox
    end
  end

  defp decision_profile(decision) do
    map_get(decision, "profile") ||
      map_get(decision, "profile_id") ||
      map_get(decision, "model_profile")
  end

  defp decision_reason(decision) do
    case map_get(decision, "reason") || map_get(decision, "rationale") do
      reason when is_binary(reason) and reason != "" -> reason
      _ -> nil
    end
  end

  defp decision_confidence(decision) do
    case map_get(decision, "confidence") do
      confidence when is_number(confidence) -> confidence
      _ -> nil
    end
  end

  defp blocker_label(%{identifier: identifier, state: state}) do
    "#{identifier || "unknown"}:#{state || "unknown"}"
  end

  defp blocker_label(blocker), do: inspect(blocker)

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp map_path(value, []), do: value

  defp map_path(%{} = map, [key | rest]) do
    map
    |> map_get(key)
    |> map_path(rest)
  end

  defp map_path(_value, _path), do: nil

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(to_string(key)))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp map_get(_map, _key), do: nil
end
