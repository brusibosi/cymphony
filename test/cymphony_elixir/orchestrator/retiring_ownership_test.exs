defmodule CymphonyElixir.Orchestrator.RetiringOwnershipTest do
  use CymphonyElixir.TestSupport

  test "agent DOWN retains the old owner's barrier before manual retry" do
    {orchestrator, pidfile} = runtime()
    {worker, guard} = suspend_running_guard(orchestrator)
    old_pid = hd(cli_pids(pidfile))

    try do
      Process.exit(worker, :kill)
      eventually(fn -> Map.has_key?(:sys.get_state(orchestrator).retry_attempts, "retire-a") end)
      :ok = Orchestrator.pause(orchestrator)
      assert :ok = GenServer.call(orchestrator, {:retry_issue_now, "retire-a"}, 100)
      eventually(fn -> not intent_active?(orchestrator, "retire-a") end)
      assert Orchestrator.snapshot(orchestrator, 100).running == []
      assert cli_pids(pidfile) == [old_pid]
      assert alive?(old_pid)
    after
      resume_guard(guard)
    end

    eventually(fn -> length(cli_pids(pidfile)) == 2 end)
    refute alive?(old_pid)
    assert [%{issue_id: "retire-a"}] = Orchestrator.snapshot(orchestrator, 100).running
  end

  for failure <- [:crash, :timeout] do
    test "a #{failure} of the stop worker cannot authorize a replacement" do
      {orchestrator, pidfile} = runtime()
      {_worker, guard} = suspend_running_guard(orchestrator)
      old_pid = hd(cli_pids(pidfile))

      try do
        assert :ok = Orchestrator.set_issue_run_spec(orchestrator, "retire-a", %{})
        job = stop_job(orchestrator)

        case unquote(failure) do
          :crash -> Process.exit(job.pid, :kill)
          :timeout -> send(orchestrator, {:io_timeout, job.ref})
        end

        eventually(fn -> Orchestrator.snapshot(orchestrator, 100).polling.cleanup_error end)
        assert Orchestrator.snapshot(orchestrator, 100).running == []
        assert cli_pids(pidfile) == [old_pid]
        assert alive?(old_pid)
        assert Orchestrator.snapshot(orchestrator, 100).polling.cleanup_error
      after
        resume_guard(guard)
      end

      eventually(fn -> length(cli_pids(pidfile)) == 2 end)
      refute alive?(old_pid)
    end
  end

  test "a crashed I/O worker has one reaper even when its old timeout arrives" do
    {orchestrator, pidfile} = runtime()
    {_worker, guard} = suspend_running_guard(orchestrator)

    try do
      assert :ok = Orchestrator.set_issue_run_spec(orchestrator, "retire-a", %{})
      job = stop_job(orchestrator)
      Process.exit(job.pid, :kill)

      eventually(fn ->
        Enum.any?(:sys.get_state(orchestrator).work.io_jobs, fn {_ref, current} ->
          current.key == {:reap, job.ref}
        end)
      end)

      assert Process.read_timer(job.timer) == false
      send(orchestrator, {:io_timeout, job.ref})

      assert Enum.count(:sys.get_state(orchestrator).work.io_jobs, fn {_ref, current} ->
               current.key == {:reap, job.ref}
             end) == 1
    after
      resume_guard(guard)
    end

    eventually(fn -> length(cli_pids(pidfile)) == 2 end)
  end

  test "retiring OS processes reserve global capacity until positive reap" do
    {orchestrator, pidfile} = runtime(max_concurrent_agents: 1)
    {_worker, guard} = suspend_running_guard(orchestrator)
    old_pid = hd(cli_pids(pidfile))
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue("a"), issue("b")])

    try do
      assert :ok = Orchestrator.set_issue_run_spec(orchestrator, "retire-a", %{})
      :ok = Orchestrator.run_poll_cycle_for_test(orchestrator)
      assert Orchestrator.snapshot(orchestrator, 100).running == []
      assert cli_pids(pidfile) == [old_pid]
    after
      resume_guard(guard)
    end

    eventually(fn -> length(cli_pids(pidfile)) == 2 end)

    assert %{running: [%{issue_id: "retire-a"}], polling: %{max_concurrent_agents: 1}} =
             Orchestrator.snapshot(orchestrator, 100)

    refute alive?(old_pid)
  end

  test "retiring OS processes reserve their per-state slot without blocking another state" do
    {orchestrator, pidfile} =
      runtime(max_concurrent_agents: 2, max_concurrent_agents_by_state: %{"In Progress" => 1})

    {_worker, guard} = suspend_running_guard(orchestrator)
    other_state = %{issue("c") | state: "Todo"}
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue("a"), issue("b"), other_state])

    try do
      assert :ok = Orchestrator.set_issue_run_spec(orchestrator, "retire-a", %{})
      :ok = Orchestrator.run_poll_cycle_for_test(orchestrator)
      assert [%{issue_id: "retire-c"}] = Orchestrator.snapshot(orchestrator, 100).running
    after
      resume_guard(guard)
    end

    eventually(fn -> Map.has_key?(:sys.get_state(orchestrator).running, "retire-a") end)
    assert Enum.sort(Map.keys(:sys.get_state(orchestrator).running)) == ["retire-a", "retire-c"]
    eventually(fn -> length(cli_pids(pidfile)) == 3 end)
  end

  test "retiring remote-client processes continue reserving their per-host slot" do
    root = Path.dirname(Workflow.workflow_file_path())
    fake_ssh = Path.join(root, "ssh")
    old_path = System.get_env("PATH")
    File.write!(fake_ssh, "#!/bin/sh\nfor arg do command=$arg; done\nexec /bin/sh -c \"$command\"\n")
    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", root <> ":" <> (old_path || ""))
    on_exit(fn -> restore_env("PATH", old_path) end)

    {orchestrator, pidfile} =
      runtime(
        max_concurrent_agents: 2,
        worker_ssh_hosts: ["worker-a"],
        worker_max_concurrent_agents_per_host: 1
      )

    {_worker, guard} = suspend_running_guard(orchestrator)
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue("a"), issue("b")])

    try do
      assert :ok = Orchestrator.set_issue_run_spec(orchestrator, "retire-a", %{})
      :ok = Orchestrator.run_poll_cycle_for_test(orchestrator)
      assert Orchestrator.snapshot(orchestrator, 100).running == []
    after
      resume_guard(guard)
    end

    eventually(fn -> Map.has_key?(:sys.get_state(orchestrator).running, "retire-a") end)

    assert [%{issue_id: "retire-a", worker_host: "worker-a"}] =
             Orchestrator.snapshot(orchestrator, 100).running

    eventually(fn -> length(cli_pids(pidfile)) == 2 end)
  end

  test "deferred restarts recheck lowered concurrency and retain intent until a slot opens" do
    {orchestrator, pidfile} = runtime(max_concurrent_agents: 2)
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue("a"), issue("b")])
    :ok = Orchestrator.run_poll_cycle_for_test(orchestrator)
    eventually(fn -> map_size(:sys.get_state(orchestrator).running) == 2 end)
    eventually(fn -> length(cli_pids(pidfile)) == 2 end)
    {_worker, guard} = suspend_running_guard(orchestrator)

    try do
      assert :ok = Orchestrator.set_issue_run_spec(orchestrator, "retire-a", %{})
      assert :ok = Orchestrator.set_concurrency(orchestrator, 1)
    after
      resume_guard(guard)
    end

    eventually(fn -> not stop_active?(orchestrator) end)
    assert [%{issue_id: "retire-b"}] = Orchestrator.snapshot(orchestrator, 100).running
    assert Map.has_key?(:sys.get_state(orchestrator).work.restarts, "retire-a")
    assert :ok = Orchestrator.pause(orchestrator)
    assert :ok = GenServer.call(orchestrator, {:kill_issue, "retire-b"}, 100)
    eventually(fn -> Map.has_key?(:sys.get_state(orchestrator).running, "retire-a") end)
    assert [%{issue_id: "retire-a"}] = Orchestrator.snapshot(orchestrator, 100).running
    eventually(fn -> length(cli_pids(pidfile)) == 3 end)
  end

  test "deferred restart waits for a live retention cleanup effect" do
    {orchestrator, pidfile} = runtime()
    root = Path.dirname(Workflow.workflow_file_path())
    started = Path.join(root, "sweep-started")
    release = Path.join(root, "sweep-release")
    stale = Path.join(:sys.get_state(orchestrator).config.workspace.root, "stale")
    File.mkdir_p!(stale)
    File.touch!(stale, System.os_time(:second) - 172_800)
    command = "touch '#{started}'; while [ ! -f '#{release}' ]; do sleep 0.02; done"

    :sys.replace_state(orchestrator, fn state ->
      config = %{
        state.config
        | workspace: %{state.config.workspace | retention_days: 1},
          hooks: %{state.config.hooks | before_remove: command}
      }

      %{state | config: config}
    end)

    send(orchestrator, :workspace_sweep)
    eventually(fn -> File.exists?(started) end)

    try do
      assert :ok = Orchestrator.set_issue_run_spec(orchestrator, "retire-a", %{})
      eventually(fn -> not stop_active?(orchestrator) end)
      assert Orchestrator.snapshot(orchestrator, 100).running == []
      assert length(cli_pids(pidfile)) == 1
      assert Map.has_key?(:sys.get_state(orchestrator).work.restarts, "retire-a")
      assert :ok = Orchestrator.pause(orchestrator)
    after
      File.write!(release, "continue")
    end

    eventually(fn -> length(cli_pids(pidfile)) == 2 end)
    assert [%{issue_id: "retire-a"}] = Orchestrator.snapshot(orchestrator, 100).running
    refute File.exists?(stale)
  end

  for metadata <- [:known, :pending] do
    test "retention protects retiring workspace and sibling log with #{metadata} metadata until positive reap" do
      root = Path.dirname(Workflow.workflow_file_path())
      physical_root = Path.join(root, "physical-workspaces")
      File.mkdir_p!(physical_root)
      File.ln_s!(physical_root, Path.join(root, "workspaces"))
      pidfile = Path.join(root, "retiring-cli.pids")

      opts =
        if unquote(metadata) == :pending,
          do: [hook_after_create: "echo $$ >> '#{pidfile}'; exec /bin/sleep 60"],
          else: []

      {orchestrator, pidfile} = runtime(opts)
      {worker, guard} = suspend_running_guard(orchestrator)
      old_pid = hd(cli_pids(pidfile))
      workspace = Path.join(root, "workspaces/RETIRE-A")
      log = Path.join(root, "workspaces/.agy-RETIRE-A.log")
      File.write!(log, "local session diagnostic")
      for path <- [workspace, log], do: File.touch!(path, System.os_time(:second) - 172_800)

      :sys.replace_state(orchestrator, fn state ->
        %{state | config: %{state.config | workspace: %{state.config.workspace | retention_days: 1}}}
      end)

      try do
        if unquote(metadata) == :pending do
          assert :sys.get_state(orchestrator).running["retire-a"].workspace_path == nil
        end

        assert :ok = GenServer.call(orchestrator, {:kill_issue, "retire-a"}, 100)
        eventually(fn -> not Process.alive?(worker) end)
        send(orchestrator, :workspace_sweep)
        eventually(fn -> not sweep_active?(orchestrator) end)
        assert :ok = GenServer.call(orchestrator, :pause, 100)
        assert Orchestrator.snapshot(orchestrator, 100).running == []
        assert map_size(:sys.get_state(orchestrator).work.retiring) == 1
        assert alive?(old_pid)
        assert File.dir?(workspace)
        assert File.exists?(log)
      after
        resume_guard(guard)
      end

      eventually(fn -> map_size(:sys.get_state(orchestrator).work.retiring) == 0 end)
      refute alive?(old_pid)
      send(orchestrator, :workspace_sweep)
      eventually(fn -> not File.exists?(workspace) and not File.exists?(log) end)
    end
  end

  defp sweep_active?(orchestrator) do
    state = :sys.get_state(orchestrator)

    Map.has_key?(state.work.effect_queue, :sweep) or
      Enum.any?(state.work.io_jobs, fn {_ref, job} -> job.key == {:effect, :sweep} end)
  end

  defp runtime(opts \\ []) do
    root = Path.dirname(Workflow.workflow_file_path())
    pidfile = Path.join(root, "retiring-cli.pids")
    cli = Path.join(root, "retiring-cli")
    File.write!(cli, "#!/bin/sh\necho $$ >> '#{pidfile}'\nexec /bin/sleep 60\n")
    File.chmod!(cli, 0o755)
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue("a")])

    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "memory",
          workspace_root: Path.join(root, "workspaces"),
          claude_command: cli,
          max_concurrent_agents: 1,
          poll_interval_ms: 60_000
        ],
        opts
      )
    )

    orchestrator = start_supervised!({Orchestrator, name: nil})

    on_exit(fn ->
      if Process.alive?(orchestrator), do: GenServer.stop(orchestrator)
      for pid <- cli_pids(pidfile), do: System.cmd("/bin/kill", ["-KILL", pid], stderr_to_stdout: true)
    end)

    eventually(fn -> length(cli_pids(pidfile)) == 1 end)
    :ok = Orchestrator.run_poll_cycle_for_test(orchestrator)
    {orchestrator, pidfile}
  end

  defp issue(suffix),
    do: %Issue{
      id: "retire-#{suffix}",
      identifier: "RETIRE-#{String.upcase(suffix)}",
      title: "Retiring ownership",
      state: "In Progress",
      labels: [],
      blocked_by: []
    }

  defp suspend_running_guard(orchestrator) do
    state = :sys.get_state(orchestrator)
    worker = state.running["retire-a"].pid

    guard =
      eventually(fn ->
        find_guard(state.port_supervisor, worker)
      end)

    :sys.suspend(guard)
    {worker, guard}
  end

  defp find_guard(supervisor, owner) do
    Enum.find_value(DynamicSupervisor.which_children(supervisor), fn {_, pid, _, _} ->
      if GenServer.call(pid, :owner) == owner, do: pid
    end)
  end

  defp resume_guard(guard) do
    if Process.alive?(guard), do: :sys.resume(guard)
  catch
    :exit, _ -> :ok
  end

  defp stop_job(orchestrator) do
    Enum.find_value(:sys.get_state(orchestrator).work.io_jobs, fn {_ref, job} ->
      if job.key == {:effect, {:stop, "retire-a"}}, do: job
    end)
  end

  defp stop_active?(orchestrator) do
    state = :sys.get_state(orchestrator)
    stop_job(orchestrator) != nil or Map.has_key?(state.work.effect_queue, {:stop, "retire-a"})
  end

  defp intent_active?(orchestrator, id), do: Map.has_key?(:sys.get_state(orchestrator).work.intent_jobs, id)
  defp alive?(pid), do: elem(System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true), 1) == 0

  defp cli_pids(path) do
    case File.read(path) do
      {:ok, data} -> String.split(data, "\n", trim: true)
      _ -> []
    end
  end

  defp eventually(fun, attempts \\ 500)
  defp eventually(fun, 0), do: flunk("condition never became true: #{inspect(fun.())}")

  defp eventually(fun, attempts) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _ ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
