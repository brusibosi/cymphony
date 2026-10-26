defmodule CymphonyElixir.CompletionCountPresenterTest do
  use CymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias CymphonyElixirWeb.Presenter

  @endpoint CymphonyElixirWeb.Endpoint

  defmodule SnapshotServer do
    use GenServer

    def start_link({project, snapshot}), do: GenServer.start_link(__MODULE__, {project, snapshot})

    @impl true
    def init({project, snapshot}) do
      if project do
        {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {project, :orchestrator}, nil)
      end

      {:ok, snapshot}
    end

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  setup do
    config_dir = Path.join(System.tmp_dir!(), "cymphony-count-#{System.unique_integer([:positive])}")
    File.mkdir_p!(config_dir)
    File.write!(Path.join(config_dir, "config.json"), ~s({"projects":[]}))

    previous_dir = Application.fetch_env(:cymphony_elixir, :config_dir_override)
    endpoint_config = Application.get_env(:cymphony_elixir, @endpoint, [])
    previous_key = System.get_env("LINEAR_API_KEY")
    System.delete_env("LINEAR_API_KEY")
    Application.put_env(:cymphony_elixir, :config_dir_override, config_dir)

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_key)
      Application.put_env(:cymphony_elixir, @endpoint, endpoint_config)

      case previous_dir do
        {:ok, dir} -> Application.put_env(:cymphony_elixir, :config_dir_override, dir)
        :error -> Application.delete_env(:cymphony_elixir, :config_dir_override)
      end

      File.rm_rf!(config_dir)
    end)

    :ok
  end

  for count <- [151, 1001] do
    test "legacy API and dashboard show #{count} completed tickets with only 100 recent agent runs" do
      server = start_snapshot(nil, snapshot("Alpha", unquote(count)))
      start_endpoint(server)

      response = json_response(get(build_conn(), "/api/v1/state"), 200)
      assert response["counts"]["completed"] == unquote(count)
      assert hd(response["projects"])["completed_count"] == unquote(count)
      assert length(response["recent_completed"]) == 100

      {:ok, view, _html} = live(build_conn(), "/")
      assert has_element?(view, "#completed-ticket-count .metric-pill-value", Integer.to_string(unquote(count)))
      assert has_element?(view, "#project-Alpha [data-completed-count]", Integer.to_string(unquote(count)))
      assert has_element?(view, "#completions-section .section-title", "Recent agent runs")
      assert has_element?(view, "#completions-section .session-row--completed")
      refute render(view) =~ "recently finished tasks"

      {:ok, refreshed, _html} = live(build_conn(), "/")
      assert has_element?(refreshed, "#completed-ticket-count .metric-pill-value", Integer.to_string(unquote(count)))
      assert Presenter.state_payload(server, 100).counts.completed == unquote(count)
    end
  end

  test "aggregate count sums independent project runs beyond the merged history limit" do
    start_snapshot("Alpha", snapshot("Alpha", 151))
    start_snapshot("Beta", snapshot("Beta", 1001))
    start_endpoint(__MODULE__.MissingOrchestrator)

    response = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert response["counts"]["completed"] == 1152
    assert Enum.find(response["projects"], &(&1["name"] == "Alpha"))["completed_count"] == 151
    assert Enum.find(response["projects"], &(&1["name"] == "Beta"))["completed_count"] == 1001
    assert length(response["recent_completed"]) == 100

    {:ok, view, _html} = live(build_conn(), "/")
    assert has_element?(view, "#completed-ticket-count .metric-pill-value", "1152")
    assert has_element?(view, "#project-Alpha [data-completed-count]", "151")
    assert has_element?(view, "#project-Beta [data-completed-count]", "1001")
    assert has_element?(view, ~s(a.rail-link[href="#project-Alpha"]))
    assert has_element?(view, ~s(a.rail-link[href="#project-Beta"]))
  end

  test "missing current-run count defaults to zero even with retained agent history" do
    server = start_snapshot(nil, Map.delete(snapshot("Alpha", 151), :completed_count))
    start_endpoint(server)

    payload = Presenter.state_payload(server, 100)
    assert payload.counts.completed == 0
    assert hd(payload.projects).completed_count == 0
    assert length(payload.recent_completed) == 100

    {:ok, view, _html} = live(build_conn(), "/")
    assert has_element?(view, "#completed-ticket-count .metric-pill-value", "0")
    assert has_element?(view, "#project-Alpha [data-completed-count]", "0")
  end

  test "an empty fleet reports zero completed tickets" do
    payload = Presenter.state_payload(__MODULE__.MissingOrchestrator, 100)
    assert payload.counts.completed == 0
    assert payload.projects == []
    assert payload.recent_completed == []
  end

  defp start_snapshot(project, snapshot) do
    start_supervised!({SnapshotServer, {project, snapshot}}, id: project || "legacy")
  end

  defp start_endpoint(orchestrator) do
    config = Application.get_env(:cymphony_elixir, @endpoint, [])

    Application.put_env(
      :cymphony_elixir,
      @endpoint,
      Keyword.merge(config, server: false, secret_key_base: String.duplicate("s", 64), orchestrator: orchestrator, snapshot_timeout_ms: 100)
    )

    start_supervised!({@endpoint, []})
  end

  defp snapshot(project, count) do
    %{
      project_name: project,
      running: [],
      retrying: [],
      waiting: [],
      completed_count: count,
      recent_completed:
        for index <- 1..100 do
          %{issue_id: "issue-#{index}", identifier: "COUNT-#{index}", ended_at: ~U[2026-10-26 10:00:00Z]}
        end,
      token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil,
      polling: %{next_poll_in_ms: nil, poll_interval_ms: 30_000, paused: true}
    }
  end
end
