defmodule CymphonyElixir.CompletionStore do
  @moduledoc """
  Durable storage for completed agent sessions.

  Backed by an embedded SQLite database (default `~/.cymphony/sessions.db`).
  Writes are asynchronous (`put_async/1`); reads are synchronous (`recent/2`,
  `count/1`). When the database cannot be opened, the GenServer enters a
  `:degraded` state — `put_async/1` still returns `:ok` and `recent/2` returns
  `[]` — so the daemon stays up even on a read-only or full disk.
  """

  use GenServer
  require Logger

  alias Exqlite.Sqlite3

  @schema [
    """
    CREATE TABLE IF NOT EXISTS sessions (
      issue_id           TEXT NOT NULL,
      identifier         TEXT,
      project_name       TEXT,
      ended_at           TEXT NOT NULL,
      started_at         TEXT,
      runtime_seconds    INTEGER,
      input_tokens  INTEGER DEFAULT 0,
      output_tokens INTEGER DEFAULT 0,
      total_tokens  INTEGER DEFAULT 0,
      worker_host        TEXT,
      workspace_path     TEXT,
      agent_kind         TEXT,
      model              TEXT,
      PRIMARY KEY (issue_id, ended_at)
    )
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_sessions_project_ended
      ON sessions(project_name, ended_at DESC)
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_sessions_ended
      ON sessions(ended_at DESC)
    """
  ]

  # Pre-rename databases (< v1.7) have claude_*-prefixed token columns; the
  # open path renames them in place so history survives the neutral renaming.
  @column_renames [
    {"claude_input_tokens", "input_tokens"},
    {"claude_output_tokens", "output_tokens"},
    {"claude_total_tokens", "total_tokens"}
  ]

  # Additive columns for databases created before they existed; "duplicate
  # column" errors on fresh DBs are ignored.
  @column_adds [
    "ALTER TABLE sessions ADD COLUMN agent_kind TEXT",
    "ALTER TABLE sessions ADD COLUMN model TEXT"
  ]

  @max_limit 1000

  @type record :: %{
          required(:issue_id) => String.t() | nil,
          required(:ended_at) => DateTime.t(),
          optional(atom()) => term()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Enqueue a completion record for durable storage.

  Returns `:ok` unconditionally — failures degrade silently with a logged
  warning so a broken store never crashes the orchestrator.
  """
  @spec put_async(record(), GenServer.server()) :: :ok
  def put_async(record, server \\ __MODULE__) when is_map(record) do
    GenServer.cast(server, {:put, record})
  end

  @doc """
  Return up to `limit` most-recent completion records, newest first.

  When `project_name` is `:all`, returns rows across all projects; otherwise
  filters to the named project. `limit` is clamped to `1..1000`.
  """
  @spec recent(String.t() | :all, pos_integer(), GenServer.server()) :: [map()]
  def recent(project_name, limit, server \\ __MODULE__)
      when (is_binary(project_name) or project_name == :all) and is_integer(limit) and limit > 0 do
    GenServer.call(server, {:recent, project_name, clamp_limit(limit)})
  end

  @doc """
  Return the number of completion records stored for the given project (or all).
  """
  @spec count(String.t() | :all, GenServer.server()) :: non_neg_integer()
  def count(project_name, server \\ __MODULE__)
      when is_binary(project_name) or project_name == :all do
    GenServer.call(server, {:count, project_name})
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, Application.get_env(:cymphony_elixir, :completion_store_path, default_path()))

    case open_and_migrate(path) do
      {:ok, db} ->
        {:ok, %{db: db, path: path, degraded: false}}

      {:error, reason} ->
        Logger.warning("event=\"completion_store.unavailable\" path=#{inspect(path)} reason=#{inspect(reason)}")

        {:ok, %{db: nil, path: path, degraded: true}}
    end
  end

  @impl true
  def handle_cast({:put, _record}, %{degraded: true} = state), do: {:noreply, state}

  def handle_cast({:put, record}, %{db: db} = state) when not is_nil(db) do
    started = System.monotonic_time(:microsecond)

    case write_record(db, record) do
      :ok ->
        duration_ms = duration_ms_since(started)

        Logger.debug("event=\"completion_store.write\" status=ok issue_id=#{inspect(record[:issue_id])} project=#{inspect(record[:project_name])} duration_ms=#{duration_ms}")

      {:error, reason} ->
        duration_ms = duration_ms_since(started)

        Logger.warning("event=\"completion_store.write\" status=error issue_id=#{inspect(record[:issue_id])} reason=#{inspect(reason)} duration_ms=#{duration_ms}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:recent, _project, _limit}, _from, %{degraded: true} = state),
    do: {:reply, [], state}

  def handle_call({:recent, project_name, limit}, _from, %{db: db} = state) when not is_nil(db) do
    rows = read_recent(db, project_name, limit)
    {:reply, rows, state}
  end

  def handle_call({:count, _project}, _from, %{degraded: true} = state), do: {:reply, 0, state}

  def handle_call({:count, project_name}, _from, %{db: db} = state) when not is_nil(db) do
    {:reply, read_count(db, project_name), state}
  end

  @impl true
  def terminate(_reason, %{db: nil}), do: :ok
  def terminate(_reason, %{db: db}), do: Sqlite3.close(db)

  @spec default_path() :: Path.t()
  def default_path do
    Path.join([System.user_home() || System.tmp_dir!(), ".cymphony", "sessions.db"])
  end

  defp open_and_migrate(path) do
    with :ok <- ensure_parent_dir(path),
         {:ok, db} <- Sqlite3.open(path, []),
         :ok <- Sqlite3.execute(db, "PRAGMA busy_timeout = 5000"),
         :ok <- Sqlite3.execute(db, "PRAGMA journal_mode = WAL"),
         :ok <- run_column_renames(db),
         :ok <- run_migrations(db),
         :ok <- run_column_adds(db),
         :ok <- chmod_secret(path) do
      {:ok, db}
    end
  end

  defp run_column_renames(db) do
    Enum.each(@column_renames, fn {old, new} ->
      # An error means the old column doesn't exist (fresh DB) — ignore.
      _ = Sqlite3.execute(db, "ALTER TABLE sessions RENAME COLUMN #{old} TO #{new}")
    end)

    :ok
  end

  defp run_column_adds(db) do
    Enum.each(@column_adds, fn stmt -> _ = Sqlite3.execute(db, stmt) end)
    :ok
  end

  defp ensure_parent_dir(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_p, reason}}
    end
  end

  defp run_migrations(db) do
    Enum.reduce_while(@schema, :ok, fn stmt, _acc ->
      case Sqlite3.execute(db, stmt) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:migration, reason}}}
      end
    end)
  end

  defp chmod_secret(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:chmod, reason}}
    end
  end

  defp write_record(db, record) do
    sql = """
    INSERT OR REPLACE INTO sessions (
      issue_id, identifier, project_name, ended_at, started_at, runtime_seconds,
      input_tokens, output_tokens, total_tokens,
      worker_host, workspace_path, agent_kind, model
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    with {:ok, stmt} <- Sqlite3.prepare(db, sql),
         :ok <- Sqlite3.bind(stmt, record_to_params(record)),
         :done <- Sqlite3.step(db, stmt),
         :ok <- Sqlite3.release(db, stmt) do
      :ok
    else
      {:error, _reason} = err -> err
      other -> {:error, {:unexpected_step, other}}
    end
  end

  defp record_to_params(record) do
    [
      Map.get(record, :issue_id) || "",
      Map.get(record, :identifier),
      Map.get(record, :project_name),
      iso8601(Map.get(record, :ended_at)),
      iso8601(Map.get(record, :started_at)),
      Map.get(record, :runtime_seconds),
      Map.get(record, :input_tokens) || 0,
      Map.get(record, :output_tokens) || 0,
      Map.get(record, :total_tokens) || 0,
      Map.get(record, :worker_host),
      Map.get(record, :workspace_path),
      Map.get(record, :agent_kind),
      Map.get(record, :model)
    ]
  end

  defp read_recent(db, project_name, limit) do
    {sql, params} =
      case project_name do
        :all ->
          {"""
           SELECT issue_id, identifier, project_name, ended_at, started_at, runtime_seconds,
                  input_tokens, output_tokens, total_tokens,
                  worker_host, workspace_path, agent_kind, model
             FROM sessions
            ORDER BY ended_at DESC
            LIMIT ?
           """, [limit]}

        name when is_binary(name) ->
          {"""
           SELECT issue_id, identifier, project_name, ended_at, started_at, runtime_seconds,
                  input_tokens, output_tokens, total_tokens,
                  worker_host, workspace_path, agent_kind, model
             FROM sessions
            WHERE project_name = ?
            ORDER BY ended_at DESC
            LIMIT ?
           """, [name, limit]}
      end

    with {:ok, stmt} <- Sqlite3.prepare(db, sql),
         :ok <- Sqlite3.bind(stmt, params),
         {:ok, rows} <- Sqlite3.fetch_all(db, stmt),
         :ok <- Sqlite3.release(db, stmt) do
      Enum.map(rows, &row_to_map/1)
    else
      {:error, reason} ->
        Logger.warning("event=\"completion_store.read\" status=error reason=#{inspect(reason)}")
        []
    end
  end

  defp read_count(db, project_name) do
    {sql, params} =
      case project_name do
        :all -> {"SELECT COUNT(*) FROM sessions", []}
        name when is_binary(name) -> {"SELECT COUNT(*) FROM sessions WHERE project_name = ?", [name]}
      end

    with {:ok, stmt} <- Sqlite3.prepare(db, sql),
         :ok <- Sqlite3.bind(stmt, params),
         {:row, [count]} <- Sqlite3.step(db, stmt),
         :ok <- Sqlite3.release(db, stmt) do
      count
    else
      _ -> 0
    end
  end

  defp row_to_map([
         issue_id,
         identifier,
         project_name,
         ended_at,
         started_at,
         runtime_seconds,
         input,
         output,
         total,
         worker_host,
         workspace_path,
         agent_kind,
         model
       ]) do
    %{
      issue_id: issue_id,
      identifier: identifier,
      project_name: project_name,
      ended_at: parse_iso8601(ended_at),
      started_at: parse_iso8601(started_at),
      runtime_seconds: runtime_seconds,
      input_tokens: input || 0,
      output_tokens: output || 0,
      total_tokens: total || 0,
      worker_host: worker_host,
      workspace_path: workspace_path,
      agent_kind: agent_kind,
      model: model
    }
  end

  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(nil), do: nil
  defp iso8601(value) when is_binary(value), do: value

  defp parse_iso8601(nil), do: nil

  defp parse_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp clamp_limit(limit) when limit > @max_limit, do: @max_limit
  defp clamp_limit(limit), do: limit

  defp duration_ms_since(started_micros) do
    div(System.monotonic_time(:microsecond) - started_micros, 1_000)
  end
end
