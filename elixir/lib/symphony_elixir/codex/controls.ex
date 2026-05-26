defmodule SymphonyElixir.Codex.Controls do
  @moduledoc """
  Reads and updates operator-facing Codex model controls.
  """

  alias SymphonyElixir.{Config, Workflow, WorkflowStore}

  @reasoning_efforts ["low", "medium", "high", "xhigh"]
  @config_arg_regex ~r/(^|\s+)--config\s+(?:"((?:\\"|[^"])*)"|'([^']*)'|([^\s]+))/

  @type payload :: %{
          model: String.t() | nil,
          reasoning_effort: String.t() | nil,
          reasoning_effort_options: [String.t()],
          command: String.t(),
          workflow_path: Path.t()
        }

  @spec current() :: {:ok, payload()} | {:error, term()}
  def current do
    with {:ok, settings} <- Config.settings() do
      command = settings.codex.command

      {:ok,
       %{
         model: command_config_value(command, "model"),
         reasoning_effort: command_config_value(command, "model_reasoning_effort"),
         reasoning_effort_options: @reasoning_efforts,
         command: command,
         workflow_path: Workflow.workflow_file_path()
       }}
    end
  end

  @spec update(map()) :: {:ok, payload()} | {:error, term()}
  def update(attrs) when is_map(attrs) do
    with {:ok, current_payload} <- current(),
         {:ok, model} <- normalize_model(attr(attrs, :model, current_payload.model)),
         {:ok, reasoning_effort} <-
           normalize_reasoning_effort(attr(attrs, :reasoning_effort, current_payload.reasoning_effort)),
         {:ok, command} <- command_with_controls(current_payload.command, model, reasoning_effort),
         :ok <- update_workflow_command(command),
         :ok <- force_reload() do
      current()
    end
  end

  @spec error_message(term()) :: String.t()
  def error_message({:invalid_controls, message}), do: message
  def error_message({:unsupported_workflow_format, message}), do: message
  def error_message({:workflow_update_failed, reason}), do: "Unable to update WORKFLOW.md: #{inspect(reason)}"
  def error_message({:invalid_workflow_config, message}), do: "Invalid WORKFLOW.md config: #{message}"
  def error_message({:missing_workflow_file, path, reason}), do: "Missing WORKFLOW.md at #{path}: #{inspect(reason)}"
  def error_message(reason), do: "Unable to load agent controls: #{inspect(reason)}"

  defp attr(attrs, key, default) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, string_key) -> Map.get(attrs, string_key)
      true -> default
    end
  end

  defp normalize_model(nil), do: {:ok, nil}

  defp normalize_model(model) when is_binary(model) do
    model = String.trim(model)

    cond do
      model == "" ->
        {:ok, nil}

      String.match?(model, ~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/) ->
        {:ok, model}

      true ->
        {:error, {:invalid_controls, "Model must use letters, numbers, dots, dashes, colons, or underscores."}}
    end
  end

  defp normalize_model(_model), do: {:error, {:invalid_controls, "Model must be a string."}}

  defp normalize_reasoning_effort(nil), do: {:ok, nil}

  defp normalize_reasoning_effort(effort) when is_binary(effort) do
    effort = effort |> String.trim() |> String.downcase()

    cond do
      effort == "" -> {:ok, nil}
      effort in @reasoning_efforts -> {:ok, effort}
      true -> {:error, {:invalid_controls, "Reasoning effort must be one of: #{Enum.join(@reasoning_efforts, ", ")}."}}
    end
  end

  defp normalize_reasoning_effort(_effort), do: {:error, {:invalid_controls, "Reasoning effort must be a string."}}

  defp command_with_controls(command, model, reasoning_effort) do
    command =
      command
      |> remove_config_arg("model")
      |> remove_config_arg("model_reasoning_effort")
      |> compact_shell_spaces()

    control_args =
      [
        model && "--config #{shell_quote(~s(model="#{model}"))}",
        reasoning_effort && "--config model_reasoning_effort=#{reasoning_effort}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    cond do
      control_args == "" ->
        {:ok, compact_shell_spaces(command)}

      Regex.match?(~r/(^|\s+)app-server(?=\s|$)/, command) ->
        command =
          Regex.replace(~r/(^|\s+)app-server(?=\s|$)/, command, "\\1#{control_args} app-server", global: false)

        {:ok, String.trim(command)}

      true ->
        {:error, {:invalid_controls, "codex.command must contain app-server."}}
    end
  end

  defp command_config_value(command, key) when is_binary(command) do
    command
    |> config_args()
    |> Enum.find_value(fn token ->
      case String.split(token, "=", parts: 2) do
        [^key, value] -> normalize_config_value(value)
        _ -> nil
      end
    end)
  end

  defp config_args(command) do
    @config_arg_regex
    |> Regex.scan(command)
    |> Enum.map(&config_arg_token/1)
  end

  defp config_arg_token(captures) do
    double_quoted = capture_at(captures, 2)
    single_quoted = capture_at(captures, 3)
    raw = capture_at(captures, 4)

    (single_quoted != "" && single_quoted) ||
      (double_quoted != "" && unescape_double_quoted(double_quoted)) ||
      raw
  end

  defp capture_at(captures, index), do: Enum.at(captures, index, "")

  defp normalize_config_value(value) do
    value
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
  end

  defp remove_config_arg(command, key) do
    Regex.replace(@config_arg_regex, command, fn full, leading, double_quoted, single_quoted, raw ->
      token =
        (single_quoted != "" && single_quoted) ||
          (double_quoted != "" && unescape_double_quoted(double_quoted)) ||
          raw

      case String.split(token, "=", parts: 2) do
        [^key, _value] -> leading
        _ -> full
      end
    end)
  end

  defp compact_shell_spaces(command) do
    {chars, _single_quoted, _double_quoted, _space} =
      command
      |> String.graphemes()
      |> Enum.reduce({[], false, false, false}, &compact_shell_space/2)

    chars
    |> Enum.reverse()
    |> Enum.join()
    |> String.trim()
  end

  defp compact_shell_space("'", {chars, false, false, _space}),
    do: {["'" | chars], true, false, false}

  defp compact_shell_space("'", {chars, true, false, _space}),
    do: {["'" | chars], false, false, false}

  defp compact_shell_space("\"", {chars, false, false, _space}),
    do: {["\"" | chars], false, true, false}

  defp compact_shell_space("\"", {chars, false, true, _space}),
    do: {["\"" | chars], false, false, false}

  defp compact_shell_space(char, {chars, false, false, true}) when char in [" ", "\t", "\n", "\r"],
    do: {chars, false, false, true}

  defp compact_shell_space(char, {chars, false, false, false}) when char in [" ", "\t", "\n", "\r"],
    do: {[" " | chars], false, false, true}

  defp compact_shell_space(char, {chars, single_quoted, double_quoted, _space}),
    do: {[char | chars], single_quoted, double_quoted, false}

  defp update_workflow_command(command) do
    path = Workflow.workflow_file_path()

    with {:ok, content} <- File.read(path),
         {:ok, updated_content} <- put_workflow_command(content, command) do
      case File.write(path, updated_content) do
        :ok -> :ok
        {:error, reason} -> {:error, {:workflow_update_failed, reason}}
      end
    else
      {:error, %File.Error{} = error} -> {:error, {:workflow_update_failed, error.reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_workflow_command(content, command) do
    with {:ok, front_matter, body} <- split_workflow(content),
         {:ok, front_matter} <- put_front_matter_command(front_matter, command) do
      {:ok, Enum.join(["---" | front_matter] ++ ["---" | body], "\n")}
    end
  end

  defp split_workflow(content) do
    case String.split(content, "\n", trim: false) do
      ["---" | tail] ->
        {front_matter, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | body] -> {:ok, front_matter, body}
          _ -> {:error, {:unsupported_workflow_format, "WORKFLOW.md front matter is missing a closing --- line."}}
        end

      _ ->
        {:error, {:unsupported_workflow_format, "WORKFLOW.md must start with YAML front matter."}}
    end
  end

  defp put_front_matter_command(lines, command) do
    case codex_section_range(lines) do
      nil ->
        {:ok, lines ++ ["codex:", command_line(command)]}

      {section_index, next_section_index} ->
        replace_or_insert_command(lines, section_index, next_section_index, command)
    end
  end

  defp codex_section_range(lines) do
    lines
    |> Enum.find_index(&Regex.match?(~r/^codex:\s*(?:#.*)?$/, &1))
    |> codex_section_range(lines)
  end

  defp codex_section_range(nil, _lines), do: nil

  defp codex_section_range(section_index, lines) do
    {section_index, next_top_level_section_index(lines, section_index)}
  end

  defp next_top_level_section_index(lines, section_index) do
    lines
    |> Enum.with_index()
    |> Enum.find_value(length(lines), fn {line, index} ->
      if top_level_section_after?(line, index, section_index), do: index
    end)
  end

  defp top_level_section_after?(line, index, section_index) do
    index > section_index and Regex.match?(~r/^\S[^:]*:\s*/, line)
  end

  defp replace_or_insert_command(lines, section_index, next_section_index, command) do
    command_index =
      lines
      |> Enum.with_index()
      |> Enum.find_value(fn {line, index} ->
        if index > section_index and index < next_section_index and Regex.match?(~r/^\s+command:\s*/, line) do
          index
        end
      end)

    cond do
      is_nil(command_index) ->
        {:ok, List.insert_at(lines, section_index + 1, command_line(command))}

      multiline_command?(Enum.at(lines, command_index)) ->
        {:error, {:unsupported_workflow_format, "codex.command must be a single-line YAML value."}}

      true ->
        {:ok, List.replace_at(lines, command_index, command_line(command, command_indent(Enum.at(lines, command_index))))}
    end
  end

  defp command_line(command, indent \\ "  ") do
    "#{indent}command: #{yaml_string(command)}"
  end

  defp command_indent(line) do
    case Regex.run(~r/^(\s*)command:/, line) do
      [_, indent] -> indent
      _ -> "  "
    end
  end

  defp multiline_command?(line), do: Regex.match?(~r/^\s+command:\s*[|>]/, line)

  defp yaml_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp unescape_double_quoted(value) do
    String.replace(value, "\\\"", "\"")
  end

  defp force_reload do
    case WorkflowStore.force_reload() do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
