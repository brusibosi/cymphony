defmodule CymphonyElixir.PublicEventTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.PublicEvent

  test "redacts real Claude, Codex and Antigravity event payloads without losing event shape" do
    claude = %{
      "type" => "assistant",
      "message" => %{
        "content" => [%{"type" => "text", "text" => "ANTHROPIC_API_KEY=secret-value and ready"}]
      }
    }

    codex = %{
      "type" => "item.completed",
      "item" => %{"type" => "agent_message", "text" => "Bearer sk-abcdefghijklmnopqrstuvwxyz"},
      "raw" => "OPENAI_API_KEY=another-secret"
    }

    antigravity = %{
      "event" => "step_update",
      "step_update" => %{"text_delta" => "GOOGLE_API_KEY=third-secret"}
    }

    for {event, field} <- [{claude, "type"}, {codex, "type"}, {antigravity, "event"}] do
      public = PublicEvent.sanitize(event)
      assert public[field] == event[field]
      assert inspect(public) =~ "[REDACTED]"
      refute inspect(public) =~ "secret-value"
      refute inspect(public) =~ "another-secret"
      refute inspect(public) =~ "third-secret"
    end
  end

  test "omits oversize scalars rather than exposing a partial credential" do
    value = String.duplicate("x", 16_384) <> " OPENAI_API_KEY=secret-value"
    public = PublicEvent.sanitize(%{"text" => value})

    assert byte_size(:erlang.term_to_binary(public)) < 10_000
    refute inspect(public) =~ "secret-value"
    refute inspect(public) =~ "OPENAI_API_KEY"
    refute inspect(public) =~ String.duplicate("x", 256)
  end

  test "bounds map entries, list items and nesting independently of incoming size" do
    wide = Map.new(1..1000, fn i -> {"field_#{i}", String.duplicate("v", 200)} end)
    deep = Enum.reduce(1..100, "leaf", fn _, acc -> %{"nested" => acc} end)
    public = PublicEvent.sanitize(%{"wide" => wide, "many" => Enum.to_list(1..1000), "deep" => deep})

    assert byte_size(:erlang.term_to_binary(public)) <= 16_384
    assert length(public["many"]) < 1000
    assert map_size(public["wide"]) < 1000
    refute inspect(public) =~ "leaf"
  end

  test "drops invalid UTF-8 and terminal control bytes before public retention" do
    public = PublicEvent.sanitize(%{"text" => <<"safe", 0xFF, 27, "[31m", 0, " end">>})

    assert public["text"] == "safe end"
    assert String.valid?(public["text"])
  end

  test "retains safe atom field names but redacts a credential-shaped atom key" do
    public = PublicEvent.sanitize(%{:"OPENAI_API_KEY=hidden-value" => "secret", type: "ready"})

    assert public[:type] == "ready"
    assert public["OPENAI_API_KEY=[REDACTED]"] == "[REDACTED]"
    refute inspect(public) =~ "hidden-value"
  end

  test "drops unsupported map keys and values rather than inspecting them into output" do
    public = PublicEvent.sanitize(%{{:unsafe, "hidden-value"} => "x", "safe" => {:secret, "hidden-value"}})

    assert public == %{"safe" => nil}
  end

  test "stops visiting a deeply branched payload after its global node budget" do
    branch = Map.new(1..20, fn i -> {"field_#{i}", Enum.to_list(1..20)} end)
    public = PublicEvent.sanitize(%{"branches" => branch})

    assert byte_size(:erlang.term_to_binary(public)) < 16_384
    assert inspect(public) =~ "nil"
  end

  test "redacts opaque values under credential-named map keys" do
    event = %{
      "headers" => %{"Authorization" => "Basic ordinary-opaque-bytes", "Cookie" => "sid=opaque"},
      "env" => %{"OPENAI_API_KEY" => "ordinary-opaque-bytes", "apiKey" => "also-opaque"},
      "SSH_KEY_PATH" => "/safe/location"
    }

    public = PublicEvent.sanitize(event)

    assert public["headers"]["Authorization"] == "[REDACTED]"
    assert public["headers"]["Cookie"] == "[REDACTED]"
    assert public["env"]["OPENAI_API_KEY"] == "[REDACTED]"
    assert public["env"]["apiKey"] == "[REDACTED]"
    assert public["SSH_KEY_PATH"] == "/safe/location"
  end

  test "rejects a huge numeric literal rather than retaining it unbounded" do
    huge_integer = String.to_integer(String.duplicate("9", 20_000))
    public = PublicEvent.sanitize(%{"usage" => huge_integer, "normal" => 42})

    assert public["usage"] == nil
    assert public["normal"] == 42
    assert byte_size(:erlang.term_to_binary(public)) < 1_000
  end

  test "classifies a credential key before truncating its long name" do
    key = String.duplicate("X", 1_100) <> "_API_KEY"
    public = PublicEvent.sanitize(%{key => "opaque-secret"})

    refute inspect(public) =~ "opaque-secret"
    assert Map.values(public) == ["[REDACTED]"]
  end
end
