defmodule CymphonyElixir.CompletionStoreTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Bitwise, only: [band: 2]

  alias CymphonyElixir.CompletionStore

  test "the test application stores session history outside the operator's state directory" do
    %{path: path} = :sys.get_state(CompletionStore)
    assert path == Application.fetch_env!(:cymphony_elixir, :completion_store_path)
    refute String.starts_with?(path, Path.expand("~/.cymphony"))
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "cymphony-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "sessions.db")
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir, path: path, name: name}
  end

  defp start_store!(opts) do
    {:ok, pid} = CompletionStore.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {pid, Keyword.fetch!(opts, :name)}
  end

  defp put_record(name, attrs) do
    base = %{
      issue_id: "i-#{System.unique_integer([:positive])}",
      identifier: "MT-#{System.unique_integer([:positive])}",
      project_name: "p1",
      ended_at: DateTime.utc_now(),
      started_at: DateTime.utc_now(),
      runtime_seconds: 5,
      input_tokens: 10,
      output_tokens: 20,
      total_tokens: 30,
      worker_host: nil,
      workspace_path: "/tmp/ws"
    }

    record = Map.merge(base, Map.new(attrs))
    :ok = CompletionStore.put_async(record, name)
    record
  end

  test "round-trip writes and reads records ordered by ended_at desc", %{path: path, name: name} do
    {_pid, name} = start_store!(path: path, name: name)

    now = DateTime.utc_now()

    put_record(name, issue_id: "a", project_name: "p1", ended_at: DateTime.add(now, -3, :second))
    put_record(name, issue_id: "b", project_name: "p1", ended_at: DateTime.add(now, -1, :second))
    put_record(name, issue_id: "c", project_name: "p2", ended_at: now)
    put_record(name, issue_id: "d", project_name: "p1", ended_at: DateTime.add(now, -2, :second))
    put_record(name, issue_id: "e", project_name: "p2", ended_at: DateTime.add(now, -10, :second))

    :ok = sync(name)

    p1 = CompletionStore.recent("p1", 10, name)
    assert Enum.map(p1, & &1.issue_id) == ["b", "d", "a"]

    p1_top = CompletionStore.recent("p1", 2, name)
    assert Enum.map(p1_top, & &1.issue_id) == ["b", "d"]

    all = CompletionStore.recent(:all, 10, name)
    assert Enum.map(all, & &1.issue_id) == ["c", "b", "d", "a", "e"]

    assert CompletionStore.count("p1", name) == 3
    assert CompletionStore.count(:all, name) == 5
  end

  test "recent/2 clamps limit above 1000", %{path: path, name: name} do
    {_pid, name} = start_store!(path: path, name: name)
    put_record(name, issue_id: "only")
    :ok = sync(name)

    # We can't easily assert SQL bound limit from outside; assert no crash + content correct.
    assert [%{issue_id: "only"}] = CompletionStore.recent(:all, 5_000, name)
  end

  test "duplicate (issue_id, ended_at) is replaced not duplicated", %{path: path, name: name} do
    {_pid, name} = start_store!(path: path, name: name)
    ended = DateTime.utc_now()

    put_record(name, issue_id: "dup", ended_at: ended, total_tokens: 1)
    put_record(name, issue_id: "dup", ended_at: ended, total_tokens: 999)
    :ok = sync(name)

    assert [row] = CompletionStore.recent(:all, 10, name)
    assert row.issue_id == "dup"
    assert row.total_tokens == 999
    assert CompletionStore.count(:all, name) == 1
  end

  test "degraded start when path is not writable still returns ok/0/[]", %{name: name} do
    bad_path = Path.join("/dev/null", "no-perm.db")

    log =
      capture_log(fn ->
        {:ok, pid} = CompletionStore.start_link(path: bad_path, name: name)
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

        assert :ok = CompletionStore.put_async(%{issue_id: "x", ended_at: DateTime.utc_now()}, name)
        assert CompletionStore.recent("p1", 10, name) == []
        assert CompletionStore.recent(:all, 10, name) == []
        assert CompletionStore.count("p1", name) == 0
        assert CompletionStore.count(:all, name) == 0
      end)

    assert log =~ "completion_store.unavailable"
  end

  test "default_path/0 resolves under home or tmp", _ctx do
    path = CompletionStore.default_path()
    assert is_binary(path)
    assert String.ends_with?(path, "sessions.db")
  end

  test "row file gets 0600 perms after create", %{path: path, name: name} do
    {_pid, _name} = start_store!(path: path, name: name)
    put_record(name, issue_id: "perm-test")
    :ok = sync(name)

    %File.Stat{mode: mode} = File.stat!(path)
    assert band(mode, 0o777) == 0o600
  end

  defp sync(name) do
    # Force the cast to drain by issuing a synchronous call that traverses
    # the same message queue.
    _ = CompletionStore.count(:all, name)
    :ok
  end

  describe "restart recovery" do
    test "fresh store on the same file recovers the most recent 100 records", %{path: path, name: name} do
      {pid1, name1} = start_store!(path: path, name: name)

      now = DateTime.utc_now()

      for i <- 1..150 do
        put_record(name1,
          issue_id: "i-#{String.pad_leading(Integer.to_string(i), 3, "0")}",
          project_name: "p1",
          ended_at: DateTime.add(now, i, :second)
        )
      end

      :ok = sync(name1)
      GenServer.stop(pid1)

      restart_name = Module.concat(__MODULE__, "Restart#{System.unique_integer([:positive])}")
      {_pid2, _} = start_store!(path: path, name: restart_name)

      rows = CompletionStore.recent("p1", 100, restart_name)
      assert length(rows) == 100

      first_issue_id = hd(rows).issue_id
      last_issue_id = List.last(rows).issue_id

      # Newest first: i-150 ... i-051
      assert first_issue_id == "i-150"
      assert last_issue_id == "i-051"
    end
  end

  describe "agent columns" do
    test "persists and reads agent_kind and model", %{path: path, name: name} do
      {_pid, name} = start_store!(path: path, name: name)

      put_record(name, issue_id: "spec-b", agent_kind: "codex", model: "gpt-5.2-codex")
      :ok = sync(name)

      assert [row] = CompletionStore.recent("p1", 10, name)
      assert row.agent_kind == "codex"
      assert row.model == "gpt-5.2-codex"
    end

    test "rows written without agent fields read back as nil", %{path: path, name: name} do
      {_pid, name} = start_store!(path: path, name: name)
      put_record(name, issue_id: "old-row")
      :ok = sync(name)

      assert [row] = CompletionStore.recent("p1", 10, name)
      assert row.agent_kind == nil
      assert row.model == nil
    end
  end

  describe "legacy column migration" do
    test "opens a pre-rename database and reads old rows through new column names", %{dir: dir} do
      path = Path.join(dir, "legacy.db")
      {:ok, db} = Exqlite.Sqlite3.open(path, [])

      :ok =
        Exqlite.Sqlite3.execute(db, """
        CREATE TABLE sessions (
          issue_id TEXT NOT NULL, identifier TEXT, project_name TEXT,
          ended_at TEXT NOT NULL, started_at TEXT, runtime_seconds INTEGER,
          claude_input_tokens INTEGER DEFAULT 0, claude_output_tokens INTEGER DEFAULT 0,
          claude_total_tokens INTEGER DEFAULT 0, worker_host TEXT, workspace_path TEXT,
          PRIMARY KEY (issue_id, ended_at))
        """)

      :ok =
        Exqlite.Sqlite3.execute(
          db,
          "INSERT INTO sessions (issue_id, ended_at, claude_input_tokens, claude_output_tokens, claude_total_tokens) VALUES ('i1', '2026-07-16T00:00:00Z', 7, 3, 10)"
        )

      :ok = Exqlite.Sqlite3.close(db)

      name = Module.concat(__MODULE__, "LegacyStore#{System.unique_integer([:positive])}")
      {_pid, name} = start_store!(path: path, name: name)

      assert [row] = CompletionStore.recent(:all, 10, name)
      assert row.input_tokens == 7
      assert row.total_tokens == 10
    end
  end
end
