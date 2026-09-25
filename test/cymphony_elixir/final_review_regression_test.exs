defmodule CymphonyElixir.FinalReviewRegressionTest do
  use CymphonyElixir.TestSupport

  import Phoenix.ConnTest
  @endpoint CymphonyElixirWeb.Endpoint

  alias CymphonyElixir.Cymphony.Config, as: ConfigStore
  alias CymphonyElixir.ProjectSupervisor
  alias CymphonyElixirWeb.{Control, Presenter}

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    old_config_dir = Application.get_env(:cymphony_elixir, :config_dir_override)
    old_home = System.get_env("HOME")
    Application.put_env(:cymphony_elixir, :config_dir_override, root)
    System.put_env("HOME", root)
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [])
    :ok = ConfigStore.save(%{"projects" => []})

    cli = Path.join(root, "fake-cli")
    File.write!(cli, "#!/bin/sh\nprintf '%s\\n' \"$@\" > prompt.args\nexec /bin/sleep 60\n")
    File.chmod!(cli, 0o755)

    on_exit(fn ->
      restore_env("HOME", old_home)

      if old_config_dir,
        do: Application.put_env(:cymphony_elixir, :config_dir_override, old_config_dir),
        else: Application.delete_env(:cymphony_elixir, :config_dir_override)
    end)

    %{root: root, cli: cli}
  end

  test "Control callers preserve concurrent distinct pins and same-issue field patches", ctx do
    {name, _pid, _store, _path} = project(ctx, dispatch_paused: true)

    results =
      1..32
      |> Task.async_stream(
        &Control.set_queue_pin({:project, name}, "PIN-#{&1}", %{"model" => "model-#{&1}"}),
        max_concurrency: 32,
        timeout: 60_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    pins = project_pins(name)
    assert map_size(pins) == 32
    for n <- 1..32, do: assert(pins["PIN-#{n}"] == %{"model" => "model-#{n}"})

    patches = [%{"model" => "model-patched"}, %{"effort" => "high"}, %{"agent_kind" => "codex"}]

    results =
      for n <- 1..16, patch <- patches do
        {"MERGE-#{n}", patch}
      end
      |> Task.async_stream(fn {id, patch} -> Control.set_queue_pin({:project, name}, id, patch) end,
        max_concurrency: 32,
        timeout: 60_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    pins = project_pins(name)
    assert map_size(pins) == 48

    for n <- 1..16 do
      assert pins["MERGE-#{n}"] == %{"model" => "model-patched", "effort" => "high", "agent_kind" => "codex"}
    end
  end

  test "concurrent API field patches preserve each issue's unrelated pin fields", ctx do
    endpoint_config = Application.get_env(:cymphony_elixir, @endpoint, [])
    Application.put_env(:cymphony_elixir, @endpoint, Keyword.merge(endpoint_config, server: false, secret_key_base: String.duplicate("s", 64)))
    on_exit(fn -> Application.put_env(:cymphony_elixir, @endpoint, endpoint_config) end)
    start_supervised!({@endpoint, []})
    {name, _pid, _store, _path} = project(ctx, dispatch_paused: true)

    requests = for n <- 1..16, patch <- [%{"model" => "model-api"}, %{"effort" => "high"}, %{"kind" => "codex"}], do: Map.put(patch, "issue", "API-#{n}")

    results =
      requests
      |> Task.async_stream(
        fn params ->
          conn = post(build_conn(), "/api/v1/queue-pin?project=#{name}", params)
          json_response(conn, 202)
        end,
        max_concurrency: 32,
        timeout: 60_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, _}, &1))
    pins = project_pins(name)
    assert map_size(pins) == 16
    for n <- 1..16, do: assert(pins["API-#{n}"] == %{"model" => "model-api", "effort" => "high", "agent_kind" => "codex"})
  end

  for diagnostic <- [:credential, :short_invalid, :oversized_invalid] do
    test "#{diagnostic} hook errors stay bounded and redacted in retries, API payload and abandonment", ctx do
      issue = issue("hook")
      diagnostic = unquote(diagnostic)
      secret = "fake-secret"
      output = Path.join(ctx.root, "hook-output")

      bytes = hook_diagnostic(diagnostic, secret)

      File.write!(output, bytes)
      Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:cymphony_elixir, :memory_tracker_recipient, self())

      {{pid, retry}, raw_log} =
        with_log(fn ->
          pid = legacy(ctx, hook_before_run: "cat '#{output}'; exit 7", max_retry_attempts: 1)

          retry =
            eventually(fn ->
              case Orchestrator.snapshot(pid, 100) do
                %{retrying: [entry | _]} -> entry
                %{retrying: []} -> nil
                :timeout -> nil
                :unavailable -> flunk("orchestrator became unavailable while waiting for retry")
              end
            end)

          {pid, retry}
        end)

      api = api_state(pid)

      eventually(fn -> map_size(:sys.get_state(pid).work.retiring) == 0 end)
      entry = :sys.get_state(pid).retry_attempts[issue.id]
      send(pid, {:retry_issue, issue.id, entry.retry_token})
      assert_receive {:memory_tracker_comment, id, body}, 5_000
      assert String.valid?(retry.error)
      assert byte_size(retry.error) <= 1_024
      assert_public_diagnostic(retry.error, secret)
      assert_public_diagnostic(api, secret)
      assert api =~ "retrying"
      assert raw_log =~ inspect({:workspace_hook_failed, "before_run", 7, bytes})
      assert id == issue.id
      assert body =~ "abandoned"
      assert String.valid?(body)
      assert byte_size(body) < 1_500
      assert_public_diagnostic(body, secret)
    end
  end

  for task_reason <- [:raw, :exception] do
    test "#{task_reason} structured task exits redact binary leaves before retry, API and abandonment formatting", ctx do
      issue = issue("raw-task-error")
      secret = "fake-secret"
      bytes = "OPENAI_API_KEY=" <> secret <> <<255>>
      raw_reason = {:diagnostic_failed, 7, %{"apiKey" => "opaque-secret", details: [bytes]}}
      reason = if unquote(task_reason) == :raw, do: raw_reason, else: {ErlangError.exception(original: raw_reason), []}
      Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:cymphony_elixir, :memory_tracker_recipient, self())
      pid = legacy(ctx, max_retry_attempts: 1)
      :ok = Orchestrator.run_poll_cycle_for_test(pid)
      worker = :sys.get_state(pid).running[issue.id].pid

      raw_log =
        capture_log(fn ->
          Process.exit(worker, reason)
          eventually(fn -> :sys.get_state(pid).retry_attempts[issue.id] end)
        end)

      retry = hd(Orchestrator.snapshot(pid, 100).retrying)
      api = api_state(pid)
      eventually(fn -> map_size(:sys.get_state(pid).work.retiring) == 0 end)
      entry = :sys.get_state(pid).retry_attempts[issue.id]
      send(pid, {:retry_issue, issue.id, entry.retry_token})
      eventually(fn -> :sys.get_state(pid).running[issue.id] end)
      Process.exit(:sys.get_state(pid).running[issue.id].pid, reason)
      assert_receive {:memory_tracker_comment, id, body}, 5_000
      assert id == issue.id
      assert body =~ "abandoned"

      for public <- [retry.error, api, body] do
        assert_public_diagnostic(public, secret)
        refute public =~ "opaque-secret"
        assert public =~ "diagnostic_failed"
      end

      assert raw_log =~ inspect(reason)
    end
  end

  test "ancillary cleanup failures sanitize structured reasons before public retention" do
    secret = "fake-secret"
    error = {:error, {:port_cleanup_failed, "OPENAI_API_KEY=" <> secret <> <<255>>}}

    for kind <- [:effect, :reap] do
      original_ref = make_ref()
      ref = make_ref()
      timer = Process.send_after(self(), :unused, 60_000)
      original = %{key: {:poll, :config}, timer: timer}
      key = if kind == :reap, do: {:reap, original_ref}, else: {:effect, {:stop, "cleanup"}}
      job = %{key: key, timer: timer, context: %{work: fn -> :ok end}}
      state = %Orchestrator.State{paused: true, poll_check_in_progress: false}
      state = %{state | work: %{state.work | io_jobs: %{ref => job, original_ref => original}}}

      {{:noreply, result}, raw_log} = with_log(fn -> Orchestrator.handle_info({ref, error}, state) end)
      assert_public_diagnostic(result.work.cleanup_error, secret)
      assert raw_log =~ inspect(error)
      Process.cancel_timer(result.work.io_jobs[original_ref].timer)
    end
  end

  test "dispatch-refresh failures sanitize structured reasons before scheduling a retry" do
    issue = issue("refresh-error")
    secret = "fake-secret"
    reason = {:refresh_failed, "OPENAI_API_KEY=" <> secret <> <<255>>}
    ref = make_ref()
    token = make_ref()
    config = Config.settings!()
    timer = Process.send_after(self(), :unused, 60_000)
    context = %{source: :retry, retry_token: token, manual: true, config: config, prompt: "prompt", issue: issue, attempt: 1}
    job = %{key: {:intent, issue.id}, timer: timer, context: context}

    state = %Orchestrator.State{
      config: config,
      prompt_template: "prompt",
      paused: true,
      poll_check_in_progress: false,
      retry_attempts: %{issue.id => %{attempt: 1, retry_token: token}}
    }

    state = %{state | work: %{state.work | io_jobs: %{ref => job}, intent_jobs: %{issue.id => ref}}}

    {:noreply, result} = Orchestrator.handle_info({ref, {:error, reason}}, state)
    retry = result.retry_attempts[issue.id]
    assert retry.error =~ "dispatch refresh failed"
    assert_public_diagnostic(retry.error, secret)
    Process.cancel_timer(retry.timer_ref)
  end

  test "non-hook task exceptions are redacted and scrubbed before retry retention", ctx do
    issue = issue("task-error")
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue])
    pid = legacy(ctx, [])
    :ok = Orchestrator.run_poll_cycle_for_test(pid)
    worker = :sys.get_state(pid).running[issue.id].pid
    message = "OPENAI_API_KEY=task-only-fixture\ninvalid byte: " <> <<255>>

    raw_log =
      capture_log(fn ->
        Process.exit(worker, {RuntimeError.exception(message), []})
        eventually(fn -> :sys.get_state(pid).retry_attempts[issue.id] end)
      end)

    retry = hd(Orchestrator.snapshot(pid, 100).retrying)
    assert String.valid?(retry.error)
    assert byte_size(retry.error) <= 1_024
    assert retry.error =~ "[REDACTED]"
    refute retry.error =~ "task-only-fixture"
    refute Jason.encode!(Presenter.state_payload(pid, 1_000)) =~ "task-only-fixture"
    assert raw_log =~ inspect(message)
  end

  test "project active and terminal states govern fresh and retry dispatch despite an invalid global workflow", ctx do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Ready"]
    )

    ready = %{issue("ready") | state: "Ready"}
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [ready])

    {_name, pid, _store, _path} =
      project(ctx, tracker_active_states: ["Ready"], tracker_terminal_states: ["Archived"])

    :ok = Orchestrator.run_poll_cycle_for_test(pid)
    assert [%{issue_id: "final-ready"}] = Orchestrator.snapshot(pid, 100).running
    assert MapSet.member?(:sys.get_state(pid).claimed, ready.id)
    eventually(fn -> File.exists?(Path.join(ctx.root, "workspaces/FINAL-ready/prompt.args")) end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nunrelated invalid global workflow\n")
    worker = :sys.get_state(pid).running[ready.id].pid
    Process.exit(worker, :kill)
    entry = eventually(fn -> :sys.get_state(pid).retry_attempts[ready.id] end)
    eventually(fn -> map_size(:sys.get_state(pid).work.retiring) == 0 end)
    send(pid, {:retry_issue, ready.id, entry.retry_token})
    eventually(fn -> Map.has_key?(:sys.get_state(pid).running, ready.id) end)
    state = :sys.get_state(pid)
    assert state.running[ready.id].pid != worker
    assert state.running[ready.id].retry_attempt == entry.attempt
    refute Map.has_key?(state.retry_attempts, ready.id)
    assert MapSet.member?(state.claimed, ready.id)
  end

  test "runtime concurrency increases and decreases govern actual dispatch after reload", ctx do
    issues = Enum.map(1..3, &issue("capacity-#{&1}"))
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, issues)
    pid = legacy(ctx, max_concurrent_agents: 1)
    :ok = Orchestrator.run_poll_cycle_for_test(pid)
    assert length(Orchestrator.snapshot(pid, 100).running) == 1
    assert :ok = Orchestrator.set_concurrency(pid, 2)
    :ok = Orchestrator.run_poll_cycle_for_test(pid)
    assert length(Orchestrator.snapshot(pid, 100).running) == 2

    rewrite_legacy(ctx, max_concurrent_agents: 1, prompt: "Reloaded capacity prompt")
    :ok = Orchestrator.run_poll_cycle_for_test(pid)
    assert :sys.get_state(pid).prompt_template == "Reloaded capacity prompt"
    assert Orchestrator.snapshot(pid, 100).polling.max_concurrent_agents == 2
    assert length(Orchestrator.snapshot(pid, 100).running) == 2

    assert :ok = Orchestrator.set_concurrency(pid, 1)
    [first, second] = Orchestrator.snapshot(pid, 100).running
    assert :ok = GenServer.call(pid, {:kill_issue, first.issue_id})
    eventually(fn -> map_size(:sys.get_state(pid).work.retiring) == 0 end)
    rewrite_legacy(ctx, max_concurrent_agents: 3)
    :ok = Orchestrator.run_poll_cycle_for_test(pid)
    assert [%{issue_id: remaining}] = Orchestrator.snapshot(pid, 100).running
    assert remaining == second.issue_id
    assert Orchestrator.snapshot(pid, 100).polling.max_concurrent_agents == 1

    assert :ok = GenServer.call(pid, {:kill_issue, second.issue_id})
    eventually(fn -> map_size(:sys.get_state(pid).work.retiring) == 0 end)
    :ok = Orchestrator.run_poll_cycle_for_test(pid)
    assert length(Orchestrator.snapshot(pid, 100).running) == 1
  end

  test "explicit per-state caps remain authoritative above the runtime concurrency fallback", ctx do
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue("cap-1"), issue("cap-2")])
    pid = legacy(ctx, max_concurrent_agents: 1, max_concurrent_agents_by_state: %{"In Progress" => 1})
    assert :ok = Orchestrator.set_concurrency(pid, 3)
    :ok = Orchestrator.run_poll_cycle_for_test(pid)
    assert length(Orchestrator.snapshot(pid, 100).running) == 1
    assert length(Orchestrator.snapshot(pid, 100).waiting) == 1
  end

  test "initial blank legacy workflow sends the default prompt to the CLI", ctx do
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue("blank")])
    pid = legacy(ctx, prompt: "")
    :ok = Orchestrator.run_poll_cycle_for_test(pid)
    prompt_file = Path.join(ctx.root, "workspaces/FINAL-blank/prompt.args")
    eventually(fn -> File.exists?(prompt_file) end)
    assert File.read!(prompt_file) =~ "You are working on a Linear issue."
    assert File.read!(prompt_file) =~ "Identifier: FINAL-blank"
    assert :sys.get_state(pid).prompt_template == Config.workflow_prompt()
  end

  test "nonblank project prompt reloads to the independent default when its body becomes blank", ctx do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "OTHER PROJECT PROMPT")
    {_name, pid, store, path} = project(ctx, prompt: "Original {{ issue.identifier }}", dispatch_paused: true)

    assert PromptBuilder.build_prompt(issue("prompt"), prompt_template: :sys.get_state(pid).prompt_template) ==
             "Original FINAL-prompt"

    write_workflow_file!(path, defaults(ctx, prompt: " \n\t"))
    assert :ok = WorkflowStore.force_reload(store)
    :ok = Orchestrator.run_poll_cycle_for_test(pid)
    prompt = PromptBuilder.build_prompt(issue("prompt"), prompt_template: :sys.get_state(pid).prompt_template)
    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: FINAL-prompt"
    refute prompt =~ "OTHER PROJECT PROMPT"
  end

  test "an explicitly blank PromptBuilder template never borrows another project's prompt" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "OTHER PROJECT PROMPT")
    prompt = PromptBuilder.build_prompt(issue("direct-blank"), prompt_template: " \n\t")
    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: FINAL-direct-blank"
    refute prompt =~ "OTHER PROJECT PROMPT"
  end

  # Detect the original lossless decimal-binary encoding, not just a literal leak.
  defp assert_public_diagnostic(public, secret) do
    assert String.valid?(public)
    refute public =~ secret

    for [_, vector] <- Regex.scan(Regex.compile!("<<([0-9, ]+)>>"), public) do
      decoded = vector |> String.split(",") |> Enum.map(&(String.trim(&1) |> String.to_integer())) |> :binary.list_to_bin()
      refute decoded =~ secret
    end

    assert public =~ "[REDACTED]" or public =~ "[event text omitted]"
  end

  defp api_state(pid) do
    endpoint_config = Application.get_env(:cymphony_elixir, @endpoint, [])
    Application.put_env(:cymphony_elixir, @endpoint, Keyword.merge(endpoint_config, server: false, orchestrator: pid, secret_key_base: String.duplicate("s", 64)))
    on_exit(fn -> Application.put_env(:cymphony_elixir, @endpoint, endpoint_config) end)
    start_supervised!({@endpoint, []})
    conn = get(build_conn(), "/api/v1/state")
    assert conn.status == 200
    conn.resp_body
  end

  defp hook_diagnostic(:short_invalid, secret), do: "OPENAI_API_KEY=#{secret}" <> <<255>>
  defp hook_diagnostic(:credential, secret), do: "OPENAI_API_KEY=#{secret}\n"
  defp hook_diagnostic(:oversized_invalid, secret), do: "OPENAI_API_KEY=#{secret}\n" <> String.duplicate("large diagnostic ", 10_000) <> <<255>>

  defp project(ctx, opts) do
    name = "final-#{System.unique_integer([:positive])}"
    :ok = ConfigStore.save(%{"projects" => [%{"name" => name, "dispatch_paused" => Keyword.get(opts, :dispatch_paused, false)}]})
    path = Path.join(ctx.root, "#{name}.md")
    write_workflow_file!(path, defaults(ctx, opts))
    supervisor = start_supervised!({ProjectSupervisor, project_name: name, workflow_path: path})
    on_exit(fn -> if Process.alive?(supervisor), do: Supervisor.stop(supervisor) end)
    {name, ProjectSupervisor.lookup(name, :orchestrator), ProjectSupervisor.lookup(name, :workflow_store), path}
  end

  defp project_pins(name) do
    {:ok, config} = ConfigStore.load()
    {:ok, project} = ConfigStore.find_project(config, name)
    project["queue_pins"]
  end

  defp legacy(ctx, opts) do
    rewrite_legacy(ctx, opts)
    pid = start_supervised!({Orchestrator, name: nil})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp rewrite_legacy(ctx, opts), do: write_workflow_file!(Workflow.workflow_file_path(), defaults(ctx, opts))

  defp defaults(ctx, opts) do
    Keyword.merge(
      [tracker_kind: "memory", workspace_root: Path.join(ctx.root, "workspaces"), claude_command: ctx.cli, poll_interval_ms: 60_000],
      opts
    )
  end

  defp issue(suffix) do
    %Issue{id: "final-#{suffix}", identifier: "FINAL-#{suffix}", title: "Final review regression", state: "In Progress", labels: [], blocked_by: []}
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
