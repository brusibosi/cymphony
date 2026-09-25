defmodule CymphonyElixir.PublicEventIntegrationTest do
  use CymphonyElixir.TestSupport

  test "orchestrator retains only redacted bounded event data in snapshot state" do
    issue_id = "issue-public-event-boundary"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-4900",
      title: "Event boundary",
      description: "Protect public state",
      state: "In Progress",
      url: "https://example.org/issues/MT-4900"
    }

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :EventBoundaryOrchestrator))
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    initial_state = :sys.get_state(pid)

    entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_agent_message: nil,
      last_agent_timestamp: nil,
      last_agent_event: nil,
      started_at: DateTime.utc_now(),
      log_events: []
    }

    :sys.replace_state(pid, fn state ->
      state
      |> Map.put(:running, %{issue_id => entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    secret = "OPENAI_API_KEY=hidden-value"
    huge = String.duplicate("x", 100_000) <> " " <> secret

    for n <- 1..75 do
      send(
        pid,
        {:agent_worker_update, issue_id,
         %{
           event: :stream_event,
           timestamp: DateTime.utc_now(),
           session_id: "thread-public",
           agent_os_pid: "OPENAI_API_KEY=hidden-value",
           payload: %{
             "type" => "item.completed",
             "item" => %{"type" => "agent_message", "text" => "#{n}: #{secret}"},
             "oversize" => huge,
             "invalid" => <<"good", 0xFF, "bad">>,
             "rate_limits" => %{
               "limit_id" => "requests",
               "primary" => %{"remaining" => 10, "limit" => 100},
               "Authorization" => "Basic opaque-credential"
             }
           },
           raw: secret
         }}
      )
    end

    assert %{running: [running]} = GenServer.call(pid, :snapshot)
    assert running.session_id == "thread-public"
    assert running.agent_os_pid == "OPENAI_API_KEY=[REDACTED]"
    assert length(running.log_events) == 50
    assert running.last_agent_message.message["type"] == "item.completed"
    assert inspect(running.last_agent_message) =~ "[REDACTED]"
    assert inspect(running.log_events) =~ "[REDACTED]"
    refute inspect(running.last_agent_message) =~ "hidden-value"
    refute inspect(running.log_events) =~ "hidden-value"
    refute inspect(running.last_agent_message) =~ String.duplicate("x", 256)
    assert byte_size(:erlang.term_to_binary(running.log_events)) < 500_000
    assert String.valid?(running.last_agent_message.message["invalid"])

    state = :sys.get_state(pid)
    assert state.rate_limits["limit_id"] == "requests"
    assert state.rate_limits["Authorization"] == "[REDACTED]"

    send(
      pid,
      {:agent_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         agent_os_pid: String.to_integer(String.duplicate("9", 20_000)),
         payload: "bounded PID"
       }}
    )

    assert %{running: [next_running]} = GenServer.call(pid, :snapshot)
    assert byte_size(next_running.agent_os_pid) < 1_024
  end
end
