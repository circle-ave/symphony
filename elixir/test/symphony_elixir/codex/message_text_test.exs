defmodule SymphonyElixir.Codex.MessageTextTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.MessageText

  test "output prefers completed agent text over streamed deltas" do
    messages = [
      %{
        "payload" => %{
          "method" => "item/completed",
          "params" => %{
            "item" => %{
              "type" => "userMessage",
              "content" => [%{"type" => "text", "text" => "ignore"}]
            }
          }
        }
      },
      %{"payload" => %{"method" => "item/agentMessage/delta", "params" => %{"delta" => "delta"}}},
      %{
        "payload" => %{
          "method" => "item/completed",
          "params" => %{"item" => %{"type" => "agentMessage", "text" => "commentary"}}
        }
      },
      %{
        "payload" => %{
          "method" => "item/completed",
          "params" => %{"item" => %{"type" => "agentMessage", "text" => "final"}}
        }
      }
    ]

    assert MessageText.output(messages) == "final"
  end

  test "output falls back to streamed deltas when completed text is absent" do
    messages = [
      %{"payload" => %{"method" => "item/agentMessage/delta", "params" => %{"delta" => "left"}}},
      %{payload: %{method: "item/agentMessage/delta", params: %{delta: "right"}}}
    ]

    assert MessageText.output(messages) == "leftright"
  end

  test "output handles raw completed agent events" do
    raw =
      Jason.encode!(%{
        "method" => "item/completed",
        "params" => %{"item" => %{"role" => "assistant", "text" => "raw final"}}
      })

    assert MessageText.output([%{raw: raw}]) == "raw final"
    assert MessageText.output([%{"raw" => raw}]) == "raw final"

    assert MessageText.output([%{method: "item/completed", params: %{item: %{role: "assistant", text: "atom final"}}}]) ==
             "atom final"

    assert MessageText.output([%{raw: "not json"}]) == ""
  end

  test "parts decodes raw, payload, and legacy agent text shapes" do
    raw_delta =
      Jason.encode!(%{
        "method" => "item/agentMessage/delta",
        "params" => %{"delta" => "raw delta"}
      })

    assert MessageText.parts(%{raw: raw_delta}) == ["raw delta"]
    assert MessageText.parts(%{"raw" => raw_delta}) == ["raw delta"]
    assert MessageText.parts(%{raw: "not json"}) == []
    assert MessageText.parts(%{"raw" => "not json"}) == []
    assert MessageText.parts(%{"payload" => %{"type" => "agent_message", "message" => "legacy"}}) == ["legacy"]
    assert MessageText.parts(%{type: "agentMessage", message: "atom legacy"}) == ["atom legacy"]
    assert MessageText.parts(:ignored) == []
  end

  test "parts decodes completed item, completed msg, and nested content" do
    assert MessageText.parts(%{
             "method" => "item/completed",
             "params" => %{
               "item" => %{
                 "type" => "agentMessage",
                 "content" => [%{"text" => "list text"}, %{"summary" => "summary text"}]
               }
             }
           }) == ["list text", "summary text"]

    assert MessageText.parts(%{
             "method" => "item/completed",
             "params" => %{"msg" => %{"type" => "agent_message", "message" => "msg text"}}
           }) == ["msg text"]

    assert MessageText.parts(%{method: "item/completed", params: %{item: %{role: "assistant", payload: %{text: "atom text"}}}}) ==
             ["atom text"]
  end

  test "parts handles legacy fallback paths and non-map payloads" do
    assert MessageText.parts(%{"params" => %{"msg" => %{"payload" => %{"delta" => "legacy delta"}}}}) == [
             "legacy delta"
           ]

    assert MessageText.parts(%{payload: "not a map"}) == []
  end
end
