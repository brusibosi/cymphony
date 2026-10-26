defmodule CymphonyElixir.Orchestrator.ReliabilityReplayTest do
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.{CompletionStore, ProjectSupervisor}
  alias CymphonyElixirWeb.Presenter

  @tag timeout: 30_000
  test "two native projects replay 200 issues and 90 retries through capacity, shared 429, quota, and stub recovery" do
    root = Path.dirname(Workflow.workflow_file_path())
    config_dir = Path.join(root, "config")
    File.mkdir_p!(config_dir)
    previous_dir = Application.fetch_env(:cymphony_elixir, :config_dir_override)
    previous_opts = Application.fetch_env(:cymphony_elixir, :linear_graphql_opts)
    Application.put_env(:cymphony_elixir, :config_dir_override, config_dir)
    assert :sys.get_state(CompletionStore).path == Application.fetch_env!(:cymphony_elixir, :completion_store_path)
    refute :sys.get_state(CompletionStore).path == Path.expand("~/.cymphony/sessions.db")

    suffix = System.unique_integer([:positive])
    projects = Enum.map(["alpha", "beta"], &{"replay-#{&1}-#{suffix}", &1})
    File.write!(Path.join(config_dir, "config.json"), Jason.encode!(%{projects: Enum.map(projects, fn {name, _} -> %{name: name, dispatch_paused: true} end)}))
    {:ok, clock} = start_supervised({Agent, fn -> 1_000_000 end}, id: :clock)
    Application.put_env(:cymphony_elixir, :linear_graphql_opts, rate_limit_now_fun: fn -> Agent.get(clock, & &1) end)
    {:ok, ledger} = start_supervised({Agent, fn -> %{requests: [], limited: false, completed: MapSet.new()} end}, id: :ledger)
    endpoint = endpoint(ledger, root)
    cli = Path.join(root, "stub-claude")
    launches = Path.join(root, "launches")

    File.write!(
      cli,
      """
      #!/bin/sh
      if ! mkdir ../.stub-active 2>/dev/null; then
        touch '#{root}/capacity-exceeded'
        exit 1
      fi
      trap 'rmdir ../.stub-active' EXIT
      echo "$PWD" >> '#{launches}'
      if [ -f '#{root}/quota-once' ] && [ "$(basename "$PWD")" = BETA-1 ]; then
        rm '#{root}/quota-once'
        printf '%s\\n' '{"type":"assistant","isApiErrorMessage":true,"error":"usage_limit_reached"}'
        exit 1
      fi
      sleep 0.05
      touch .stub-complete
      printf '%s\\n' '{"session_id":"offline-stub","result":"completed","usage":{"input_tokens":1,"output_tokens":1}}'
      """
    )

    File.chmod!(cli, 0o755)

    on_exit(fn ->
      Enum.each(projects, fn {name, _} -> ProjectSupervisor.stop_project(name) end)
      restore_app(:config_dir_override, previous_dir)
      restore_app(:linear_graphql_opts, previous_opts)
    end)

    actors =
      Enum.map(projects, fn {name, slug} ->
        workflow = Path.join(root, "#{slug}.md")

        write_workflow_file!(workflow,
          tracker_kind: "linear",
          tracker_endpoint: endpoint,
          tracker_project_slug: slug,
          tracker_api_key: "offline-shared-key",
          workspace_root: Path.join(root, slug),
          claude_command: cli,
          max_concurrent_agents: 1,
          max_turns: 1,
          poll_interval_ms: 60_000
        )

        assert :ok = ProjectSupervisor.start_project(name, workflow)
        pid = ProjectSupervisor.lookup(name, :orchestrator)
        {name, slug, pid}
      end)

    eventually(fn ->
      Enum.all?(actors, fn {_, _, pid} ->
        state = :sys.get_state(pid)
        state.paused and length(state.waiting) == 100 and map_size(state.work.io_jobs) == 0
      end)
    end)

    initial_calls = requests(ledger)
    assert Enum.count(initial_calls, fn {kind, vars} -> kind == :poll and vars["after"] == "50" end) == 2
    refute File.exists?(launches)

    Enum.each(actors, fn {_, slug, pid} ->
      :sys.replace_state(pid, fn state ->
        retries =
          Map.new(1..45, fn index ->
            id = "#{slug}-#{index}"

            {id,
             %{
               attempt: 2,
               failures: 3,
               identifier: identifier(slug, index),
               timer_ref: nil,
               retry_token: make_ref(),
               due_at_ms: System.monotonic_time(:millisecond),
               worker_host: nil,
               workspace_path: nil
             }}
          end)

        %{state | paused: false, running: %{"busy" => %{issue: %Issue{id: "busy", state: "In Progress"}, worker_host: nil}}, retry_attempts: retries, claimed: MapSet.new(Map.keys(retries))}
      end)

      fire_retries(pid)
      assert_retry_ownership(pid, :capacity)
      cancel_retry_timers(pid)
    end)

    assert requests(ledger) == initial_calls
    refute File.exists?(launches)

    Agent.update(ledger, &%{&1 | limited: true})
    {_, _, first} = hd(actors)
    config = :sys.get_state(first).config
    assert {:error, {:linear_api_status, 429}} = Client.fetch_candidate_issues(config)
    assert {:error, {:linear_rate_limited, 1_060_000}} = Client.fetch_candidate_issues(config)
    limited_calls = requests(ledger)
    assert length(limited_calls) == length(initial_calls) + 1

    Enum.each(actors, fn {_, _, pid} ->
      :sys.replace_state(pid, &%{&1 | running: %{}})
      fire_retries(pid)
      assert_retry_ownership(pid, :rate_limit)
      cancel_retry_timers(pid)
    end)

    assert requests(ledger) == limited_calls
    refute File.exists?(launches)

    Agent.update(clock, fn _ -> 1_060_001 end)
    File.touch!(Path.join(root, "quota-once"))

    Enum.each(actors, fn {_, slug, pid} ->
      id = "#{slug}-1"
      retry = :sys.get_state(pid).retry_attempts[id]
      send(pid, {:retry_issue, id, retry.retry_token})
      send(pid, {:retry_issue, id, retry.retry_token})
    end)

    [{_, _, alpha}, {_, _, beta}] = actors

    eventually(fn ->
      Orchestrator.snapshot(alpha, 1_000).completed_count == 1 and
        match?(%{held: true, hold_reason: :quota}, :sys.get_state(beta).retry_attempts["beta-1"])
    end)

    held = :sys.get_state(beta).retry_attempts["beta-1"]
    assert held.failures == 3
    assert held.timer_ref == nil
    Enum.each(1..8, fn _ -> send(beta, :watchdog) end)
    :sys.get_state(beta)
    assert length(File.read!(launches) |> String.split("\n", trim: true)) == 2
    assert :ok = GenServer.call(beta, {:retry_issue_now, "beta-1"})
    eventually(fn -> Enum.all?(actors, fn {_, _, pid} -> Orchestrator.snapshot(pid, 1_000).completed_count == 1 end) end)
    assert :sys.get_state(beta).provider_holds == %{}
    refute File.exists?(Path.join(root, "capacity-exceeded"))
    assert length(File.read!(launches) |> String.split("\n", trim: true)) == 3
    assert Agent.get(ledger, &MapSet.size(&1.completed)) == 2

    recovery_calls = Enum.drop(requests(ledger), length(limited_calls))
    assert recovery_calls != []

    assert Enum.all?(recovery_calls, fn {kind, vars} ->
             kind == :by_id and vars["projectSlug"] in ["alpha", "beta"] and vars["ids"] == ["#{vars["projectSlug"]}-1"]
           end)

    Enum.each(actors, fn {_, _, pid} ->
      state = :sys.get_state(pid)
      assert map_size(state.running) <= 1
      assert map_size(state.retry_attempts) == 44
      assert MapSet.size(state.claimed) == 44
      assert Enum.all?(state.retry_attempts, fn {_, retry} -> retry.attempt == 2 and retry.failures == 3 end)
    end)

    assert Presenter.state_payload(first, 1_000).counts.completed == 2
    assert :ok = GenServer.call(alpha, :pause)
    assert :ok = GenServer.call(alpha, :resume)
    assert :ok = GenServer.call(beta, :resume)
    assert Orchestrator.snapshot(alpha, 1_000).completed_count == 0
    assert Orchestrator.snapshot(beta, 1_000).completed_count == 1
    assert Presenter.state_payload(first, 1_000).counts.completed == 1
    Enum.each(actors, fn {_, _, pid} -> assert :ok = GenServer.call(pid, :pause) end)
  end

  defp fire_retries(pid) do
    Enum.each(:sys.get_state(pid).retry_attempts, fn {id, retry} -> send(pid, {:retry_issue, id, retry.retry_token}) end)
    :sys.get_state(pid)
  end

  defp assert_retry_ownership(pid, reason) do
    state = :sys.get_state(pid)
    assert map_size(state.retry_attempts) == 45
    assert MapSet.size(state.claimed) == 45
    assert state.work.io_jobs == %{}
    assert Enum.all?(state.retry_attempts, fn {_, retry} -> retry.attempt == 2 and retry.failures == 3 and retry.wait_reason == reason end)
  end

  defp cancel_retry_timers(pid) do
    :sys.replace_state(pid, fn state ->
      Enum.each(state.retry_attempts, fn {_, entry} -> if is_reference(entry.timer_ref), do: Process.cancel_timer(entry.timer_ref) end)
      %{state | retry_attempts: Map.new(state.retry_attempts, fn {id, entry} -> {id, %{entry | timer_ref: nil}} end)}
    end)
  end

  defp endpoint(ledger, root) do
    plug = fn conn, _ ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"query" => query, "variables" => vars} = Jason.decode!(body)
      kind = if String.contains?(query, "CymphonyLinearIssuesById"), do: :by_id, else: :poll

      limited =
        Agent.get_and_update(ledger, fn state ->
          {state.limited, %{state | limited: false, requests: state.requests ++ [{kind, vars}]}}
        end)

      if limited do
        conn |> Plug.Conn.put_resp_header("retry-after", "60") |> Plug.Conn.send_resp(429, "{}")
      else
        response = response(ledger, root, kind, vars)

        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end
    end

    server = start_supervised!({Bandit, plug: plug, port: 0, ip: {127, 0, 0, 1}, startup_log: false})
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}/graphql"
  end

  defp response(ledger, root, kind, vars) do
    nodes = linear_nodes(ledger, root, vars["projectSlug"])
    selected = select_nodes(nodes, kind, vars)
    offset = if vars["after"], do: String.to_integer(vars["after"]), else: 0
    page = Enum.slice(selected, offset, vars["first"])
    more = offset + length(page) < length(selected)
    %{"data" => %{"issues" => %{"nodes" => page, "pageInfo" => %{"hasNextPage" => more, "endCursor" => if(more, do: "#{offset + length(page)}", else: nil)}}}}
  end

  defp select_nodes(nodes, :by_id, vars), do: Enum.filter(nodes, &(&1["id"] in vars["ids"]))
  defp select_nodes(nodes, :poll, vars), do: Enum.filter(nodes, &(&1["state"]["name"] in vars["stateNames"]))

  defp linear_nodes(ledger, root, slug) do
    for index <- 1..100 do
      id = "#{slug}-#{index}"
      done = File.exists?(Path.join([root, slug, identifier(slug, index), ".stub-complete"])) or Agent.get(ledger, &MapSet.member?(&1.completed, id))
      if done, do: Agent.update(ledger, &%{&1 | completed: MapSet.put(&1.completed, id)})

      %{
        "id" => id,
        "identifier" => identifier(slug, index),
        "title" => "Offline replay #{id}",
        "state" => %{"name" => if(done, do: "Done", else: "In Progress"), "type" => if(done, do: "completed", else: "started")},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end
  end

  defp requests(ledger), do: Agent.get(ledger, & &1.requests)
  defp identifier(slug, index), do: "#{String.upcase(slug)}-#{index}"
  defp restore_app(key, {:ok, value}), do: Application.put_env(:cymphony_elixir, key, value)
  defp restore_app(key, :error), do: Application.delete_env(:cymphony_elixir, key)
  defp eventually(fun, attempts \\ 600)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
