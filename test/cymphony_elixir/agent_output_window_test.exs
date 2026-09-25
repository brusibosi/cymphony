defmodule CymphonyElixir.AgentOutputWindowTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Agent.OutputWindow
  alias CymphonyElixir.Agent.Codex
  alias CymphonyElixir.Agent.Antigravity

  test "a long Codex stream keeps thread ID, last message, completion usage and a bounded transcript" do
    thread = ~s({"type":"thread.started","thread_id":"thread-4900"})
    message = ~s({"type":"item.completed","item":{"type":"agent_message","text":"final answer"}})
    done = ~s({"type":"turn.completed","usage":{"input_tokens":12,"output_tokens":3}})
    noise = for n <- 1..10_000, do: ~s({"type":"item.updated","n":#{n}})

    window =
      ([thread] ++ Enum.take(noise, 5_000) ++ [message] ++ Enum.drop(noise, 5_000) ++ [done])
      |> Enum.reduce(OutputWindow.new(), &OutputWindow.push(&2, &1))

    lines = OutputWindow.lines(window)
    assert length(lines) < 200
    assert byte_size(:erlang.term_to_binary(lines)) < 2_100_000

    assert {:ok, result} = Codex.parse_output(lines, %{}, fn _ -> :ok end)
    assert result.session_id == "thread-4900"
    assert result.result == "final answer"
    assert result.usage == %{"input_tokens" => 12, "output_tokens" => 3, "total_tokens" => 15}
  end

  test "a flood of long lines stays under a finite byte budget" do
    line = String.duplicate("a", 20_000)
    window = Enum.reduce(1..1_000, OutputWindow.new(), fn _, acc -> OutputWindow.push(acc, line) end)

    assert byte_size(:erlang.term_to_binary(OutputWindow.lines(window))) < 2_100_000
  end

  test "ignores an oversize line rather than growing the retained transcript" do
    window = OutputWindow.new() |> OutputWindow.push(String.duplicate("x", 300_000))

    assert OutputWindow.lines(window) == []
  end

  test "keeps each adapter's semantic event after unrelated output evicts it from the tail" do
    milestones = [
      ~s({"type":"turn.failed","error":{"message":"failed"}}),
      ~s({"type":"result","session_id":"claude-id"}),
      ~s({"event":"init","conversation_id":"agy-id"}),
      ~s({"event":"result","result":{"status":"SUCCESS"}}),
      ~s({"event":"step_update","step_update":{"text_delta":"hello"}})
    ]

    window =
      Enum.reduce(milestones, OutputWindow.new(), fn line, acc ->
        acc
        |> OutputWindow.push(line)
        |> then(fn window ->
          Enum.reduce(1..100, window, fn i, window -> OutputWindow.push(window, "noise #{i}") end)
        end)
      end)

    lines = OutputWindow.lines(window)
    for line <- milestones, do: assert(line in lines)
  end

  test "semantic milestones also obey a global byte budget" do
    first = Jason.encode!(%{"type" => "thread.started", "thread_id" => String.duplicate("a", 200_000)})
    second = Jason.encode!(%{"type" => "turn.completed", "padding" => String.duplicate("b", 200_000)})
    third = Jason.encode!(%{"type" => "turn.failed", "padding" => String.duplicate("c", 200_000)})

    window =
      OutputWindow.new()
      |> then(fn window -> Enum.reduce(1..4, window, fn i, acc -> OutputWindow.push(acc, "start #{i}") end) end)
      |> OutputWindow.push(first)
      |> OutputWindow.push(second)
      |> OutputWindow.push(third)
      |> then(fn window -> Enum.reduce(1..100, window, fn i, acc -> OutputWindow.push(acc, "end #{i}") end) end)

    refute first in OutputWindow.lines(window)
    assert byte_size(:erlang.term_to_binary(OutputWindow.lines(window))) < 2_100_000
  end

  test "long Antigravity stream keeps all bounded fallback text and the latest usage-only update" do
    init = ~s({"event":"init","conversation_id":"agy-long"})
    first = ~s({"event":"step_update","step_update":{"text_delta":"first"}})
    second = ~s({"event":"step_update","step_update":{"text_delta":"second"}})
    usage = ~s({"event":"step_update","step_update":{"usage":{"input_tokens":3,"output_tokens":1}}})
    result = ~s({"event":"result","result":{"status":"SUCCESS"}})
    noise = for n <- 1..100, do: ~s({"event":"progress","n":#{n}})

    window =
      ([init] ++ Enum.take(noise, 10) ++ [first] ++ noise ++ [second, usage] ++ noise ++ [result])
      |> Enum.reduce(OutputWindow.new(), &OutputWindow.push(&2, &1))

    lines = OutputWindow.lines(window)
    assert length(lines) < 200
    assert byte_size(:erlang.term_to_binary(lines)) < 2_100_000

    assert {:ok, parsed} = Antigravity.parse_output(lines, %{settings: %{output_format: "stream-json"}}, fn _ -> :ok end)
    assert parsed.session_id == "agy-long"
    assert parsed.result == "firstsecond"
    assert parsed.usage == %{"input_tokens" => 3, "output_tokens" => 1, "total_tokens" => 4}
  end

  test "Antigravity text summary stops accumulating chunks after its byte cap" do
    delta = Jason.encode!(%{"event" => "step_update", "step_update" => %{"text_delta" => String.duplicate("x", 2_000)}})
    window = Enum.reduce(1..1_000, OutputWindow.new(), fn _, acc -> OutputWindow.push(acc, delta) end)

    assert length(window.antigravity_step.deltas_rev) < 100
    assert byte_size(:erlang.term_to_binary(window)) < 2_000_000
    assert Enum.join(OutputWindow.lines(window)) =~ "[truncated]"
  end

  test "Antigravity usage summary normalizes malformed numbers without retaining arbitrary values" do
    usage = Jason.encode!(%{"event" => "step_update", "step_update" => %{"usage" => %{"input_tokens" => "opaque", "output_tokens" => 2}}})
    result = ~s({"event":"result","result":{"status":"SUCCESS"}})

    window = OutputWindow.new() |> OutputWindow.push(usage) |> OutputWindow.push(result)

    assert {:ok, parsed} =
             Antigravity.parse_output(OutputWindow.lines(window), %{settings: %{output_format: "stream-json"}}, fn _ -> :ok end)

    assert parsed.usage == %{"input_tokens" => 0, "output_tokens" => 2, "total_tokens" => 2}
  end
end
