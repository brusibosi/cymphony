defmodule CymphonyElixir.Orchestrator.RetryOwnershipTest do
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Orchestrator.State

  test "a terminal issue found by dispatch revalidation releases its retry claim" do
    issue = issue("retry-stale", "MT-STALE", "In Progress")
    endpoint = linear_endpoint(issue, by_id: %{issue | state: "Done"})
    state = retry_state(issue, endpoint)
    token = state.retry_attempts[issue.id].retry_token

    {:noreply, result} = Orchestrator.handle_info({:retry_issue, issue.id, token}, state)

    assert result.running == %{}
    refute Map.has_key?(result.retry_attempts, issue.id)
    refute MapSet.member?(result.claimed, issue.id)
    assert_receive {:linear_query, :poll}
    assert_receive {:linear_query, :by_id}
  end

  test "a missing issue at dispatch revalidation releases its retry claim" do
    issue = issue("retry-missing", "MT-MISSING", "In Progress")
    endpoint = linear_endpoint(issue, by_id: nil)
    state = retry_state(issue, endpoint)
    token = state.retry_attempts[issue.id].retry_token

    {:noreply, result} = Orchestrator.handle_info({:retry_issue, issue.id, token}, state)

    assert result.running == %{}
    refute Map.has_key?(result.retry_attempts, issue.id)
    refute MapSet.member?(result.claimed, issue.id)
  end

  test "a nonterminal issue that left active states releases its retry claim" do
    issue = issue("retry-stale", "MT-BACKLOG", "In Progress")
    endpoint = linear_endpoint(issue, by_id: %{issue | state: "Backlog"})
    state = retry_state(issue, endpoint)
    token = state.retry_attempts[issue.id].retry_token

    {:noreply, result} = Orchestrator.handle_info({:retry_issue, issue.id, token}, state)

    assert result.running == %{}
    refute Map.has_key?(result.retry_attempts, issue.id)
    refute MapSet.member?(result.claimed, issue.id)
  end

  test "a failed dispatch revalidation keeps retry ownership and failure count" do
    issue = issue("retry-error", "MT-ERROR", "In Progress")
    endpoint = linear_endpoint(issue, by_id: {:error, "temporary outage"})
    state = retry_state(issue, endpoint)
    state = %{state | config: %{state.config | agent: %{state.config.agent | max_retry_attempts: 3}}}
    token = state.retry_attempts[issue.id].retry_token

    {:noreply, result} = Orchestrator.handle_info({:retry_issue, issue.id, token}, state)

    assert result.running == %{}

    assert %{attempt: 3, failures: 3, identifier: "MT-ERROR", timer_ref: timer_ref} =
             result.retry_attempts[issue.id]

    assert is_reference(timer_ref)
    assert MapSet.member?(result.claimed, issue.id)
  end

  test "a failed retry poll remains scheduled without spending the failure budget" do
    issue = issue("retry-poll-error", "MT-POLL-ERROR", "In Progress")
    endpoint = linear_endpoint(issue, by_id: issue, poll: {:error, "temporary outage"})
    state = retry_state(issue, endpoint)
    token = state.retry_attempts[issue.id].retry_token

    {:noreply, result} = Orchestrator.handle_info({:retry_issue, issue.id, token}, state)

    assert %{attempt: 3, failures: 3, timer_ref: timer_ref} = result.retry_attempts[issue.id]
    assert is_reference(timer_ref)
    assert MapSet.member?(result.claimed, issue.id)
  end

  test "lack of dispatch capacity reschedules the retry without spending a failure" do
    issue = issue("retry-full", "MT-FULL", "In Progress")
    endpoint = linear_endpoint(issue, by_id: issue)
    state = %{retry_state(issue, endpoint) | max_concurrent_agents: 0}
    token = state.retry_attempts[issue.id].retry_token

    {:noreply, result} = Orchestrator.handle_info({:retry_issue, issue.id, token}, state)

    assert %{attempt: 3, failures: 3, timer_ref: timer_ref} = result.retry_attempts[issue.id]
    assert is_reference(timer_ref)
    assert result.running == %{}
    assert MapSet.member?(result.claimed, issue.id)
  end

  test "a full SSH worker reschedules the retry without spending a failure" do
    issue = issue("retry-worker-full", "MT-WORKER-FULL", "In Progress")
    endpoint = linear_endpoint(issue, by_id: issue)
    state = retry_state(issue, endpoint)
    worker = %{state.config.worker | ssh_hosts: ["worker-a"], max_concurrent_agents_per_host: 1}
    config = %{state.config | worker: worker}
    occupied = %{issue: issue("occupied", "MT-OCCUPIED", "In Progress"), worker_host: "worker-a"}
    state = %{state | config: config, max_concurrent_agents: 2, running: %{"occupied" => occupied}}
    token = state.retry_attempts[issue.id].retry_token

    {:noreply, result} = Orchestrator.handle_info({:retry_issue, issue.id, token}, state)

    assert %{attempt: 3, failures: 3, timer_ref: timer_ref} = result.retry_attempts[issue.id]
    assert is_reference(timer_ref)
    assert MapSet.member?(result.claimed, issue.id)
    refute Map.has_key?(result.running, issue.id)
  end

  test "successful retry dispatch moves ownership from retry queue to running" do
    issue = issue("retry-success", "MT-SUCCESS", "In Progress")
    endpoint = linear_endpoint(issue, by_id: issue)
    state = retry_state(issue, endpoint)
    token = state.retry_attempts[issue.id].retry_token

    {:noreply, result} = Orchestrator.handle_info({:retry_issue, issue.id, token}, state)

    assert %{retry_attempt: 2, failure_count: 3, pid: pid} = result.running[issue.id]
    assert is_pid(pid)
    refute Map.has_key?(result.retry_attempts, issue.id)
    assert MapSet.member?(result.claimed, issue.id)
    Process.exit(pid, :kill)
  end

  test "an obsolete retry token cannot consume the current retry" do
    issue = issue("retry-token", "MT-TOKEN", "In Progress")
    endpoint = linear_endpoint(issue, by_id: issue)
    state = retry_state(issue, endpoint)

    assert {:noreply, ^state} = Orchestrator.handle_info({:retry_issue, issue.id, make_ref()}, state)
    refute_receive {:linear_query, _}
  end

  test "paused retry keeps its attempt and failure count held" do
    issue = issue("retry-paused", "MT-PAUSED", "In Progress")
    endpoint = linear_endpoint(issue, by_id: issue)
    state = %{retry_state(issue, endpoint) | paused: true}
    token = state.retry_attempts[issue.id].retry_token

    {:noreply, result} = Orchestrator.handle_info({:retry_issue, issue.id, token}, state)

    assert %{attempt: 2, failures: 3, held: true, timer_ref: nil} = result.retry_attempts[issue.id]
    assert MapSet.member?(result.claimed, issue.id)
    refute_receive {:linear_query, _}
  end

  test "manual retry remains an explicit dispatch override while paused" do
    issue = issue("retry-manual", "MT-MANUAL", "In Progress")
    endpoint = linear_endpoint(issue, by_id: issue)
    state = %{retry_state(issue, endpoint) | paused: true}

    {:reply, :ok, result} =
      Orchestrator.handle_call({:retry_issue_now, issue.id}, {self(), make_ref()}, state)

    assert %{retry_attempt: 2, failure_count: 3, pid: pid} = result.running[issue.id]
    assert is_pid(pid)
    refute Map.has_key?(result.retry_attempts, issue.id)
    Process.exit(pid, :kill)
  end

  defp issue(id, identifier, state) do
    %Issue{
      id: id,
      identifier: identifier,
      title: identifier,
      state: state,
      url: "https://example.org/#{identifier}",
      labels: [],
      blocked_by: []
    }
  end

  defp retry_state(issue, endpoint) do
    config = Config.settings!()
    tracker = %{config.tracker | endpoint: endpoint}
    workspace_root = Path.join(System.tmp_dir!(), "cymphony-retry-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    config = %{config | tracker: tracker, workspace: %{config.workspace | root: workspace_root}}
    token = make_ref()

    %State{
      config: config,
      max_concurrent_agents: 1,
      providers: [],
      claimed: MapSet.new([issue.id]),
      retry_attempts: %{
        issue.id => %{
          attempt: 2,
          failures: 3,
          identifier: issue.identifier,
          error: "agent exited",
          worker_host: nil,
          workspace_path: nil,
          retry_token: token,
          timer_ref: nil,
          due_at_ms: System.monotonic_time(:millisecond)
        }
      }
    }
  end

  defp linear_endpoint(issue, opts) do
    parent = self()
    by_id = Keyword.fetch!(opts, :by_id)
    poll = Keyword.get(opts, :poll, issue)

    plug = fn conn, _plug_opts ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      query = Jason.decode!(body)["query"]
      send(parent, {:linear_query, if(String.contains?(query, "CymphonyLinearIssuesById"), do: :by_id, else: :poll)})

      response =
        if String.contains?(query, "CymphonyLinearIssuesById") do
          by_id_response(by_id)
        else
          poll_response(poll)
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end

    server = start_supervised!({Bandit, plug: plug, port: 0, ip: {127, 0, 0, 1}, startup_log: false})
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}/graphql"
  end

  defp by_id_response(nil), do: %{"data" => %{"issues" => %{"nodes" => []}}}
  defp by_id_response({:error, reason}), do: %{"errors" => [%{"message" => reason}]}
  defp by_id_response(issue), do: %{"data" => %{"issues" => %{"nodes" => [linear_issue(issue)]}}}

  defp poll_response({:error, reason}), do: %{"errors" => [%{"message" => reason}]}

  defp poll_response(issue) do
    %{
      "data" => %{
        "issues" => %{
          "nodes" => [linear_issue(issue)],
          "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
        }
      }
    }
  end

  defp linear_issue(issue) do
    %{
      "id" => issue.id,
      "identifier" => issue.identifier,
      "title" => issue.title,
      "state" => %{"name" => issue.state},
      "url" => issue.url,
      "labels" => %{"nodes" => []},
      "inverseRelations" => %{"nodes" => []}
    }
  end
end
