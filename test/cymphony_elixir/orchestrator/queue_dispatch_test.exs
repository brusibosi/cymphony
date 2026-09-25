defmodule CymphonyElixir.Orchestrator.QueueDispatchTest do
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig

  test "snapshot.waiting is empty before any fetch" do
    pid = start_queue_orchestrator(:EmptyWaiting)

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.waiting == []
  end

  test "slots==0 still fills snapshot.waiting without claiming" do
    pid = start_queue_orchestrator(:SlotsZero, slots: 0)

    urgent = issue("iss-u", "MT-U", priority: 1, created_at: ~U[2026-01-02 00:00:00Z])
    later = issue("iss-l", "MT-L", priority: 3, created_at: ~U[2026-01-01 00:00:00Z])
    put_issues([later, urgent])
    poll(pid)

    snapshot = GenServer.call(pid, :snapshot)
    assert Enum.map(snapshot.waiting, & &1.identifier) == ["MT-U", "MT-L"]
    assert snapshot.running == []
    assert Enum.all?(snapshot.waiting, &(&1.agent_kind == nil))
    assert :sys.get_state(pid).claimed == MapSet.new()
  end

  test "dispatch follows persisted order, not a fresh sort_for_dispatch" do
    project_name = "queue-persist-#{System.unique_integer([:positive])}"

    with_config_dir(fn _tmp ->
      :ok =
        CymphonyConfig.save(%{
          "projects" => [
            %{
              "name" => project_name,
              "linear_project_slug" => "demo",
              "queue_order" => ["MT-LOW", "MT-URGENT"],
              "queue_priority_seen" => %{"MT-LOW" => 4, "MT-URGENT" => 1}
            }
          ]
        })

      pid = start_queue_orchestrator(:PersistOrder, slots: 1, project_name: project_name)

      urgent = issue("iss-urgent", "MT-URGENT", priority: 1, created_at: ~U[2026-01-01 00:00:00Z])
      low = issue("iss-low", "MT-LOW", priority: 4, created_at: ~U[2026-01-01 00:00:00Z])
      put_issues([urgent, low])
      poll(pid)

      snapshot = GenServer.call(pid, :snapshot)
      assert Enum.map(snapshot.running, & &1.identifier) == ["MT-LOW"]
      assert Enum.map(snapshot.waiting, & &1.identifier) == ["MT-URGENT"]
    end)
  end

  test "dispatch follows drag order, not a fresh sort_for_dispatch" do
    pid = start_queue_orchestrator(:DragOrder, slots: 0)

    first = issue("iss-a", "MT-A", priority: 1, created_at: ~U[2026-01-01 00:00:00Z])
    second = issue("iss-b", "MT-B", priority: 3, created_at: ~U[2026-01-01 00:00:00Z])
    put_issues([first, second])
    poll(pid)

    assert Enum.map(GenServer.call(pid, :snapshot).waiting, & &1.identifier) == ["MT-A", "MT-B"]

    assert :ok = Orchestrator.reorder_queue(pid, ["MT-B", "MT-A"])
    assert Enum.map(GenServer.call(pid, :snapshot).waiting, & &1.identifier) == ["MT-B", "MT-A"]

    :sys.replace_state(pid, fn state -> %{state | max_concurrent_agents: 1} end)
    poll(pid)

    snapshot = GenServer.call(pid, :snapshot)
    assert Enum.map(snapshot.running, & &1.identifier) == ["MT-B"]
    assert Enum.map(snapshot.waiting, & &1.identifier) == ["MT-A"]
  end

  test "skips the head when the per-state cap is full and dispatches the next card" do
    pid =
      start_queue_orchestrator(:SkipStateHead,
        slots: 2,
        workflow: [max_concurrent_agents_by_state: %{"In Progress" => 1}]
      )

    running_issue =
      issue("iss-run", "MT-RUN", state: "In Progress", priority: 2, created_at: ~U[2026-01-01 00:00:00Z])

    head =
      issue("iss-head", "MT-HEAD",
        state: "In Progress",
        priority: 1,
        created_at: ~U[2026-01-01 00:00:00Z]
      )

    nxt =
      issue("iss-next", "MT-NEXT", state: "Todo", priority: 3, created_at: ~U[2026-01-01 00:00:00Z])

    :sys.replace_state(pid, fn state ->
      running_entry = %{
        pid: self(),
        ref: make_ref(),
        identifier: running_issue.identifier,
        issue: running_issue,
        started_at: DateTime.utc_now(),
        session_id: nil
      }

      %{
        state
        | running: %{running_issue.id => running_entry},
          claimed: MapSet.put(state.claimed, running_issue.id)
      }
    end)

    put_issues([running_issue, head, nxt])
    poll(pid)

    snapshot = GenServer.call(pid, :snapshot)
    running_ids = snapshot.running |> Enum.map(& &1.identifier) |> Enum.sort()
    assert running_ids == ["MT-NEXT", "MT-RUN"]
    assert Enum.map(snapshot.waiting, & &1.identifier) == ["MT-HEAD"]
  end

  test "skips the head when every worker host is full and leaves the card waiting" do
    pid =
      start_queue_orchestrator(:SkipHostHead,
        slots: 2,
        workflow: [worker_ssh_hosts: ["worker-a"], worker_max_concurrent_agents_per_host: 1]
      )

    running_issue =
      issue("iss-host-run", "MT-HOST-RUN",
        state: "In Progress",
        priority: 2,
        created_at: ~U[2026-01-01 00:00:00Z]
      )

    head = issue("iss-host-a", "MT-HOST-A", priority: 1, created_at: ~U[2026-01-01 00:00:00Z])
    nxt = issue("iss-host-b", "MT-HOST-B", priority: 3, created_at: ~U[2026-01-01 00:00:00Z])

    :sys.replace_state(pid, fn state ->
      running_entry = %{
        pid: self(),
        ref: make_ref(),
        identifier: running_issue.identifier,
        issue: running_issue,
        worker_host: "worker-a",
        started_at: DateTime.utc_now(),
        session_id: nil
      }

      %{
        state
        | running: %{running_issue.id => running_entry},
          claimed: MapSet.put(state.claimed, running_issue.id)
      }
    end)

    put_issues([running_issue, head, nxt])
    poll(pid)

    snapshot = GenServer.call(pid, :snapshot)
    assert Enum.map(snapshot.running, & &1.identifier) == ["MT-HOST-RUN"]
    assert Enum.map(snapshot.waiting, & &1.identifier) == ["MT-HOST-A", "MT-HOST-B"]
  end

  test "paused ticks refresh waiting without dispatching" do
    pid = start_queue_orchestrator(:PausedRefresh, slots: 1)
    stale = issue("iss-p1", "MT-P1", priority: 2, created_at: ~U[2026-01-01 00:00:00Z])
    put_issues([stale])
    :ok = Orchestrator.pause(pid)
    :ok = Orchestrator.run_poll_cycle_for_test(pid)

    assert Enum.map(GenServer.call(pid, :snapshot).waiting, & &1.identifier) == ["MT-P1"]
    assert GenServer.call(pid, :snapshot).running == []

    restored = issue("iss-p2", "MT-P2", priority: 1, created_at: ~U[2026-01-02 00:00:00Z])
    put_issues([restored])
    :ok = Orchestrator.run_poll_cycle_for_test(pid)

    snapshot = GenServer.call(pid, :snapshot)
    assert Enum.map(snapshot.waiting, & &1.identifier) == ["MT-P2"]
    assert snapshot.running == []
    assert :sys.get_state(pid).paused
  end

  test "a project persisted as dispatch_paused starts paused and skips its first dispatch" do
    project_name = "queue-paused-#{System.unique_integer([:positive])}"

    with_config_dir(fn _tmp ->
      :ok =
        CymphonyConfig.save(%{
          "projects" => [
            %{"name" => project_name, "linear_project_slug" => "demo", "dispatch_paused" => true}
          ]
        })

      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", poll_interval_ms: 60_000)
      put_issues([issue("iss-boot", "MT-BOOT", priority: 1, created_at: ~U[2026-01-01 00:00:00Z])])

      pid = start_named_orchestrator(:PausedBoot, project_name)

      # init/1 seeded it before the 0ms boot tick could dispatch.
      assert :sys.get_state(pid).paused
      :ok = Orchestrator.run_poll_cycle_for_test(pid)

      snapshot = GenServer.call(pid, :snapshot)
      assert Enum.map(snapshot.waiting, & &1.identifier) == ["MT-BOOT"]
      assert snapshot.running == []
      assert snapshot.polling.paused == true

      # Persisted resume, then a fresh process: it comes back dispatching.
      assert {:ok, _} = CymphonyConfig.update_dispatch_paused(project_name, false)
      GenServer.stop(pid)

      resumed = start_named_orchestrator(:ResumedBoot, project_name)
      refute :sys.get_state(resumed).paused
      :ok = Orchestrator.run_poll_cycle_for_test(resumed)

      assert Enum.map(GenServer.call(resumed, :snapshot).running, & &1.identifier) == ["MT-BOOT"]
      :ok = Orchestrator.pause(resumed)
    end)
  end

  test "fetch and config errors keep the last waiting list" do
    pid = start_queue_orchestrator(:ErrorKeep, slots: 0)
    kept = issue("iss-e1", "MT-E1", priority: 2, created_at: ~U[2026-01-01 00:00:00Z])
    put_issues([kept])
    poll(pid)

    assert Enum.map(GenServer.call(pid, :snapshot).waiting, & &1.identifier) == ["MT-E1"]

    put_issues([])
    Application.put_env(:cymphony_elixir, :memory_tracker_error, :linear_unavailable)
    :ok = Orchestrator.resume(pid)
    :ok = Orchestrator.run_poll_cycle_for_test(pid)
    :ok = Orchestrator.pause(pid)
    Application.delete_env(:cymphony_elixir, :memory_tracker_error)

    assert Enum.map(GenServer.call(pid, :snapshot).waiting, & &1.identifier) == ["MT-E1"]

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "bogus",
      poll_interval_ms: 60_000
    )

    :ok = Orchestrator.resume(pid)
    :ok = Orchestrator.run_poll_cycle_for_test(pid)
    :ok = Orchestrator.pause(pid)

    assert Enum.map(GenServer.call(pid, :snapshot).waiting, & &1.identifier) == ["MT-E1"]
  end

  test "queue pin is used on the next waiting spawn" do
    pid = start_queue_orchestrator(:PinSpawn, slots: 0)

    labeled =
      issue("iss-pin", "MT-PIN",
        priority: 2,
        labels: ["agent:claude", "model:sonnet", "effort:low"]
      )

    put_issues([labeled])
    poll(pid)

    assert :ok =
             Orchestrator.set_queue_run_spec(pid, "MT-PIN", %{
               agent_kind: "codex",
               model: "gpt-5.2-codex",
               effort: "high"
             })

    snapshot = GenServer.call(pid, :snapshot)
    assert [%{agent_kind: "codex", model: "gpt-5.2-codex", effort: "high"}] = snapshot.waiting

    :sys.replace_state(pid, fn state -> %{state | max_concurrent_agents: 1} end)
    poll(pid)

    snapshot = GenServer.call(pid, :snapshot)
    assert [%{agent_kind: "codex", model: "gpt-5.2-codex", effort: "high"}] = snapshot.running
    assert snapshot.waiting == []
  end

  test "empty or keep pin fields are skipped and an empty pin is removed" do
    pid = start_queue_orchestrator(:PinSkip, slots: 0)
    labeled = issue("iss-keep", "MT-KEEP", priority: 2, labels: ["effort:low"])
    put_issues([labeled])
    poll(pid)

    assert :ok =
             Orchestrator.set_queue_run_spec(pid, "MT-KEEP", %{
               agent_kind: "codex",
               model: "gpt-5.2-codex",
               effort: "high"
             })

    assert :ok =
             Orchestrator.set_queue_run_spec(pid, "MT-KEEP", %{
               agent_kind: "keep",
               model: "",
               effort: "keep"
             })

    snapshot = GenServer.call(pid, :snapshot)
    assert [%{agent_kind: "codex", model: "gpt-5.2-codex", effort: "high"}] = snapshot.waiting

    assert :ok = Orchestrator.set_queue_run_spec(pid, "MT-KEEP", %{})
    snapshot = GenServer.call(pid, :snapshot)
    assert [%{agent_kind: nil, model: nil, effort: nil}] = snapshot.waiting
  end

  test "set_queue_run_spec persists the full pins map and set_queue_pin aliases it" do
    project_name = "queue-pins-#{System.unique_integer([:positive])}"

    with_config_dir(fn tmp ->
      :ok =
        CymphonyConfig.save(%{
          "projects" => [
            %{
              "name" => project_name,
              "linear_project_slug" => "demo",
              "queue_pins" => %{"MT-OTHER" => %{"effort" => "low"}}
            }
          ]
        })

      pid = start_queue_orchestrator(:FullPins, slots: 0, project_name: project_name)

      assert :ok =
               Orchestrator.set_queue_run_spec(pid, "MT-KEEP", %{
                 agent_kind: "codex",
                 model: "gpt-5.2-codex"
               })

      assert :ok = GenServer.call(pid, {:set_queue_pin, "MT-KEEP", %{effort: "high"}})

      {:ok, cfg} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      project = Enum.find(cfg["projects"], &(&1["name"] == project_name))
      assert project["queue_pins"]["MT-OTHER"] == %{"effort" => "low"}

      assert project["queue_pins"]["MT-KEEP"] == %{
               "agent_kind" => "codex",
               "model" => "gpt-5.2-codex",
               "effort" => "high"
             }
    end)
  end

  test "set_queue_run_spec preserves pins written after the orchestrator loaded its state" do
    project_name = "concurrent-pins-#{System.unique_integer([:positive])}"

    with_config_dir(fn _tmp ->
      :ok = CymphonyConfig.save(%{"projects" => [%{"name" => project_name, "queue_pins" => %{}}]})
      pid = start_queue_orchestrator(:ConcurrentPins, slots: 0, project_name: project_name)

      assert {:ok, _} =
               CymphonyConfig.update_project_queue_pin(project_name, "EXTERNAL-1", %{"effort" => "low"})

      assert :ok = Orchestrator.set_queue_run_spec(pid, "LOCAL-1", %{model: "new-model"})

      {:ok, config} = CymphonyConfig.load()
      pins = hd(config["projects"])["queue_pins"]
      assert pins["EXTERNAL-1"] == %{"effort" => "low"}
      assert pins["LOCAL-1"] == %{"model" => "new-model"}
    end)
  end

  defp start_queue_orchestrator(suffix, opts \\ []) do
    isolate_config_dir()

    workflow =
      Keyword.merge(
        [tracker_kind: "memory", poll_interval_ms: 60_000],
        Keyword.get(opts, :workflow, [])
      )

    write_workflow_file!(Workflow.workflow_file_path(), workflow)

    name = Module.concat(__MODULE__, suffix)

    start_opts =
      case Keyword.get(opts, :project_name) do
        nil -> [name: name]
        project_name -> [name: name, project_name: project_name]
      end

    {:ok, pid} = Orchestrator.start_link(start_opts)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    slots = Keyword.get(opts, :slots, 0)

    :sys.replace_state(pid, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

      %{
        state
        | paused: true,
          tick_timer_ref: nil,
          tick_token: nil,
          poll_check_in_progress: false,
          max_concurrent_agents: slots
      }
    end)

    pid
  end

  # Unlike start_queue_orchestrator/2 this does not force `paused` afterwards,
  # so `init/1`'s seeded value is what the boot tick observes.
  defp start_named_orchestrator(suffix, project_name) do
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, suffix), project_name: project_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
    pid
  end

  defp poll(pid) do
    :ok = Orchestrator.resume(pid)
    :ok = Orchestrator.run_poll_cycle_for_test(pid)
    :ok = Orchestrator.pause(pid)
  end

  defp put_issues(issues) do
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, issues)
  end

  defp issue(id, identifier, opts) do
    %Issue{
      id: id,
      identifier: identifier,
      title: Keyword.get(opts, :title, identifier),
      description: Keyword.get(opts, :description),
      state: Keyword.get(opts, :state, "Todo"),
      url: "https://example.org/#{identifier}",
      priority: Keyword.get(opts, :priority),
      created_at: Keyword.get(opts, :created_at),
      labels: Keyword.get(opts, :labels, []),
      blocked_by: Keyword.get(opts, :blocked_by, [])
    }
  end

  defp isolate_config_dir do
    if is_binary(Application.get_env(:cymphony_elixir, :config_dir_override)) do
      :ok
    else
      tmp = Path.join(System.tmp_dir!(), "cymphony-q-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      Application.put_env(:cymphony_elixir, :config_dir_override, tmp)
      :ok = CymphonyConfig.save(%{"projects" => []})

      on_exit(fn ->
        Application.delete_env(:cymphony_elixir, :config_dir_override)
        File.rm_rf(tmp)
      end)
    end
  end

  defp with_config_dir(fun) do
    tmp = Path.join(System.tmp_dir!(), "cymphony-q-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    previous = Application.get_env(:cymphony_elixir, :config_dir_override)
    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

    try do
      fun.(tmp)
    after
      if is_binary(previous) do
        Application.put_env(:cymphony_elixir, :config_dir_override, previous)
      else
        Application.delete_env(:cymphony_elixir, :config_dir_override)
      end

      File.rm_rf(tmp)
    end
  end
end
