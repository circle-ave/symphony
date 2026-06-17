defmodule SymphonyElixir.Codex.MessageText do
  @moduledoc false

  @spec output([term()]) :: String.t()
  def output(messages) when is_list(messages) do
    completed =
      messages
      |> Enum.flat_map(&completed_agent_parts/1)
      |> Enum.join("")

    if completed == "" do
      messages
      |> Enum.flat_map(&parts/1)
      |> Enum.join("")
    else
      completed
    end
  end

  @spec parts(term()) :: [String.t()]
  def parts(%{payload: payload}), do: text_parts(payload)
  def parts(%{raw: raw}) when is_binary(raw), do: raw_text_parts(raw)
  def parts(%{"payload" => payload}), do: text_parts(payload)
  def parts(%{"raw" => raw}) when is_binary(raw), do: raw_text_parts(raw)
  def parts(message) when is_map(message), do: text_parts(message)
  def parts(_message), do: []

  defp raw_text_parts(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> text_parts(decoded)
      _ -> []
    end
  end

  defp completed_agent_parts(%{payload: payload}), do: completed_agent_parts(payload)
  defp completed_agent_parts(%{raw: raw}) when is_binary(raw), do: raw_completed_agent_parts(raw)
  defp completed_agent_parts(%{"payload" => payload}), do: completed_agent_parts(payload)
  defp completed_agent_parts(%{"raw" => raw}) when is_binary(raw), do: raw_completed_agent_parts(raw)

  defp completed_agent_parts(%{"method" => "item/completed"} = payload) do
    cond do
      agent_message?(map_path(payload, ["params", "item"])) ->
        payload
        |> map_path(["params", "item"])
        |> agent_item_text()

      agent_message?(map_path(payload, ["params", "msg"])) ->
        payload
        |> map_path(["params", "msg"])
        |> agent_item_text()

      true ->
        []
    end
  end

  defp completed_agent_parts(%{method: "item/completed"} = payload) do
    payload
    |> stringify_method_key()
    |> completed_agent_parts()
  end

  defp completed_agent_parts(_message), do: []

  defp raw_completed_agent_parts(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> completed_agent_parts(decoded)
      _ -> []
    end
  end

  defp text_parts(%{"method" => "item/agentMessage/delta"} = payload) do
    payload
    |> map_path(["params", "delta"])
    |> content_text()
  end

  defp text_parts(%{method: "item/agentMessage/delta"} = payload) do
    payload
    |> map_path(["params", "delta"])
    |> content_text()
  end

  defp text_parts(%{"method" => "item/completed"} = payload) do
    cond do
      agent_message?(map_path(payload, ["params", "item"])) ->
        payload
        |> map_path(["params", "item"])
        |> agent_item_text()

      agent_message?(map_path(payload, ["params", "msg"])) ->
        payload
        |> map_path(["params", "msg"])
        |> agent_item_text()

      true ->
        []
    end
  end

  defp text_parts(%{method: "item/completed"} = payload) do
    payload
    |> stringify_method_key()
    |> text_parts()
  end

  defp text_parts(%{"type" => type} = payload) when type in ["agent_message", "agentMessage"] do
    agent_item_text(payload)
  end

  defp text_parts(%{type: type} = payload) when type in ["agent_message", "agentMessage"] do
    agent_item_text(payload)
  end

  defp text_parts(payload) when is_map(payload) do
    legacy_text_paths()
    |> Enum.flat_map(fn path -> content_text(map_path(payload, path)) end)
  end

  defp text_parts(_payload), do: []

  defp stringify_method_key(%{method: method} = payload) do
    payload
    |> Map.delete(:method)
    |> Map.put("method", method)
  end

  defp agent_message?(%{} = item) do
    type = map_get(item, "type")
    role = map_get(item, "role")

    type in ["agentMessage", "agent_message"] or role == "assistant"
  end

  defp agent_message?(_item), do: false

  defp agent_item_text(%{} = item) do
    [
      map_get(item, "text"),
      map_get(item, "message"),
      map_get(item, "content"),
      map_path(item, ["payload", "text"]),
      map_path(item, ["payload", "message"]),
      map_path(item, ["payload", "content"])
    ]
    |> Enum.flat_map(&content_text/1)
  end

  defp legacy_text_paths do
    [
      ["params", "msg", "textDelta"],
      ["params", "msg", "delta"],
      ["params", "msg", "text"],
      ["params", "msg", "message"],
      ["params", "msg", "payload", "textDelta"],
      ["params", "msg", "payload", "delta"],
      ["params", "msg", "payload", "text"],
      ["params", "msg", "payload", "message"],
      ["params", "textDelta"],
      ["params", "delta"],
      ["params", "text"],
      ["params", "message"],
      ["textDelta"],
      ["delta"],
      ["text"],
      ["message"]
    ]
  end

  defp content_text(value) when is_binary(value), do: [value]
  defp content_text(values) when is_list(values), do: Enum.flat_map(values, &content_text/1)

  defp content_text(%{} = value) do
    ["text", "message", "content", "summary"]
    |> Enum.flat_map(fn key -> content_text(map_get(value, key)) end)
  end

  defp content_text(_value), do: []

  defp map_path(value, []), do: value

  defp map_path(%{} = map, [key | rest]) do
    map
    |> map_get(key)
    |> map_path(rest)
  end

  defp map_path(_value, _path), do: nil

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(to_string(key)))
  end
end
