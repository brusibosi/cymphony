defmodule CymphonyElixir.WorkspaceProcessOwnershipTest do
  use CymphonyElixir.TestSupport

  test "killing a hook owner also terminates its silent OS process" do
    {workspace, pidfile, config} = fixture(60_000)
    supervisor = start_supervised!(Task.Supervisor)

    worker =
      spawn(fn ->
        Workspace.run_before_run_hook(workspace, "HOOK-1", nil, config: config, port_supervisor: supervisor)
      end)

    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    os_pid = read_pid(pidfile)
    on_exit(fn -> kill(os_pid) end)
    Process.exit(worker, :kill)
    assert_dead(os_pid)
  end

  test "hook timeout tears down the child before returning the existing timeout result" do
    {workspace, pidfile, config} = fixture(100)
    supervisor = start_supervised!(Task.Supervisor)

    assert {:error, {:workspace_hook_timeout, "before_run", 100}} =
             Workspace.run_before_run_hook(workspace, "HOOK-1", nil,
               config: config,
               port_supervisor: supervisor
             )

    os_pid = read_pid(pidfile)
    on_exit(fn -> kill(os_pid) end)
    assert_dead(os_pid)
  end

  defp fixture(timeout) do
    workspace = Path.join(Path.dirname(Workflow.workflow_file_path()), "HOOK-1")
    File.mkdir_p!(workspace)
    pidfile = Path.join(workspace, "hook.pid")

    write_workflow_file!(Workflow.workflow_file_path(),
      hook_before_run: "printf '%s' $$ > '#{pidfile}'; exec /bin/sleep 60",
      hook_timeout_ms: timeout
    )

    {workspace, pidfile, Config.settings!()}
  end

  defp read_pid(path, attempts \\ 100)
  defp read_pid(_path, 0), do: flunk("hook never started")

  defp read_pid(path, attempts) do
    case File.read(path) do
      {:ok, pid} when byte_size(pid) > 0 ->
        pid

      _ ->
        Process.sleep(10)
        read_pid(path, attempts - 1)
    end
  end

  defp kill(pid), do: System.cmd("/bin/kill", ["-KILL", pid], stderr_to_stdout: true)
  defp assert_dead(pid, attempts \\ 100)
  defp assert_dead(pid, 0), do: flunk("task-created hook survived cleanup: #{pid}")

  defp assert_dead(pid, attempts) do
    case System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} ->
        Process.sleep(10)
        assert_dead(pid, attempts - 1)

      _ ->
        :ok
    end
  end
end
