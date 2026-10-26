defmodule CymphonyElixir.PresenterMetricsTest do
  use CymphonyElixir.TestSupport

  alias CymphonyElixirWeb.Presenter

  defmodule StaticOrchestrator do
    use GenServer

    def child_spec(opts) do
      name = Keyword.fetch!(opts, :name)

      %{
        id: name,
        start: {__MODULE__, :start_link, [opts]}
      }
    end

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts) do
      if project_name = Keyword.get(opts, :project_name) do
        {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {project_name, :orchestrator}, nil)
      end

      {:ok, opts}
    end

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end
  end

  describe "count_breakdowns/1" do
    test "returns empty maps when nothing is running" do
      assert Presenter.count_breakdowns([]) == %{by_state: %{}, by_kind: %{}}
    end

    test "counts raw state strings and agent_kind with unknown fallback" do
      running = [
        %{state: "In Progress", agent_kind: "claude"},
        %{state: "In Progress", agent_kind: "codex"},
        %{state: "Todo", agent_kind: nil},
        %{"state" => "Todo", "agent_kind" => "antigravity"},
        %{state: :Blocked, agent_kind: :claude},
        %{state: "In Progress", agent_kind: ""},
        :not_a_map
      ]

      assert Presenter.count_breakdowns(running) == %{
               by_state: %{"In Progress" => 3, "Todo" => 2, "Blocked" => 1},
               by_kind: %{"claude" => 2, "codex" => 1, "antigravity" => 1, "unknown" => 2}
             }
    end
  end

  describe "session_tokens_per_second/2" do
    test "is 0.0 when totals are zero, including both-zero" do
      assert Presenter.session_tokens_per_second(0, 0) == 0.0
      assert Presenter.session_tokens_per_second(0, 12) == 0.0
      assert Presenter.session_tokens_per_second(0.0, 3.5) == 0.0
      assert Presenter.session_tokens_per_second(nil, 8) == 0.0
    end

    test "divides total by max(seconds, 1) as a float" do
      assert Presenter.session_tokens_per_second(100, 4) == 25.0
      assert Presenter.session_tokens_per_second(100, 0) == 100.0
      assert Presenter.session_tokens_per_second(10, nil) == 10.0
      assert Presenter.session_tokens_per_second(10, 0.5) == 10.0
      assert Presenter.session_tokens_per_second(12, 42.5) == 12 / 42.5
    end
  end

  describe "state_payload/2" do
    setup do
      stop_registered_orchestrators()
      :ok
    end

    test "legacy single-orchestrator path adds by_state, by_kind, and tokens_per_second" do
      started_at = DateTime.add(DateTime.utc_now(), -8, :second)
      log_events = Enum.map(1..25, fn i -> %{at: started_at, event: :tick, message: "e#{i}"} end)
      orchestrator = unique_name("Legacy")

      snapshot =
        snapshot_fixture(
          running: [
            running_entry(%{
              identifier: "MT-1",
              state: "In Progress",
              agent_kind: "claude",
              total_tokens: 24,
              started_at: started_at,
              log_events: log_events
            }),
            running_entry(%{
              identifier: "MT-2",
              state: "Todo",
              agent_kind: nil,
              total_tokens: 0,
              started_at: nil
            })
          ],
          retrying: [retry_entry()],
          token_totals: %{input_tokens: 10, output_tokens: 14, total_tokens: 24, seconds_running: 8}
        )

      start_supervised!({StaticOrchestrator, name: orchestrator, snapshot: snapshot})

      payload = Presenter.state_payload(orchestrator, 50)

      assert payload.counts == %{
               running: 2,
               retrying: 1,
               waiting: 0,
               completed: 0,
               by_state: %{"In Progress" => 1, "Todo" => 1},
               by_kind: %{"claude" => 1, "unknown" => 1}
             }

      assert hd(payload.projects).waiting == []
      assert hd(payload.projects).waiting_count == 0

      assert payload.token_totals == %{
               input_tokens: 10,
               output_tokens: 14,
               total_tokens: 24,
               seconds_running: 8,
               tokens_per_second: 3.0
             }

      [first, second] = payload.running
      assert_session_tps(first.tokens_per_second, 24, started_at)
      assert first.tokens.total_tokens == 24
      assert length(first.log_events) == 20
      assert second.tokens_per_second == 0.0

      assert Map.has_key?(payload, :generated_at)
      assert Map.has_key?(payload, :running)
      assert Map.has_key?(payload, :retrying)
      assert Map.has_key?(payload, :recent_completed)
      assert Map.has_key?(payload, :rate_limits)
      assert Map.has_key?(payload, :polling)
      assert Map.has_key?(payload, :projects)
      assert length(payload.projects) == 1
    end

    test "multi-project path flattens running entries for breakdowns and totals tps" do
      started_at = DateTime.add(DateTime.utc_now(), -5, :second)
      first_name = unique_name("MultiA")
      second_name = unique_name("MultiB")

      start_supervised!(
        {StaticOrchestrator,
         name: first_name,
         project_name: "Alpha",
         snapshot:
           snapshot_fixture(
             running: [
               running_entry(%{
                 identifier: "A-1",
                 state: "In Progress",
                 agent_kind: "codex",
                 total_tokens: 30,
                 started_at: started_at
               })
             ],
             retrying: [],
             token_totals: %{input_tokens: 10, output_tokens: 20, total_tokens: 30, seconds_running: 5}
           )}
      )

      start_supervised!(
        {StaticOrchestrator,
         name: second_name,
         project_name: "Beta",
         snapshot:
           snapshot_fixture(
             running: [
               running_entry(%{
                 identifier: "B-1",
                 state: "In Progress",
                 agent_kind: "antigravity",
                 total_tokens: 10,
                 started_at: started_at
               }),
               running_entry(%{
                 identifier: "B-2",
                 state: "Blocked",
                 agent_kind: "claude",
                 total_tokens: 0,
                 started_at: "not-a-date"
               })
             ],
             retrying: [retry_entry(%{identifier: "B-R"})],
             token_totals: %{input_tokens: 4, output_tokens: 6, total_tokens: 10, seconds_running: 5}
           )}
      )

      payload = Presenter.state_payload(first_name, 50)

      assert payload.counts.running == 3
      assert payload.counts.retrying == 1
      assert payload.counts.waiting == 0
      assert payload.counts.by_state == %{"In Progress" => 2, "Blocked" => 1}
      assert payload.counts.by_kind == %{"codex" => 1, "antigravity" => 1, "claude" => 1}

      assert payload.token_totals.input_tokens == 14
      assert payload.token_totals.output_tokens == 26
      assert payload.token_totals.total_tokens == 40
      assert payload.token_totals.seconds_running == 10
      assert payload.token_totals.tokens_per_second == 4.0

      assert Enum.sort(Enum.map(payload.projects, & &1.name)) == ["Alpha", "Beta"]
      assert length(payload.running) == 3

      blocked = Enum.find(payload.running, &(&1.issue_identifier == "B-2"))
      assert blocked.tokens_per_second == 0.0
    end

    test "empty running list and nil token totals produce empty breakdowns and 0.0 tps" do
      orchestrator = unique_name("Empty")

      snapshot =
        snapshot_fixture()
        |> Map.put(:running, [])
        |> Map.put(:retrying, [])
        |> Map.put(:token_totals, nil)

      start_supervised!({StaticOrchestrator, name: orchestrator, snapshot: snapshot})

      payload = Presenter.state_payload(orchestrator, 50)

      assert payload.counts == %{running: 0, retrying: 0, waiting: 0, completed: 0, by_state: %{}, by_kind: %{}}

      assert payload.token_totals == %{
               input_tokens: 0,
               output_tokens: 0,
               total_tokens: 0,
               seconds_running: 0,
               tokens_per_second: 0.0
             }
    end

    test "iso8601 started_at strings feed session tokens_per_second" do
      started_at = DateTime.add(DateTime.utc_now(), -20, :second) |> DateTime.truncate(:second)
      orchestrator = unique_name("Iso")

      snapshot =
        snapshot_fixture(
          running: [
            running_entry(%{
              identifier: "MT-ISO",
              total_tokens: 40,
              started_at: DateTime.to_iso8601(started_at)
            })
          ],
          token_totals: %{input_tokens: 10, output_tokens: 30, total_tokens: 40, seconds_running: 0}
        )

      start_supervised!({StaticOrchestrator, name: orchestrator, snapshot: snapshot})

      payload = Presenter.state_payload(orchestrator, 50)
      [entry] = payload.running

      assert_session_tps(entry.tokens_per_second, 40, started_at)
      assert payload.token_totals.tokens_per_second == 40.0
    end

    test "projects include waiting rows and waiting_count; counts.waiting sums them" do
      first_name = unique_name("WaitA")
      second_name = unique_name("WaitB")
      created_at = ~U[2026-01-02 03:04:05Z]

      start_supervised!(
        {StaticOrchestrator,
         name: first_name,
         project_name: "WaitAlpha",
         snapshot:
           snapshot_fixture(
             waiting: [
               %{
                 issue_id: "issue-a-w",
                 identifier: "A-W",
                 issue: %{
                   title: "Wait A",
                   url: "https://linear.app/test/issue/A-W",
                   priority: 1,
                   created_at: created_at
                 },
                 priority: 1,
                 state: "Todo",
                 created_at: created_at,
                 agent_kind: "codex",
                 model: "gpt-5.2-codex",
                 effort: "high"
               }
             ]
           )}
      )

      start_supervised!(
        {StaticOrchestrator,
         name: second_name,
         project_name: "WaitBeta",
         snapshot:
           snapshot_fixture(
             waiting: [
               %{
                 issue_id: "issue-b-w",
                 identifier: "B-W",
                 issue: %{title: "Wait B", url: nil, priority: 3, created_at: created_at},
                 priority: 3,
                 state: "In Progress",
                 created_at: created_at
               }
             ]
           )}
      )

      payload = Presenter.state_payload(first_name, 50)

      assert payload.counts.waiting == 2

      alpha = Enum.find(payload.projects, &(&1.name == "WaitAlpha"))
      beta = Enum.find(payload.projects, &(&1.name == "WaitBeta"))

      assert alpha.waiting_count == 1
      assert beta.waiting_count == 1

      [alpha_row] = alpha.waiting
      assert alpha_row.issue_identifier == "A-W"
      assert alpha_row.issue_title == "Wait A"
      assert alpha_row.issue_url == "https://linear.app/test/issue/A-W"
      assert alpha_row.issue_id == "issue-a-w"
      assert alpha_row.priority == 1
      assert alpha_row.state == "Todo"
      assert alpha_row.created_at == "2026-01-02T03:04:05Z"
      assert alpha_row.agent_kind == "codex"
      assert alpha_row.model == "gpt-5.2-codex"
      assert alpha_row.effort == "high"

      [beta_row] = beta.waiting
      assert beta_row.issue_identifier == "B-W"
      assert beta_row.issue_title == "Wait B"
      assert beta_row.agent_kind == nil
      assert beta_row.model == nil
      assert beta_row.effort == nil
    end

    test "missing snapshot waiting defaults to an empty list and counts.waiting 0" do
      orchestrator = unique_name("NoWait")

      snapshot = snapshot_fixture() |> Map.delete(:waiting)
      start_supervised!({StaticOrchestrator, name: orchestrator, snapshot: snapshot})

      payload = Presenter.state_payload(orchestrator, 50)

      assert payload.counts.waiting == 0
      assert hd(payload.projects).waiting == []
      assert hd(payload.projects).waiting_count == 0
    end
  end

  test "format_rate_limits_for_web is unchanged" do
    assert Presenter.format_rate_limits_for_web(nil) == nil
    assert Presenter.format_rate_limits_for_web(:invalid) == nil

    assert Presenter.format_rate_limits_for_web(%{
             "limit_id" => "primary-bucket",
             "primary" => %{"remaining" => 11, "limit" => 20},
             "secondary" => %{"remaining" => 3},
             "credits" => %{"unlimited" => true}
           }) == %{
             limit_id: "primary-bucket",
             primary: %{remaining: 11, limit: 20, reset_in_seconds: nil, summary: "11/20"},
             secondary: %{remaining: 3, limit: nil, reset_in_seconds: nil, summary: "remaining 3"},
             credits: %{status: "unlimited", summary: "unlimited"}
           }
  end

  defp unique_name(label) do
    Module.concat(__MODULE__, :"#{label}#{System.unique_integer([:positive])}")
  end

  defp stop_registered_orchestrators do
    Enum.each(CymphonyElixir.ProjectSupervisor.list_orchestrators(), fn {_name, pid} ->
      if is_pid(pid) and Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 200)
        catch
          :exit, _ -> :ok
        end
      end
    end)
  end

  defp assert_session_tps(actual, total_tokens, %DateTime{} = started_at) do
    seconds = max(0, DateTime.diff(DateTime.utc_now(), started_at, :second))

    allowed =
      Enum.map([seconds, max(seconds - 1, 0), seconds + 1], fn elapsed ->
        Presenter.session_tokens_per_second(total_tokens, elapsed)
      end)

    assert actual in allowed
  end

  defp snapshot_fixture(overrides \\ []) do
    Map.merge(
      %{
        running: [],
        retrying: [],
        waiting: [],
        token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        rate_limits: %{"primary" => %{"remaining" => 11}},
        polling: %{
          next_poll_in_ms: 5_000,
          poll_interval_ms: 30_000,
          paused: false,
          checking?: false
        }
      },
      Map.new(overrides)
    )
  end

  defp running_entry(overrides) do
    Map.merge(
      %{
        issue_id: "issue-#{Map.get(overrides, :identifier, "MT-1")}",
        identifier: "MT-1",
        state: "In Progress",
        session_id: "thread-1",
        turn_count: 1,
        agent_os_pid: nil,
        last_agent_message: nil,
        last_agent_timestamp: nil,
        last_agent_event: nil,
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        started_at: DateTime.utc_now(),
        agent_kind: "claude",
        log_events: []
      },
      overrides
    )
  end

  defp retry_entry(overrides \\ %{}) do
    Map.merge(
      %{
        issue_id: "issue-retry",
        identifier: "MT-RETRY",
        attempt: 2,
        due_in_ms: 2_000,
        error: "boom"
      },
      overrides
    )
  end
end
