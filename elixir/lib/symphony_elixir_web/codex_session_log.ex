defmodule SymphonyElixirWeb.CodexSessionLog do
  @moduledoc false

  @tail_bytes 512_000
  @max_entries 80
  @summary_limit 2_000

  @spec payloads_for_session(String.t() | nil) :: [map()]
  def payloads_for_session(session_id) when not is_binary(session_id), do: []
  def payloads_for_session(""), do: []

  def payloads_for_session(session_id) do
    case find_log(session_id) do
      {:ok, path} -> [log_payload(path, session_id)]
      :error -> []
    end
  end

  defp find_log(session_id) do
    thread_id = thread_id(session_id)

    sessions_dir()
    |> Path.join("**/*#{thread_id}*.jsonl")
    |> Path.wildcard()
    |> Enum.reject(&File.dir?/1)
    |> latest_path()
  end

  defp sessions_dir do
    System.get_env("SYMPHONY_CODEX_SESSIONS_DIR") ||
      Path.join([System.user_home!(), ".codex", "sessions"])
  end

  defp thread_id(session_id) do
    parts = String.split(session_id, "-")

    if length(parts) >= 5 do
      parts |> Enum.take(5) |> Enum.join("-")
    else
      session_id
    end
  end

  defp latest_path([]), do: :error
  defp latest_path(paths), do: {:ok, Enum.max_by(paths, &mtime/1)}

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> stat.mtime
      _ -> 0
    end
  end

  defp log_payload(path, session_id) do
    stat = stat(path)
    {tail, tail_truncated?} = read_tail(path, stat.size)

    lines =
      tail
      |> String.split("\n", trim: true)
      |> maybe_drop_partial_line(tail_truncated?)

    %{
      session_id: session_id,
      path: path,
      size_bytes: stat.size,
      modified_at: unix_iso8601(stat.mtime),
      truncated: tail_truncated? or length(lines) > @max_entries,
      entries:
        lines
        |> Enum.take(-@max_entries)
        |> Enum.map(&entry/1)
    }
  end

  defp stat(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> stat
      _ -> %{size: 0, mtime: 0}
    end
  end

  defp read_tail(path, size) do
    bytes = min(max(size, 0), @tail_bytes)
    start_at = max(size - bytes, 0)

    case :file.open(String.to_charlist(path), [:read, :binary]) do
      {:ok, file} ->
        try do
          with {:ok, _position} <- :file.position(file, {:bof, start_at}),
               {:ok, data} <- :file.read(file, bytes) do
            {data, start_at > 0}
          else
            :eof -> {"", start_at > 0}
            _ -> {"", false}
          end
        after
          :file.close(file)
        end

      _ ->
        {"", false}
    end
  end

  defp maybe_drop_partial_line([], _tail_truncated?), do: []
  defp maybe_drop_partial_line([_partial | rest], true), do: rest
  defp maybe_drop_partial_line(lines, false), do: lines

  defp entry(line) do
    case Jason.decode(line) do
      {:ok, %{} = decoded} ->
        payload = Map.get(decoded, "payload", %{})

        %{
          at: Map.get(decoded, "timestamp"),
          kind: kind(decoded, payload),
          summary: summary(decoded, payload)
        }

      _ ->
        %{at: nil, kind: "raw", summary: truncate(line)}
    end
  end

  defp kind(%{"type" => type}, %{"type" => payload_type}), do: "#{type}/#{payload_type}"
  defp kind(%{"type" => type}, _payload), do: type
  defp kind(_decoded, _payload), do: "event"

  defp summary(%{"type" => "session_meta"}, %{} = payload) do
    ["session", Map.get(payload, "id"), Map.get(payload, "cwd")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> truncate()
  end

  defp summary(_decoded, %{"type" => "message", "role" => role, "content" => content}) do
    "#{role}: #{content_text(content)}"
    |> truncate()
  end

  defp summary(_decoded, %{"type" => "function_call", "name" => name} = payload) do
    ["tool call:", name, Map.get(payload, "arguments")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> truncate()
  end

  defp summary(_decoded, %{"type" => "function_call_output"} = payload) do
    ["tool output:", Map.get(payload, "output")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> truncate()
  end

  defp summary(_decoded, %{"type" => "reasoning", "summary" => summary}) when is_list(summary) do
    text = content_text(summary)

    if text == "" do
      "reasoning update"
    else
      truncate("reasoning: #{text}")
    end
  end

  defp summary(_decoded, %{"type" => "agent_message", "message" => message}),
    do: truncate("agent: #{message}")

  defp summary(_decoded, %{"type" => "token_count", "info" => info}) do
    total = get_in(info, ["total_token_usage", "total_tokens"])
    last = get_in(info, ["last_token_usage", "total_tokens"])

    "tokens: total #{token_count(total)}, last #{token_count(last)}"
  end

  defp summary(_decoded, %{"type" => type}), do: truncate(type)
  defp summary(%{} = decoded, _payload), do: truncate(inspect(decoded, limit: 20))

  defp content_text(content) when is_list(content) do
    content
    |> Enum.map(&content_part_text/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp content_text(content) when is_binary(content), do: content
  defp content_text(_content), do: ""

  defp content_part_text(%{"text" => text}) when is_binary(text), do: text
  defp content_part_text(%{"type" => "input_text", "text" => text}) when is_binary(text), do: text
  defp content_part_text(%{"type" => "output_text", "text" => text}) when is_binary(text), do: text
  defp content_part_text(%{"summary" => summary}) when is_binary(summary), do: summary
  defp content_part_text(_part), do: nil

  defp token_count(value) when is_integer(value), do: Integer.to_string(value)
  defp token_count(_value), do: "n/a"

  defp truncate(value) do
    value
    |> to_string()
    |> String.slice(0, @summary_limit)
  end

  defp unix_iso8601(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} ->
        datetime
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      _ ->
        nil
    end
  end

  defp unix_iso8601(_value), do: nil
end
