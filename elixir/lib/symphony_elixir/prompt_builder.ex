defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
    |> maybe_append_resume_checkpoint(Keyword.get(opts, :resume_checkpoint))
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end

  defp maybe_append_resume_checkpoint(prompt, nil), do: prompt

  defp maybe_append_resume_checkpoint(prompt, checkpoint) when is_map(checkpoint) do
    prompt <> "\n\n" <> resume_checkpoint_prompt(checkpoint)
  end

  defp maybe_append_resume_checkpoint(prompt, _checkpoint), do: prompt

  defp resume_checkpoint_prompt(checkpoint) do
    issue = checkpoint_get(checkpoint, "issue") || %{}
    session = checkpoint_get(checkpoint, "session") || %{}
    codex = checkpoint_get(checkpoint, "codex") || %{}

    stream_lines =
      codex
      |> checkpoint_get("stream_window")
      |> resume_stream_lines()

    """
    Symphony resume checkpoint:

    - This issue was frozen for an operator restart at #{checkpoint_get(checkpoint, "frozen_at") || "unknown"}.
    - Resume from the preserved workspace and workpad state. Do not restart from scratch.
    - Checkpoint file: #{checkpoint_get(checkpoint, "path") || "n/a"}
    - Issue: #{checkpoint_get(issue, "identifier") || "unknown"} / #{checkpoint_get(issue, "state") || "unknown"}
    - Previous session: #{checkpoint_get(session, "session_id") || "unknown"}; turns completed: #{checkpoint_get(session, "turn_count") || 0}.
    - Last observed activity: #{checkpoint_get(codex, "last_message") || "n/a"}
    #{stream_lines}
    """
    |> String.trim_trailing()
  end

  defp resume_stream_lines(stream_window) when is_list(stream_window) and stream_window != [] do
    lines =
      stream_window
      |> Enum.take(-5)
      |> Enum.map(fn entry ->
        "- #{checkpoint_get(entry, "message") || inspect(entry, limit: 8, printable_limit: 120)}"
      end)
      |> Enum.join("\n")

    "\nRecent stream before freeze:\n#{lines}"
  end

  defp resume_stream_lines(_stream_window), do: ""

  defp checkpoint_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp checkpoint_get(_map, _key), do: nil
end
