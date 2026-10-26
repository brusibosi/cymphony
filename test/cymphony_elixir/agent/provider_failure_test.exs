defmodule CymphonyElixir.Agent.ProviderFailureTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Agent.ProviderFailure

  @now_ms 1_800_000_000_000

  test "genuine structured provider permission errors remain distinct from individual tool denials" do
    for code <- ["permission_error", "permission_denied"] do
      assert %{kind: :permission} = classify([Jason.encode!(%{"type" => "result", "is_error" => true, "error" => %{"code" => code}})])
      event = %{"type" => "result", "is_error" => true, "error" => %{"code" => code}, "permission_denials" => [permission_denial()]}
      assert %{kind: :permission} = classify([Jason.encode!(event)])
    end
  end

  test "unknown final errors cannot hide a valid tool denial" do
    for error <- ["ordinary_error", %{"code" => "ordinary_error"}, %{"message" => "permission_error"}] do
      event = %{"type" => "result", "is_error" => true, "error" => error, "permission_denials" => [permission_denial()]}
      assert %{kind: :tool_permission} = classify([Jason.encode!(event)])
    end
  end

  test "Claude final permission denials hold an exit-zero result before success resets" do
    denial = permission_denial()

    for is_error <- [false, true] do
      event = %{"type" => "result", "is_error" => is_error, "permission_denials" => [denial], "result" => "Waiting for permissions"}
      assert %{__struct__: ProviderFailure, kind: :tool_permission, retry_at: nil, message: message} = classify([Jason.encode!(event)])
      assert message =~ "refused"
      assert message =~ "retry manually"
      refute inspect(message) =~ "PRIVATE"
      refute message =~ "toolu_private"
    end
  end

  test "only a nonempty well-formed denial list in the Claude result envelope establishes a permission hold" do
    denial = permission_denial()
    event = %{"type" => "result", "is_error" => false, "permission_denials" => [denial]}

    for line <- [
          Jason.encode!(Jason.encode!(event)),
          Jason.encode!(%{"type" => "user", "message" => %{"content" => [%{"type" => "tool_result", "content" => Jason.encode!(event)}]}}),
          Jason.encode!(%{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => Jason.encode!(event)}]}}),
          Jason.encode!(Map.put(event, "type", "tool_result")),
          "Claude requested permissions that have not been granted yet"
        ] do
      assert classify([line]) == nil
    end

    for denials <- [
          nil,
          [],
          %{"tool_name" => "Bash"},
          "Bash",
          [nil],
          ["Bash"],
          [%{}],
          [Map.delete(denial, "tool_name")],
          [Map.put(denial, "tool_name", " ")],
          [Map.put(denial, "tool_name", 1)],
          [Map.delete(denial, "tool_use_id")],
          [Map.put(denial, "tool_use_id", "")],
          [Map.put(denial, "tool_use_id", false)],
          [Map.delete(denial, "tool_input")],
          [Map.put(denial, "tool_input", "quoted input")],
          [denial, %{}]
        ] do
      assert classify([Jason.encode!(Map.put(event, "permission_denials", denials))]) == nil
    end
  end

  test "permission hold keeps only an actionable message and no denied tool input" do
    event = %{"type" => "result", "is_error" => false, "permission_denials" => [permission_denial(), permission_denial()]}
    assert %{kind: :tool_permission, message: message} = failure = classify([Jason.encode!(event)])
    assert String.valid?(message)
    assert byte_size(message) <= 512
    refute inspect(failure) =~ "PRIVATE"
    refute inspect(failure) =~ "toolu_private"
    assert classify([Jason.encode!(event), ~s({"type":"result","is_error":false,"permission_denials":[]})]) == nil
  end

  test "Claude API authentication error becomes an actionable typed failure" do
    lines = [
      ~s({"type":"assistant","isApiErrorMessage":true,"error":"authentication_failed","message":{"content":[{"type":"text","text":"Not logged in"}]}}),
      ~s({"type":"result","is_error":true,"result":"Not logged in"})
    ]

    assert %{__struct__: ProviderFailure, kind: :authentication, retry_at: nil, message: message} = classify(lines)
    assert message =~ "authentication"
  end

  test "AGY result string quota refusal retains its explicit reset deadline" do
    lines = [
      ~s({"event":"result","result":{"conversation_id":"id","status":"ERROR","response":"","error":"Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 48h53m16s.","duration_seconds":0,"num_turns":1,"usage":{}}})
    ]

    assert %{kind: :quota, retry_at: 1_800_175_996_000} = classify(lines)
  end

  test "known AGY_ERROR JSON envelope retains quota metadata before any excerpt" do
    line =
      ~s|AGY_ERROR: {"short_error":"RESOURCE_EXHAUSTED (code 429): Individual quota reached. Resets in 48h53m16s.","status":"RESOURCE_EXHAUSTED","error_code":429,"code_kind":"http","retryable":true,"error_id":"id"}|

    assert %{kind: :quota, retry_at: 1_800_175_996_000} = classify([line])
  end

  test "quota without a provable future reset requires manual action" do
    for error <- [
          %{"code" => "RESOURCE_EXHAUSTED", "message" => "Quota exhausted"},
          %{"code" => "RESOURCE_EXHAUSTED", "retry_at_ms" => @now_ms - 1},
          %{"code" => "RESOURCE_EXHAUSTED", "retry_after" => -1},
          %{"code" => "RESOURCE_EXHAUSTED", "retry_after" => "tomorrow"},
          %{"code" => "RESOURCE_EXHAUSTED", "retry_at_ms" => 999_999_999_999_999_999},
          %{"code" => "RESOURCE_EXHAUSTED", "message" => "Resets in 0s."}
        ] do
      assert %{kind: :quota, retry_at: nil} = classify([Jason.encode!(%{"event" => "error", "error" => error})])
    end
  end

  test "structured absolute and relative retry metadata produce exact Unix milliseconds" do
    for {metadata, expected} <- [
          {%{"retry_at_ms" => 1_800_000_004_000}, 1_800_000_004_000},
          {%{"reset_at_ms" => 1_800_000_005_000}, 1_800_000_005_000},
          {%{"retry_after_ms" => 1_250}, 1_800_000_001_250},
          {%{"retry_after" => 7}, 1_800_000_007_000},
          {%{"retry_at" => "2027-01-15T08:00:03.250Z"}, 1_800_000_003_250},
          {%{"details" => [%{"@type" => "type.googleapis.com/google.rpc.RetryInfo", "retryDelay" => "3.250s"}]}, 1_800_000_003_250}
        ] do
      error = Map.put(metadata, "code", "RESOURCE_EXHAUSTED")
      assert %{kind: :quota, retry_at: ^expected} = classify([Jason.encode!(%{"event" => "error", "error" => error})])
    end
  end

  test "quoted fixtures, tool output and generic 429 errors do not hold a provider" do
    authentication = %{"type" => "assistant", "isApiErrorMessage" => true, "error" => "authentication_failed"}

    for line <- [
          "test authentication_failed RESOURCE_EXHAUSTED Resets in 48h53m16s passed",
          Jason.encode!(Jason.encode!(authentication)),
          Jason.encode!(%{"type" => "user", "message" => %{"content" => [%{"type" => "tool_result", "content" => Jason.encode!(authentication)}]}}),
          Jason.encode!(%{"type" => "item.completed", "item" => %{"type" => "command_execution", "aggregated_output" => Jason.encode!(authentication)}}),
          Jason.encode!(%{"event" => "step_update", "step_update" => %{"text_delta" => "Individual quota reached. Resets in 48h53m16s."}}),
          ~s({"event":"error","error":{"code":429,"message":"Network request failed"}}),
          ~s({"type":"result","is_error":true,"result":"Test failed: authentication_failed"}),
          ~s({"event":"result","result":{"status":"ERROR","error":"Test failed: RESOURCE_EXHAUSTED"}})
        ] do
      # A JSON string containing an envelope is data, not an event.
      assert classify([line]) == nil
    end
  end

  test "malformed or unrecognized output never evaluates code or infers a hold" do
    for line <- [
          nil,
          3,
          "",
          "{broken",
          "[]",
          ~s(%{"error" => "authentication_failed"}),
          ~s({"type":"assistant","error":"authentication_failed"}),
          ~s({"event":"result","result":{"status":"SUCCESS","error":"Individual quota reached."}})
        ] do
      assert classify([line]) == nil
    end
  end

  test "public message is bounded and contains no raw credential or payload" do
    secret = "sk-ant-api03-PRIVATE-CREDENTIAL"
    payload = %{"event" => "error", "error" => %{"code" => "RESOURCE_EXHAUSTED", "message" => String.duplicate(secret, 1_000)}}
    assert %{message: message} = classify([Jason.encode!(payload)])
    assert String.valid?(message)
    assert byte_size(message) <= 512
    refute message =~ secret
    refute message =~ "PRIVATE"
  end

  test "a repeated quota refusal without metadata keeps the actionable known deadline" do
    lines = [
      ~s({"event":"error","error":{"code":"RESOURCE_EXHAUSTED","retry_after":5}}),
      ~s({"event":"error","error":{"code":"RESOURCE_EXHAUSTED"}})
    ]

    assert %{retry_at: 1_800_000_005_000, message: message} = classify(lines)
    refute message =~ "manually"
  end

  test "successful terminal events clear an earlier recovered refusal" do
    error = ~s({"event":"error","error":{"code":"RESOURCE_EXHAUSTED"}})

    for success <- [~s({"type":"result","is_error":false}), ~s({"type":"turn.completed"}), ~s({"event":"result","result":{"status":"SUCCESS"}})] do
      assert classify([error, success]) == nil
    end
  end

  test "typed provider codes are recognized only at supported error envelope paths" do
    for event <- [
          %{"type" => "result", "is_error" => true, "error" => %{"code" => "authentication_failed"}},
          %{"type" => "turn.failed", "error" => %{"code" => "UNAUTHENTICATED"}},
          %{"event" => "error", "status" => "authentication_error"},
          %{"event" => "result", "result" => %{"status" => "ERROR", "error" => %{"code" => "invalid_api_key"}}}
        ] do
      assert %{kind: :authentication, retry_at: nil} = classify([Jason.encode!(event)])
    end
  end

  test "invalid and excessively large error envelopes remain ordinary failures" do
    for line <- [
          "AGY_ERROR: invalid JSON",
          ~s(AGY_ERROR: {"status":"NETWORK_ERROR"}),
          ~s({"event":"error","error":{"message":"authentication_failed"}}),
          String.duplicate(" ", 262_145)
        ] do
      assert classify([line]) == nil
    end
  end

  test "ambiguous retry fields do not invent a deadline" do
    for metadata <- [
          %{"retry_at" => "tomorrow"},
          %{"retry_at" => "2027-01-15T07:00:00Z"},
          %{"retry_at" => 1_800_000_005},
          %{"retry_after_ms" => 0},
          %{"details" => [%{"@type" => "unknown", "retryDelay" => "3s"}]},
          %{"details" => [%{"@type" => "type.googleapis.com/google.rpc.RetryInfo", "retryDelay" => "soon"}]},
          %{"message" => "Resets in two days."},
          %{"message" => "Resets in 1h 30m."}
        ] do
      error = Map.put(metadata, "code", "RESOURCE_EXHAUSTED")
      assert %{kind: :quota, retry_at: nil} = classify([Jason.encode!(%{"event" => "error", "error" => error})])
    end
  end

  test "whole-second RetryInfo and partial reset durations keep exact deadlines" do
    for {metadata, expected} <- [
          {%{"details" => [%{"@type" => "type.googleapis.com/google.rpc.RetryInfo", "retryDelay" => "3s"}]}, 1_800_000_003_000},
          {%{"message" => "Resets in 2h."}, 1_800_007_200_000},
          {%{"message" => "Resets in 3m."}, 1_800_000_180_000},
          {%{"message" => "Resets in 4s."}, 1_800_000_004_000}
        ] do
      error = Map.put(metadata, "code", "RESOURCE_EXHAUSTED")
      assert %{kind: :quota, retry_at: ^expected} = classify([Jason.encode!(%{"event" => "error", "error" => error})])
    end
  end

  defp permission_denial do
    %{
      "tool_name" => "mcp__linear__get_issue_PRIVATE",
      "tool_use_id" => "toolu_private",
      "tool_input" => %{"id" => "ALE-PRIVATE", "api_key" => "lin_api_PRIVATE"}
    }
  end

  defp classify(lines), do: ProviderFailure.classify(lines, @now_ms)
end
