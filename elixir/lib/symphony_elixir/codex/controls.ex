defmodule SymphonyElixir.Codex.Controls do
  @moduledoc """
  Reads and updates operator-facing Symphony controls.
  """

  alias SymphonyElixir.{Config, Workflow, WorkflowStore}

  @type payload :: %{
          selected_repository_id: String.t() | nil,
          repository_options: [map()],
          command: String.t(),
          workflow_path: Path.t()
        }

  @spec current() :: {:ok, payload()} | {:error, term()}
  def current do
    with {:ok, settings} <- Config.settings() do
      {:ok,
       %{
         selected_repository_id: settings.repositories.selected,
         repository_options: Config.repository_options(settings),
         command: settings.codex.command,
         workflow_path: Workflow.workflow_file_path()
       }}
    end
  end

  @spec update(map()) :: {:ok, payload()} | {:error, term()}
  def update(attrs) when is_map(attrs) do
    with {:ok, current_payload} <- current(),
         {:ok, repository_id} <-
           normalize_repository_id(
             attr(attrs, :repository_id, current_payload.selected_repository_id),
             current_payload.repository_options
           ),
         :ok <- update_workflow_repository(repository_id),
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

  defp normalize_repository_id(_repository_id, []), do: {:ok, nil}

  defp normalize_repository_id(repository_id, repository_options) when is_list(repository_options) do
    repository_id = repository_id && String.trim(to_string(repository_id))
    allowed_ids = Enum.map(repository_options, & &1.id)

    cond do
      is_nil(repository_id) or repository_id == "" ->
        {:error, {:invalid_controls, "Repository is required."}}

      repository_id in allowed_ids ->
        {:ok, repository_id}

      true ->
        {:error, {:invalid_controls, "Repository must be one of: #{Enum.join(allowed_ids, ", ")}."}}
    end
  end

  defp update_workflow_repository(nil), do: :ok

  defp update_workflow_repository(repository_id) do
    path = Workflow.workflow_file_path()

    with {:ok, content} <- File.read(path),
         {:ok, updated_content} <- put_workflow_repository(content, repository_id) do
      case File.write(path, updated_content) do
        :ok -> :ok
        {:error, reason} -> {:error, {:workflow_update_failed, reason}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_workflow_repository(content, repository_id) do
    with {:ok, front_matter, body} <- split_workflow(content),
         {:ok, front_matter} <- put_front_matter_repository(front_matter, repository_id) do
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

  defp put_front_matter_repository(lines, repository_id) do
    case repositories_section_range(lines) do
      nil ->
        {:ok, lines ++ ["repositories:", selected_repository_line(repository_id)]}

      {section_index, next_section_index} ->
        replace_or_insert_selected_repository(lines, section_index, next_section_index, repository_id)
    end
  end

  defp repositories_section_range(lines) do
    lines
    |> Enum.find_index(&Regex.match?(~r/^repositories:\s*(?:#.*)?$/, &1))
    |> section_range(lines)
  end

  defp section_range(nil, _lines), do: nil

  defp section_range(section_index, lines) do
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

  defp replace_or_insert_selected_repository(lines, section_index, next_section_index, repository_id) do
    selected_index =
      lines
      |> Enum.with_index()
      |> Enum.find_value(fn {line, index} ->
        if index > section_index and index < next_section_index and Regex.match?(~r/^\s+selected:\s*/, line) do
          index
        end
      end)

    cond do
      is_nil(selected_index) ->
        {:ok, List.insert_at(lines, section_index + 1, selected_repository_line(repository_id))}

      multiline_selected_repository?(Enum.at(lines, selected_index)) ->
        {:error, {:unsupported_workflow_format, "repositories.selected must be a single-line YAML value."}}

      true ->
        {:ok,
         List.replace_at(
           lines,
           selected_index,
           selected_repository_line(repository_id, selected_repository_indent(Enum.at(lines, selected_index)))
         )}
    end
  end

  defp selected_repository_line(repository_id, indent \\ "  ") do
    "#{indent}selected: #{yaml_string(repository_id)}"
  end

  defp selected_repository_indent(line) do
    case Regex.run(~r/^(\s*)selected:/, line) do
      [_, indent] -> indent
      _ -> "  "
    end
  end

  defp multiline_selected_repository?(line), do: Regex.match?(~r/^\s+selected:\s*[|>]/, line)

  defp yaml_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end

  defp force_reload do
    case WorkflowStore.force_reload() do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
