defmodule CymphonyElixir.Agent.PortGuardTest do
  use ExUnit.Case

  alias CymphonyElixir.Agent.PortGuard

  test "owner crash kills a silent CLI and its wrapper children" do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    owner =
      spawn(fn ->
        result =
          PortGuard.open(supervisor, fn ->
            {:ok,
             Port.open({:spawn_executable, ~c"/bin/sh"}, [
               :binary,
               :exit_status,
               args: [~c"-c", ~c"sleep 60 & echo $!; wait"]
             ])}
          end)

        send(parent, {:opened, result})

        receive do
          {port, {:data, data}} -> send(parent, {:child, port, String.trim(data)})
        end

        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    assert_receive {:opened, {:ok, port, guard}}, 1_000
    assert_receive {:child, ^port, child}, 1_000
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      kill(os_pid)
      kill(child)
    end)

    monitored_guard = guard_pid(guard)
    ref = Process.monitor(monitored_guard)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^monitored_guard, :normal}, 2_000
    assert_dead(os_pid)
    assert_dead(child)
  end

  test "supervisor shutdown is a barrier for live CLI cleanup" do
    supervisor = start_supervised!(Task.Supervisor)
    assert {:ok, port, guard} = PortGuard.open(supervisor, &sleep_port/0)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> kill(os_pid) end)
    Supervisor.stop(supervisor)
    refute Process.alive?(guard_pid(guard))
    assert_dead(os_pid)
  end

  test "normal CLI exit keeps protocol and close is idempotent" do
    supervisor = start_supervised!(Task.Supervisor)

    assert {:ok, port, guard} =
             PortGuard.open(supervisor, fn ->
               {:ok,
                Port.open({:spawn_executable, ~c"/bin/sh"}, [
                  :binary,
                  :exit_status,
                  args: [~c"-c", ~c"printf ready"]
                ])}
             end)

    assert_receive {^port, {:data, "ready"}}, 1_000
    assert_receive {^port, {:exit_status, 0}}, 1_000
    assert :ok = PortGuard.close(guard)
    assert :ok = PortGuard.close(guard)
    assert Process.alive?(self())
  end

  test "a CLI which exits before opener returns still forwards its exit" do
    supervisor = start_supervised!(Task.Supervisor)

    assert {:ok, port, guard} =
             PortGuard.open(supervisor, fn ->
               port = Port.open({:spawn_executable, ~c"/usr/bin/true"}, [:binary, :exit_status])
               Process.sleep(50)
               {:ok, port}
             end)

    assert_receive {^port, {:exit_status, 0}}, 1_000
    assert :ok = PortGuard.finish(guard)
  end

  test "guard crash fails collection promptly and still kills the tracked OS process" do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    owner =
      spawn(fn ->
        result =
          PortGuard.run(
            supervisor,
            fn ->
              {:ok, port} = sleep_port()
              {:os_pid, pid} = Port.info(port, :os_pid)
              send(parent, {:guard_ready, self(), pid})
              {:ok, port}
            end,
            10_000
          )

        send(parent, {:guard_result, result})
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    assert_receive {:guard_ready, guard, os_pid}, 1_000
    on_exit(fn -> kill(os_pid) end)
    Process.sleep(30)
    Process.exit(guard_pid(guard), :kill)
    assert_receive {:guard_result, {:error, {:port_guard_exit, :killed}}}, 1_000
    assert_dead(os_pid)
  end

  test "owner cleanup stops only the requested owner's guards" do
    supervisor = start_supervised!(Task.Supervisor)
    {:ok, port, guard} = PortGuard.open(supervisor, &sleep_port/0)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> kill(os_pid) end)

    unrelated =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert :ok = PortGuard.stop_owner(supervisor, unrelated)
    assert Process.alive?(guard_pid(guard))
    send(unrelated, :stop)
    assert :ok = PortGuard.stop_owner(supervisor, self())
    refute Process.alive?(guard_pid(guard))
    assert_dead(os_pid)
  end

  test "owner cleanup reports an unresponsive guard without pretending it stopped" do
    supervisor = start_supervised!(Task.Supervisor)
    {:ok, port, guard} = PortGuard.open(supervisor, &sleep_port/0)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> kill(os_pid) end)
    :sys.suspend(guard_pid(guard))

    try do
      assert {:error, {:port_cleanup_failed, _}} = PortGuard.stop_owner(supervisor, self())
    after
      :sys.resume(guard_pid(guard))
    end

    assert :ok = PortGuard.stop_owner(supervisor, self())
    assert_dead(os_pid)
  end

  test "owner cleanup tolerates a guard disappearing during the owner lookup" do
    supervisor = start_supervised!(Task.Supervisor)

    {:ok, _racing_guard} =
      Task.Supervisor.start_child(supervisor, fn ->
        receive do
          {:"$gen_call", _from, :owner} -> exit(:normal)
        end
      end)

    assert :ok = PortGuard.stop_owner(supervisor, self())
  end

  test "collection preserves stdout with EOF and nonzero exit status" do
    supervisor = start_supervised!(Task.Supervisor)
    collector = self()

    assert {:ok, {"diagnostic", 7}} =
             PortGuard.run(
               supervisor,
               fn ->
                 port =
                   Port.open(
                     {:spawn_executable, ~c"/bin/sh"},
                     [:binary, :exit_status, args: [~c"-c", ~c"printf diagnostic; exec 1>&- 2>&-; sleep 0.05; exit 7"]]
                   )

                 # Exercise the valid EOF-before-status ordering without depending on scheduler races.
                 send(collector, {port, :eof})
                 {:ok, port}
               end,
               1_000
             )

    refute_received {_port, :eof}
    assert {:error, :not_available} = PortGuard.run(supervisor, fn -> {:error, :not_available} end, 10)
  end

  test "guard closes a port without exit-status notifications within its reap budget" do
    supervisor = start_supervised!(Task.Supervisor)

    {:ok, port, guard} =
      PortGuard.open(supervisor, fn ->
        {:ok, Port.open({:spawn_executable, ~c"/bin/sleep"}, [:binary, args: [~c"60"]])}
      end)

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> kill(os_pid) end)
    assert :ok = PortGuard.close(guard)
    assert_dead(os_pid)
  end

  test "readiness handshake captures the group before a fast wrapper exits" do
    supervisor = start_supervised!(Task.Supervisor)
    command = "sleep 60 & echo $!; exit 0"

    parent = self()

    assert {:ok, port, guard} =
             PortGuard.open(
               supervisor,
               fn ->
                 port =
                   Port.open(
                     {:spawn_executable, ~c"/bin/sh"},
                     [:binary, :exit_status, args: [~c"-c", String.to_charlist(PortGuard.prepare(command))]]
                   )

                 {:os_pid, wrapper_pid} = Port.info(port, :os_pid)
                 send(parent, {:wrapper_pid, wrapper_pid})
                 Process.sleep(50)
                 {:ok, port}
               end,
               handshake: true
             )

    assert_receive {^port, {:data, child}}, 1_000
    child = String.trim(child)
    on_exit(fn -> kill(child) end)
    assert_receive {:wrapper_pid, wrapper_pid}, 1_000
    assert_dead(wrapper_pid)
    assert :ok = PortGuard.close(guard)
    assert_dead(child)
  end

  test "owner death during readiness does not release the actual shell command" do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()
    marker = Path.join(System.tmp_dir!(), "cymphony-guard-marker-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(marker) end)

    owner =
      spawn(fn ->
        PortGuard.open(
          supervisor,
          fn ->
            command = PortGuard.prepare("touch '#{marker}'; exec /bin/sleep 60")

            port =
              Port.open(
                {:spawn_executable, ~c"/bin/sh"},
                [:binary, :exit_status, args: [~c"-c", String.to_charlist(command)]]
              )

            {:os_pid, pid} = Port.info(port, :os_pid)
            send(parent, {:starting_guard, self(), pid})

            receive do
              :release_initialization -> :ok
            end

            {:ok, port}
          end,
          handshake: true
        )
      end)

    assert_receive {:starting_guard, guard, os_pid}, 1_000
    on_exit(fn -> kill(os_pid) end)
    monitored_guard = guard_pid(guard)
    ref = Process.monitor(monitored_guard)
    Process.exit(owner, :kill)
    send(guard_pid(guard), :release_initialization)
    assert_receive {:DOWN, ^ref, :process, ^monitored_guard, :normal}, 1_000
    assert_dead(os_pid)
    refute File.exists?(marker)
  end

  test "abnormal port exit completes collection instead of hanging after readiness" do
    supervisor = start_supervised!(Task.Supervisor)
    {:ok, port, guard} = PortGuard.open(supervisor, &sleep_port/0)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> kill(os_pid) end)
    send(guard_pid(guard), {:EXIT, port, :epipe})
    assert_receive {^port, {:exit_status, 1}}, 1_000
    assert :ok = PortGuard.close(guard)
    assert_dead(os_pid)
  end

  test "owner handle retains a fast wrapper group after the port has closed" do
    supervisor = start_supervised!(Task.Supervisor)
    command = PortGuard.prepare("sleep 60 >/dev/null 2>&1 & echo $!; exit 0")

    {:ok, port, guard} =
      PortGuard.open(
        supervisor,
        fn ->
          {:ok,
           Port.open(
             {:spawn_executable, ~c"/bin/sh"},
             [:binary, :exit_status, args: [~c"-c", String.to_charlist(command)]]
           )}
        end,
        handshake: true
      )

    assert_receive {^port, {:data, child}}, 1_000
    child = String.trim(child)
    on_exit(fn -> kill(child) end)
    assert_receive {^port, {:exit_status, 0}}, 1_000
    assert Port.info(port) == nil
    watch = guard
    monitored_guard = guard_pid(guard)
    Process.exit(monitored_guard, :kill)
    assert_receive {:DOWN, ref, :process, ^monitored_guard, :killed}, 1_000
    assert ref == watch.ref
    assert :ok = PortGuard.finish(watch)
    assert_dead(child)
  end

  test "a failed spawn propagates without leaving a guard child" do
    supervisor = start_supervised!(Task.Supervisor)
    assert {:error, :not_available} = PortGuard.open(supervisor, fn -> {:error, :not_available} end)
    assert DynamicSupervisor.count_children(supervisor).active == 0
  end

  defp guard_pid(%{guard: pid}), do: pid
  defp guard_pid(pid), do: pid

  defp sleep_port do
    {:ok, Port.open({:spawn_executable, ~c"/bin/sleep"}, [:binary, :exit_status, args: [~c"60"]])}
  end

  defp kill(pid), do: System.cmd("/bin/kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)

  defp assert_dead(pid, attempts \\ 100)
  defp assert_dead(pid, 0), do: flunk("task-created OS process survived cleanup: #{pid}")

  defp assert_dead(pid, attempts) do
    case System.cmd("/bin/kill", ["-0", to_string(pid)], stderr_to_stdout: true) do
      {_, 0} ->
        Process.sleep(10)
        assert_dead(pid, attempts - 1)

      _ ->
        :ok
    end
  end
end
