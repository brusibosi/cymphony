defmodule CymphonyElixir.Cymphony.Config do
  @moduledoc false

  require Logger

  alias CymphonyElixir.Agent
  alias CymphonyElixir.Cymphony.Defaults
  alias CymphonyElixir.Cymphony.ShellProvider

  @config_dir "~/.cymphony"
  @config_file "config.json"
  @default_dashboard_refresh_seconds 3
  # Owner read/write only: config.json carries the Linear API key in cleartext.
  @file_mode 0o600

  @spec config_dir() :: String.t()
  def config_dir do
    case Application.get_env(:cymphony_elixir, :config_dir_override) do
      override when is_binary(override) -> override
      _ -> Path.expand(@config_dir)
    end
  end

  @spec config_path() :: String.t()
  def config_path, do: Path.join(config_dir(), @config_file)

  @spec exists?() :: boolean()
  def exists?, do: File.regular?(config_path())

  @spec load() :: {:ok, map()} | {:error, term()}
  def load do
    case File.read(config_path()) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, parsed} when is_map(parsed) -> {:ok, normalize(parsed)}
          {:ok, _parsed} -> {:error, "Invalid config in #{config_path()}: expected a JSON object"}
          {:error, reason} -> {:error, "Invalid JSON in #{config_path()}: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to read #{config_path()}: #{inspect(reason)}"}
    end
  end

  @doc """
  Normalizes a config map into the multi-project format.

  Old flat format (no "projects" key) is converted to a single-element
  projects array with name derived from the linear_project_slug.
  """
  @spec normalize(map()) :: map()
  def normalize(%{"projects" => [_ | _]} = config), do: config

  def normalize(config) when is_map(config) do
    if Map.has_key?(config, "projects") do
      config
    else
      name = Map.get(config, "linear_project_slug", "default")
      project = Map.put(config, "name", name)
      Map.put(%{}, "projects", [project])
    end
  end

  @doc """
  Extracts the list of project configs from a normalized config map.
  """
  @spec projects(map()) :: [map()]
  def projects(%{"projects" => projects}) when is_list(projects), do: projects
  def projects(_config), do: []

  @doc """
  Finds a single project by name from a normalized config map.
  """
  @spec find_project(map(), String.t()) :: {:ok, map()} | {:error, :project_not_found}
  def find_project(config, project_name) when is_binary(project_name) do
    case Enum.find(projects(config), &(&1["name"] == project_name)) do
      nil -> {:error, :project_not_found}
      project -> {:ok, project}
    end
  end

  @doc """
  Resolves the shared Linear API key.

  Prefers a non-empty `config["linear_api_key"]`, then the first non-empty
  project `linear_api_key`, then `LINEAR_API_KEY`.
  """
  @spec resolve_linear_api_key(map() | nil) :: String.t() | nil
  def resolve_linear_api_key(nil), do: env_linear_api_key()

  def resolve_linear_api_key(config) when is_map(config) do
    file_linear_api_key(config) || env_linear_api_key()
  end

  @doc """
  Masks a Linear API key as `••••` plus the last 4 characters.

  Keys shorter than 4 characters (after trim) are entirely `••••` so the
  mask never encodes the key length.
  """
  @spec mask_linear_api_key(String.t()) :: String.t()
  def mask_linear_api_key(key) when is_binary(key) do
    trimmed = String.trim(key)

    if String.length(trimmed) < 4 do
      "••••"
    else
      "••••" <> String.slice(trimmed, -4, 4)
    end
  end

  @doc """
  Where `resolve_linear_api_key/1` would get a key from: the config file,
  the process environment, or nowhere.
  """
  @spec linear_key_source(map() | nil) :: :config | :env | nil
  def linear_key_source(nil) do
    if is_binary(env_linear_api_key()), do: :env, else: nil
  end

  def linear_key_source(config) when is_map(config) do
    cond do
      is_binary(file_linear_api_key(config)) -> :config
      is_binary(env_linear_api_key()) -> :env
      true -> nil
    end
  end

  @doc """
  Persists a shared Linear API key to `config.json` (created if missing).

  Sets the top-level `linear_api_key` and stamps the same value onto every
  `projects[]` entry. `save/1` keeps the file mode at `0o600`.
  """
  @spec put_linear_api_key(String.t()) :: {:ok, map()} | {:error, :empty | term()}
  def put_linear_api_key(key) when is_binary(key) do
    case String.trim(key) do
      "" -> {:error, :empty}
      trimmed -> persist_linear_api_key(trimmed)
    end
  end

  @doc """
  Appends a project to `config.json`, inheriting the shared Linear API key.
  """
  @spec add_project(map()) ::
          {:ok, map()}
          | {:error, :duplicate_name | :duplicate_slug | :not_connected | :invalid_project | term()}
  def add_project(attrs) when is_map(attrs) do
    with_write_lock(fn ->
      with {:ok, name} <- required_project_string(attrs, "name"),
           {:ok, slug} <- required_project_string(attrs, "linear_project_slug"),
           {:ok, config} <- load_or_empty_config(),
           {:ok, api_key} <- connected_linear_api_key(config),
           :ok <- reject_duplicate_project(config, name, slug) do
        project = build_added_project(attrs, name, slug, api_key)
        persist_added_project(config, project)
      end
    end)
  end

  defp persist_linear_api_key(key) do
    with_write_lock(fn ->
      with {:ok, config} <- load_or_empty_config() do
        save_stamped_linear_api_key(config, key)
      end
    end)
  end

  defp save_stamped_linear_api_key(config, key) do
    updated = stamp_linear_api_key(config, key)

    case save(updated) do
      :ok -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_added_project(config, project) do
    updated = Map.put(config, "projects", projects(config) ++ [project])

    case save(updated) do
      :ok -> {:ok, project}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_or_empty_config do
    case load() do
      {:ok, config} ->
        {:ok, config}

      {:error, reason} ->
        if exists?() do
          {:error, reason}
        else
          {:ok, %{"projects" => []}}
        end
    end
  end

  defp stamp_linear_api_key(config, key) do
    config
    |> Map.put("linear_api_key", key)
    |> stamp_projects_linear_key(key)
  end

  defp stamp_projects_linear_key(%{"projects" => projects} = config, key) when is_list(projects) do
    Map.put(config, "projects", Enum.map(projects, &Map.put(&1, "linear_api_key", key)))
  end

  defp stamp_projects_linear_key(config, _key), do: config

  defp file_linear_api_key(config) when is_map(config) do
    case present_string(Map.get(config, "linear_api_key")) do
      nil -> first_project_linear_api_key(projects(config))
      key -> key
    end
  end

  defp first_project_linear_api_key(project_list) do
    Enum.find_value(project_list, fn project ->
      present_string(Map.get(project, "linear_api_key"))
    end)
  end

  defp env_linear_api_key, do: present_string(System.get_env("LINEAR_API_KEY"))

  defp connected_linear_api_key(config) do
    case resolve_linear_api_key(config) do
      key when is_binary(key) -> {:ok, key}
      _ -> {:error, :not_connected}
    end
  end

  defp required_project_string(attrs, key) do
    case present_string(Map.get(attrs, key)) do
      nil -> {:error, :invalid_project}
      value -> {:ok, value}
    end
  end

  defp reject_duplicate_project(config, name, slug) do
    existing = projects(config)

    cond do
      Enum.any?(existing, &(present_string(&1["name"]) == name)) ->
        {:error, :duplicate_name}

      Enum.any?(existing, &(present_string(&1["linear_project_slug"]) == slug)) ->
        {:error, :duplicate_slug}

      true ->
        :ok
    end
  end

  defp build_added_project(attrs, name, slug, api_key) do
    %{
      "name" => name,
      "linear_project_slug" => slug,
      "linear_api_key" => api_key,
      "workspace_root" => added_workspace_root(attrs, name),
      "polling_interval_ms" => added_polling_interval_ms(attrs)
    }
    |> maybe_put_copied(attrs, "github_repo_url")
    |> maybe_put_agent(attrs)
    |> maybe_put_copied(attrs, "model")
    |> maybe_put_copied(attrs, "effort")
    |> maybe_put_copied(attrs, "provider")
  end

  defp added_workspace_root(attrs, name) do
    case present_string(Map.get(attrs, "workspace_root")) do
      nil -> Path.join(Defaults.workspace_root(), name)
      root -> root
    end
  end

  defp added_polling_interval_ms(attrs) do
    case Map.get(attrs, "polling_interval_ms") do
      n when is_integer(n) and n > 0 -> n
      _ -> Defaults.polling_interval_ms()
    end
  end

  defp maybe_put_copied(map, attrs, key) do
    case present_string(Map.get(attrs, key)) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp maybe_put_agent(map, attrs) do
    case present_string(Map.get(attrs, "agent")) do
      nil ->
        map

      kind ->
        if Agent.known_kind?(kind), do: Map.put(map, "agent", kind), else: map
    end
  end

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(_value), do: nil

  @doc """
  Updates `max_concurrent_agents` for the named project (or for the entire
  legacy single-project config if `project_name` is `nil`) and persists to
  disk. Returns `{:ok, updated_config}` or an error tuple.
  """
  @spec update_concurrency(String.t() | nil, pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def update_concurrency(project_name, n) when is_integer(n) and n > 0 do
    with_write_lock(fn ->
      with {:ok, config} <- load(),
           {:ok, updated} <- apply_concurrency(config, project_name, n),
           :ok <- save(updated) do
        {:ok, updated}
      end
    end)
  end

  defp apply_concurrency(%{"projects" => projects} = config, project_name, n)
       when is_list(projects) do
    updated_projects =
      Enum.map(projects, fn project ->
        cond do
          is_nil(project_name) ->
            Map.put(project, "max_concurrent_agents", n)

          project["name"] == project_name ->
            Map.put(project, "max_concurrent_agents", n)

          true ->
            project
        end
      end)

    {:ok, Map.put(config, "projects", updated_projects)}
  end

  defp apply_concurrency(config, _project_name, n) when is_map(config) do
    {:ok, Map.put(config, "max_concurrent_agents", n)}
  end

  @doc """
  Persists the dispatch-pause flag for the named project (every project when
  `project_name` is `nil`) and saves to disk.

  Stored as the per-project boolean `"dispatch_paused"` so a paused project
  stays paused across a daemon restart — `Orchestrator.init/1` reads it back
  before the first poll tick. Returns `{:ok, updated_config}` or an error tuple.
  """
  @spec update_dispatch_paused(String.t() | nil, boolean()) ::
          {:ok, map()} | {:error, term()}
  def update_dispatch_paused(project_name, paused?) when is_boolean(paused?) do
    with_write_lock(fn ->
      with {:ok, config} <- load(),
           {:ok, updated} <- apply_dispatch_paused(config, project_name, paused?),
           :ok <- save(updated) do
        {:ok, updated}
      end
    end)
  end

  defp apply_dispatch_paused(%{"projects" => projects} = config, project_name, paused?)
       when is_list(projects) do
    updated_projects =
      Enum.map(projects, fn project ->
        if is_nil(project_name) or project["name"] == project_name do
          Map.put(project, "dispatch_paused", paused?)
        else
          project
        end
      end)

    {:ok, Map.put(config, "projects", updated_projects)}
  end

  defp apply_dispatch_paused(config, _project_name, paused?) when is_map(config) do
    {:ok, Map.put(config, "dispatch_paused", paused?)}
  end

  @doc """
  Reads back the persisted dispatch-pause flag for a project.

  Prefers the named project's `"dispatch_paused"` (or the sole project's when
  `project_name` is `nil`), falling back to the top-level key for a legacy flat
  config. Anything other than a stored `true` is `false`.
  """
  @spec dispatch_paused?(map(), String.t() | nil) :: boolean()
  def dispatch_paused?(config, project_name) when is_map(config) do
    case dispatch_paused_project(config, project_name) do
      {:ok, project} -> Map.get(project, "dispatch_paused") == true
      :error -> Map.get(config, "dispatch_paused") == true
    end
  end

  defp dispatch_paused_project(config, project_name) when is_binary(project_name) do
    case find_project(config, project_name) do
      {:ok, project} -> {:ok, project}
      {:error, :project_not_found} -> :error
    end
  end

  defp dispatch_paused_project(config, _project_name) do
    case projects(config) do
      [project] when is_map(project) -> {:ok, project}
      _ -> :error
    end
  end

  @doc """
  Dashboard payload refresh interval in seconds.

  Loads `config.json` and returns a positive integer. Missing or unreadable
  files, and any non-positive stored value, fall back to `3`.
  """
  @spec dashboard_refresh_seconds() :: pos_integer()
  def dashboard_refresh_seconds do
    case load() do
      {:ok, config} -> dashboard_refresh_seconds(config)
      _ -> @default_dashboard_refresh_seconds
    end
  end

  @doc """
  Normalizes a stored or in-memory refresh interval.

  A positive integer is returned as-is. A config map uses its top-level
  `dashboard_refresh_seconds` key. Anything else (including `0`, negatives,
  strings, and a missing key) is `3`.
  """
  @spec dashboard_refresh_seconds(term()) :: pos_integer()
  def dashboard_refresh_seconds(n) when is_integer(n) and n > 0, do: n

  def dashboard_refresh_seconds(config) when is_map(config) do
    dashboard_refresh_seconds(Map.get(config, "dashboard_refresh_seconds"))
  end

  def dashboard_refresh_seconds(_value), do: @default_dashboard_refresh_seconds

  @doc """
  Persists the daemon-wide dashboard payload refresh interval as a top-level
  `config.json` key (beside `projects`, never inside a project map).

  Requires an existing readable file, same as the other `update_*` helpers.
  Rejects non-positive values. Does not write `polling_interval_ms` or
  rewrite `WORKFLOW.md`.
  """
  @spec update_dashboard_refresh_seconds(term()) :: {:ok, map()} | {:error, term()}
  def update_dashboard_refresh_seconds(n) when is_integer(n) and n > 0 do
    with_write_lock(fn ->
      with {:ok, config} <- load(),
           updated = Map.put(config, "dashboard_refresh_seconds", n),
           :ok <- save(updated) do
        {:ok, updated}
      end
    end)
  end

  def update_dashboard_refresh_seconds(_n), do: {:error, :invalid_refresh_interval}

  @doc """
  Updates `provider` (head) and `providers` (full list) for the named project
  (or for all projects if `project_name` is `nil`) and persists to disk.
  Returns `{:ok, updated_config}` or an error tuple.
  """
  @spec update_providers(String.t() | nil, [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def update_providers(project_name, providers)
      when is_list(providers) and providers != [] do
    with_write_lock(fn ->
      with {:ok, config} <- load(),
           {:ok, updated} <- apply_providers(config, project_name, providers),
           :ok <- save(updated) do
        {:ok, updated}
      end
    end)
  end

  def update_providers(_project_name, _providers), do: {:error, :invalid_providers}

  defp apply_providers(%{"projects" => projects} = config, project_name, providers)
       when is_list(projects) do
    updated_projects =
      Enum.map(projects, fn project ->
        cond do
          is_nil(project_name) ->
            put_providers(project, providers)

          project["name"] == project_name ->
            put_providers(project, providers)

          true ->
            project
        end
      end)

    {:ok, Map.put(config, "projects", updated_projects)}
  end

  defp apply_providers(config, _project_name, providers) when is_map(config) do
    {:ok, put_providers(config, providers)}
  end

  defp put_providers(map, providers) do
    map
    |> Map.put("provider", hd(providers))
    |> Map.put("providers", providers)
  end

  @agent_setting_keys ["agent", "model", "effort"]
  @flat_agent_setting_keys ["claude_bare_mode", "max_retry_backoff_ms"]

  @doc """
  Merges agent settings (`"agent"`, `"model"`, `"effort"`) onto the named
  project (or all projects when `project_name` is nil) and saves. Keys absent
  from `settings` are untouched; empty-string values delete the key.

  Two further flat per-project keys are supported and generated into the
  native nested workflow (see `to_schema_map/1`):

    * `"claude_bare_mode"` — boolean; `false` omits `--bare` from the Claude
      command (`claude.bare_mode`). Absent means the default (`true`).
    * `"max_retry_backoff_ms"` — positive integer; the failure-retry backoff cap
      (`agent.max_retry_backoff_ms`). Absent means the schema default.

  `nil` deletes either key. Any other value is rejected with
  `{:error, :invalid_claude_bare_mode | :invalid_max_retry_backoff_ms}` before
  `config.json` is read or written, so a bad value never replaces a valid one.
  """
  @spec update_agent_settings(String.t() | nil, map()) ::
          :ok
          | {:error, :invalid_agent_kind | :invalid_claude_bare_mode | :invalid_max_retry_backoff_ms | term()}
  def update_agent_settings(project_name, settings) when is_map(settings) do
    with_write_lock(fn ->
      with :ok <- validate_agent_kind(Map.get(settings, "agent")),
           :ok <- validate_claude_bare_mode(settings),
           :ok <- validate_max_retry_backoff_ms(settings),
           {:ok, config} <- load(),
           {:ok, updated} <- apply_agent_settings(config, project_name, settings) do
        save(updated)
      end
    end)
  end

  defp validate_agent_kind(nil), do: :ok

  defp validate_agent_kind(kind) do
    if kind in Agent.known_kinds(), do: :ok, else: {:error, :invalid_agent_kind}
  end

  defp validate_claude_bare_mode(settings) do
    case Map.fetch(settings, "claude_bare_mode") do
      :error -> :ok
      {:ok, value} when is_boolean(value) or is_nil(value) -> :ok
      {:ok, _value} -> {:error, :invalid_claude_bare_mode}
    end
  end

  defp validate_max_retry_backoff_ms(settings) do
    case Map.fetch(settings, "max_retry_backoff_ms") do
      :error -> :ok
      {:ok, value} when is_nil(value) -> :ok
      {:ok, value} when is_integer(value) and value > 0 -> :ok
      {:ok, _value} -> {:error, :invalid_max_retry_backoff_ms}
    end
  end

  defp apply_agent_settings(%{"projects" => projects} = config, project_name, settings)
       when is_list(projects) do
    updated_projects =
      Enum.map(projects, fn project ->
        if project_name == nil or Map.get(project, "name") == project_name do
          merge_agent_settings(project, settings)
        else
          project
        end
      end)

    {:ok, Map.put(config, "projects", updated_projects)}
  end

  defp apply_agent_settings(config, _project_name, settings) when is_map(config) do
    {:ok, merge_agent_settings(config, settings)}
  end

  defp merge_agent_settings(map, settings) do
    string_merged =
      Enum.reduce(@agent_setting_keys, map, fn key, acc ->
        case Map.fetch(settings, key) do
          {:ok, ""} -> Map.delete(acc, key)
          {:ok, value} when is_binary(value) -> Map.put(acc, key, value)
          _ -> acc
        end
      end)

    # Already validated by `update_agent_settings/2`: a boolean/positive integer
    # sets the key, `nil` returns it to absent.
    Enum.reduce(@flat_agent_setting_keys, string_merged, fn key, acc ->
      case Map.fetch(settings, key) do
        {:ok, nil} -> Map.delete(acc, key)
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  @queue_attr_keys ["queue_order", "queue_pins", "queue_priority_seen"]
  @queue_pin_field_keys ["agent_kind", "model", "effort"]

  @doc """
  Merges per-project dispatch-queue keys onto `config.json` and `save/1`s.

  Accepts any of `"queue_order"` (list of identifier binaries), `"queue_pins"`
  (identifier => `%{"agent_kind"|"model"|"effort" => binary}`), and
  `"queue_priority_seen"` (identifier => integer | nil). Empty pin fields and
  empty pin entries are dropped. Provided keys replace the stored value
  (`queue_pins` is the full map, not a per-id patch).

  `project_name` nil updates every `projects[]` entry (and a legacy flat map
  when `projects` is not a list). Does not rewrite `WORKFLOW.md` or touch
  `dashboard_refresh_seconds`.
  """
  @spec update_project_queue(String.t() | nil, map()) ::
          {:ok, map()} | {:error, :invalid_queue | term()}
  def update_project_queue(project_name, attrs)
      when (is_binary(project_name) or is_nil(project_name)) and is_map(attrs) do
    with_write_lock(fn ->
      with {:ok, sanitized} <- sanitize_queue_attrs(attrs),
           {:ok, config} <- load(),
           {:ok, updated} <- apply_project_queue(config, project_name, sanitized),
           :ok <- save(updated) do
        {:ok, updated}
      end
    end)
  end

  def update_project_queue(_project_name, _attrs), do: {:error, :invalid_queue}

  @doc "Atomically patches one issue's queue pin without replacing other pins."
  @spec update_project_queue_pin(String.t() | nil, String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def update_project_queue_pin(project_name, issue_key, pin)
      when (is_binary(project_name) or is_nil(project_name)) and is_binary(issue_key) and
             is_map(pin) do
    with_write_lock(fn ->
      with {:ok, id} <- sanitize_queue_id(issue_key),
           {:ok, fields} <- sanitize_pin_fields(pin),
           {:ok, config} <- load(),
           {:ok, project} <- queue_project(config, project_name),
           existing when is_map(existing) <- Map.get(project, "queue_pins", %{}),
           {:ok, pins} <- sanitize_queue_pins(existing),
           updated_pins = patch_queue_pin(pins, id, pin, fields),
           {:ok, updated} <- apply_project_queue(config, project_name, %{"queue_pins" => updated_pins}),
           :ok <- save(updated) do
        {:ok, updated_pins}
      else
        :error -> {:error, :invalid_queue_pin}
        {:error, _} = error -> error
        _ -> {:error, :invalid_queue_pin}
      end
    end)
  end

  def update_project_queue_pin(_project_name, _issue_key, _pin), do: {:error, :invalid_queue_pin}

  defp queue_project(%{"projects" => projects}, project_name) when is_list(projects) do
    case Enum.find(projects, &(&1["name"] == project_name)) do
      nil -> {:error, :project_not_found}
      project -> {:ok, project}
    end
  end

  defp queue_project(config, _project_name) when is_map(config), do: {:ok, config}

  defp patch_queue_pin(pins, id, pin, _fields) when map_size(pin) == 0,
    do: Map.delete(pins, id)

  defp patch_queue_pin(pins, id, _pin, fields) do
    Map.update(pins, id, fields, &Map.merge(&1, fields))
  end

  @doc "Looks up a top-level config provider map, filtering for the active agent."
  @spec provider_env(String.t(), [String.t()]) :: {:ok, map()} | :not_found
  def provider_env(name, prefixes) when is_binary(name) and is_list(prefixes) do
    case load() do
      {:ok, %{"providers" => providers}} when is_map(providers) ->
        case Map.get(providers, name) do
          env when is_map(env) ->
            {:ok,
             env
             |> Enum.filter(fn {key, value} ->
               is_binary(key) and is_binary(value) and
                 Enum.any?(prefixes, &String.starts_with?(key, &1))
             end)
             |> Map.new()}

          _ ->
            :not_found
        end

      _ ->
        :not_found
    end
  end

  defp sanitize_queue_attrs(attrs) do
    Enum.reduce_while(@queue_attr_keys, {:ok, %{}}, &sanitize_queue_attr_step(&1, &2, attrs))
  end

  defp sanitize_queue_attr_step(key, {:ok, acc}, attrs) do
    case Map.fetch(attrs, key) do
      :error -> {:cont, {:ok, acc}}
      {:ok, value} -> put_sanitized_queue_attr(acc, key, value)
    end
  end

  defp put_sanitized_queue_attr(acc, key, value) do
    case sanitize_queue_attr(key, value) do
      {:ok, sanitized} -> {:cont, {:ok, Map.put(acc, key, sanitized)}}
      :error -> {:halt, {:error, :invalid_queue}}
    end
  end

  defp sanitize_queue_attr("queue_order", value), do: sanitize_queue_order(value)
  defp sanitize_queue_attr("queue_pins", value), do: sanitize_queue_pins(value)
  defp sanitize_queue_attr("queue_priority_seen", value), do: sanitize_queue_priority_seen(value)

  defp sanitize_queue_order(order) when is_list(order), do: collect_queue_ids(order)
  defp sanitize_queue_order(_order), do: :error

  defp sanitize_queue_pins(pins) when is_map(pins) do
    Enum.reduce_while(pins, {:ok, %{}}, &sanitize_queue_pin_step/2)
  end

  defp sanitize_queue_pins(_pins), do: :error

  defp sanitize_queue_pin_step({key, pin}, {:ok, acc}) do
    with {:ok, id} <- sanitize_queue_id(key),
         {:ok, fields} <- sanitize_pin_fields(pin) do
      {:cont, {:ok, put_present_pin(acc, id, fields)}}
    else
      :error -> {:halt, :error}
    end
  end

  defp put_present_pin(acc, _id, fields) when map_size(fields) == 0, do: acc
  defp put_present_pin(acc, id, fields), do: Map.put(acc, id, fields)

  defp sanitize_queue_priority_seen(seen) when is_map(seen) do
    Enum.reduce_while(seen, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, id} <- sanitize_queue_id(key),
           {:ok, priority} <- sanitize_seen_priority(value) do
        {:cont, {:ok, Map.put(acc, id, priority)}}
      else
        :error -> {:halt, :error}
      end
    end)
  end

  defp sanitize_queue_priority_seen(_seen), do: :error

  defp collect_queue_ids(values) do
    values
    |> Enum.reduce_while({:ok, []}, &collect_queue_id_step/2)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      :error -> :error
    end
  end

  defp collect_queue_id_step(value, {:ok, acc}) do
    case sanitize_queue_id(value) do
      {:ok, id} -> {:cont, {:ok, [id | acc]}}
      :error -> skip_or_halt_queue_id(value, acc)
    end
  end

  # A blank entry is dropped rather than rejecting the whole order, so a stray
  # empty string in `config.json` cannot make the queue unloadable.
  defp skip_or_halt_queue_id(value, acc) do
    if blank_queue_id?(value), do: {:cont, {:ok, acc}}, else: {:halt, :error}
  end

  defp blank_queue_id?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_queue_id?(_value), do: false

  defp sanitize_queue_id(key) when is_binary(key) do
    case String.trim(key) do
      "" -> :error
      trimmed -> {:ok, trimmed}
    end
  end

  defp sanitize_queue_id(_key), do: :error

  defp sanitize_pin_fields(pin) when is_map(pin) do
    fields =
      Enum.reduce(@queue_pin_field_keys, %{}, fn key, acc ->
        case pin_field_value(pin, key) do
          value when is_binary(value) -> put_present_pin_field(acc, key, value)
          _ -> acc
        end
      end)

    {:ok, fields}
  end

  defp sanitize_pin_fields(_pin), do: :error

  defp pin_field_value(pin, "agent_kind") do
    binary_pin_value(pin, ["agent_kind", :agent_kind, "kind", :kind])
  end

  defp pin_field_value(pin, "model"), do: binary_pin_value(pin, ["model", :model])
  defp pin_field_value(pin, "effort"), do: binary_pin_value(pin, ["effort", :effort])

  defp binary_pin_value(pin, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(pin, key) do
        value when is_binary(value) -> value
        _ -> nil
      end
    end)
  end

  defp put_present_pin_field(acc, key, value) do
    case String.trim(value) do
      "" -> acc
      "keep" -> acc
      trimmed -> Map.put(acc, key, trimmed)
    end
  end

  defp sanitize_seen_priority(value) when is_integer(value) or is_nil(value), do: {:ok, value}
  defp sanitize_seen_priority(_value), do: :error

  defp apply_project_queue(%{"projects" => projects} = config, project_name, attrs)
       when is_list(projects) do
    updated_projects =
      Enum.map(projects, fn project ->
        cond do
          is_nil(project_name) ->
            put_queue_attrs(project, attrs)

          project["name"] == project_name ->
            put_queue_attrs(project, attrs)

          true ->
            project
        end
      end)

    {:ok, Map.put(config, "projects", updated_projects)}
  end

  defp apply_project_queue(config, _project_name, attrs) when is_map(config) do
    {:ok, put_queue_attrs(config, attrs)}
  end

  defp put_queue_attrs(project, attrs) do
    Enum.reduce(attrs, project, fn {key, value}, acc -> Map.put(acc, key, value) end)
  end

  @doc """
  Parses a comma-separated provider list into a normalized list of names.
  Trims whitespace and drops empty segments. Returns `{:error, :empty}` if no
  non-empty segments remain.
  """
  @spec parse_providers_csv(String.t()) :: {:ok, [String.t()]} | {:error, :empty | :invalid}
  def parse_providers_csv(value) when is_binary(value) do
    list =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    cond do
      list == [] -> {:error, :empty}
      Enum.all?(list, &ShellProvider.valid_name?/1) -> {:ok, list}
      true -> {:error, :invalid}
    end
  end

  def parse_providers_csv(_), do: {:error, :empty}

  @doc """
  Writes `config` to `config.json` at mode `0600`.

  Staged through a sibling temp file that is chmod'd while still empty and then
  renamed over the target, the same treatment `WorkflowGenerator.write/2` gives
  the generated `WORKFLOW.md`:

    * the Linear API key the file carries in cleartext is never on disk under a
      umask-derived mode, not even for the width of one `File.write/2`;
    * the rename is atomic, so a concurrent reader (`Orchestrator.init/1`
      seeding its persisted pause flag, another `update_*` load) never observes
      a truncated or half-written config, and a failed write leaves the
      previous file intact.
  """
  @spec save(map()) :: :ok | {:error, term()}
  def save(config) do
    dir = config_dir()

    with :ok <- File.mkdir_p(dir),
         {:ok, json} <- Jason.encode(config, pretty: true) do
      write_atomically(config_path(), json)
    end
  end

  # Serializes one `load → modify → save` against every other one on the node.
  #
  # The writers do not share a process: the dashboard LiveView, the JSON API
  # controller, and each project's Orchestrator (which persists `queue_order` /
  # `queue_priority_seen` from its poll tick whenever the waiting set moves) all
  # run the sequence themselves. Interleaved, the later `save/1` writes back a
  # config it loaded before the earlier one — silently dropping a freshly
  # persisted `dispatch_paused` (the daemon stays paused in memory, so nothing
  # looks wrong until the next restart resumes it) or a drag-reordered queue.
  #
  # `:global.trans/2` retries forever rather than returning `:aborted`, and
  # `:global` drops the locks of a process that dies holding one, so the only
  # outcome is the wrapped function's own result.
  defp with_write_lock(fun) do
    :global.trans({{__MODULE__, :config_write}, self()}, fun)
  end

  defp write_atomically(path, json) do
    staged = "#{path}.tmp-#{:erlang.unique_integer([:positive])}"

    with :ok <- File.write(staged, ""),
         :ok <- File.chmod(staged, @file_mode),
         :ok <- File.write(staged, json),
         :ok <- File.rename(staged, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(staged)
        {:error, "Failed to write #{path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Builds the Schema-shaped (nested, string-keyed) runtime config map for a
  project from its flat `config.json` representation, applying `Defaults`.

  This is the structured replacement for the old hand-built YAML string: the
  generator serializes this map (as JSON, which is valid YAML) into the
  `WORKFLOW.md` front matter, so values containing YAML metacharacters (`:`,
  `#`, quotes, newlines) round-trip safely and missing keys get explicit
  defaults rather than silently becoming Schema fallbacks.
  """
  @spec to_schema_map(map()) :: map()
  def to_schema_map(config) when is_map(config) do
    base = %{
      "tracker" => %{
        "kind" => "linear",
        "api_key" => Map.get(config, "linear_api_key", ""),
        "project_slug" => Map.get(config, "linear_project_slug", ""),
        "active_states" => Defaults.active_states(),
        "terminal_states" => Defaults.terminal_states()
      },
      "polling" => %{
        "interval_ms" => Map.get(config, "polling_interval_ms", Defaults.polling_interval_ms())
      },
      "workspace" => %{
        "root" => Map.get(config, "workspace_root", Defaults.workspace_root())
      },
      "agent" =>
        %{
          "kind" => agent_kind(config),
          "model" => Map.get(config, "model"),
          "effort" => Map.get(config, "effort"),
          "max_concurrent_agents" => Map.get(config, "max_concurrent_agents", Defaults.max_concurrent_agents()),
          "max_turns" => Defaults.max_turns(),
          "stall_timeout_ms" => stall_timeout_ms(config)
        }
        |> maybe_put_max_retry_backoff_ms(config),
      "claude" => agent_section_map(config, "claude"),
      "codex" => agent_section_map(config, "codex"),
      "antigravity" => agent_section_map(config, "antigravity")
    }

    maybe_put_hooks(base, config)
  end

  defp agent_kind(config) do
    kind = Map.get(config, "agent")
    if kind in Agent.known_kinds(), do: kind, else: Defaults.agent_kind()
  end

  # Only a positive integer is honored. A missing key, `0`, a negative number, a
  # float or a stringified number falls back to the schema default rather than
  # generating an out-of-range front-matter value: a typo must not silently
  # disable the stall watchdog (`stall_timeout_ms <= 0` turns it off) or fail
  # `Schema.parse/1` and take the whole project down.
  defp stall_timeout_ms(config) do
    case Map.get(config, "stall_timeout_ms") do
      value when is_integer(value) and value > 0 -> value
      _ -> Defaults.stall_timeout_ms()
    end
  end

  # Only a positive integer is honored, and only when present: an absent key
  # keeps the schema default (the generated file stays byte-compatible), while
  # a stored `0`, negative number, float or string is logged and ignored rather
  # than generating a front-matter value that fails `Schema.parse/1` or removes
  # the backoff cap.
  defp maybe_put_max_retry_backoff_ms(section, config) do
    case Map.fetch(config, "max_retry_backoff_ms") do
      :error -> section
      {:ok, nil} -> section
      {:ok, value} when is_integer(value) and value > 0 -> Map.put(section, "max_retry_backoff_ms", value)
      {:ok, value} -> warn_ignored_setting("max_retry_backoff_ms", "a positive integer", value, section)
    end
  end

  # `--bare` is on by default in the adapter, so absence must stay absent; an
  # explicit boolean (including `false`) is passed through. Anything else is
  # logged and ignored rather than silently flipping the flag.
  defp maybe_put_bare_mode(section, config) do
    case Map.fetch(config, "claude_bare_mode") do
      :error -> section
      {:ok, nil} -> section
      {:ok, value} when is_boolean(value) -> Map.put(section, "bare_mode", value)
      {:ok, value} -> warn_ignored_setting("claude_bare_mode", "a boolean", value, section)
    end
  end

  defp warn_ignored_setting(key, expected, value, section) do
    Logger.warning("Ignoring invalid #{key} in config.json: expected #{expected}, got #{inspect(value)}")
    section
  end

  defp agent_section_map(config, "claude") do
    %{"command" => Defaults.claude_command(), "output_format" => Defaults.output_format()}
    |> maybe_put_bare_mode(config)
    |> maybe_put_provider_keys(config, "claude")
    |> maybe_put_extra_args(config, "claude")
  end

  defp agent_section_map(config, "codex") do
    %{"command" => Defaults.codex_command(), "sandbox" => Defaults.codex_sandbox()}
    |> maybe_put_provider_keys(config, "codex")
    |> maybe_put_extra_args(config, "codex")
  end

  defp agent_section_map(config, "antigravity") do
    %{
      "command" => Defaults.antigravity_command(),
      "output_format" => "stream-json",
      "skip_permissions" => true
    }
    |> maybe_put_new_project(config)
    |> maybe_put_provider_keys(config, "antigravity")
    |> maybe_put_extra_args(config, "antigravity")
  end

  # `--new-project` is on by default in the adapter, so only an explicit `false`
  # needs to reach the front matter. Anything else (missing, `"false"`, `0`)
  # keeps the default rather than silently sandboxing agy back into
  # ~/.gemini/antigravity-cli/scratch.
  defp maybe_put_new_project(section, config) do
    case Map.get(config, "new_project") do
      false -> Map.put(section, "new_project", false)
      _ -> section
    end
  end

  # Providers are auth aliases for a specific backend: they belong to the
  # active kind's section only.
  defp maybe_put_provider_keys(section, config, kind) do
    if agent_kind(config) == kind do
      providers = Map.get(config, "providers", [])
      provider = Map.get(config, "provider")

      cond do
        is_list(providers) and providers != [] ->
          section
          |> Map.put("providers", providers)
          |> Map.put("provider", hd(providers))

        is_binary(provider) and provider != "" ->
          Map.put(section, "provider", provider)

        true ->
          section
      end
    else
      section
    end
  end

  # A per-kind map supplies each named agent's own pass-through flags, including
  # agents selected through issue overrides. The bare-list convenience form is
  # scoped to the default agent; flags never cross into another kind's section.
  #
  # Two accepted shapes on a `projects[]` entry:
  #
  #   "extra_args": {"antigravity": ["--new-project"], "codex": ["--full-auto"]}
  #   "extra_args": ["--new-project"]      # convenience form, active kind
  #
  # Only a list of strings is honored. Mirroring `stall_timeout_ms`, anything
  # else is ignored rather than written into front matter that would fail
  # `Schema.parse/1` and take the whole project down — but unlike a numeric
  # typo, a mistyped escape hatch is invisible, so it is logged.
  defp maybe_put_extra_args(section, config, kind) do
    if is_map(Map.get(config, "extra_args")) or agent_kind(config) == kind do
      case extra_args(config, kind) do
        [] -> section
        args -> Map.put(section, "extra_args", args)
      end
    else
      section
    end
  end

  defp extra_args(config, kind) do
    case Map.get(config, "extra_args") do
      nil -> []
      by_kind when is_map(by_kind) -> by_kind |> Map.get(kind) |> kind_extra_args()
      value -> string_list_or_warn(value)
    end
  end

  # A map with no entry for this kind is the normal case, not a mistake.
  defp kind_extra_args(nil), do: []
  defp kind_extra_args(value), do: string_list_or_warn(value)

  defp string_list_or_warn(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: value, else: warn_invalid_extra_args(value)
  end

  defp string_list_or_warn(value), do: warn_invalid_extra_args(value)

  defp warn_invalid_extra_args(value) do
    Logger.warning(
      "Ignoring invalid extra_args in config.json: expected a list of strings, " <>
        "or a map of agent kind to list of strings, got #{inspect(value)}"
    )

    []
  end

  defp maybe_put_hooks(base, config) do
    case Map.get(config, "github_repo_url", "") do
      repo when is_binary(repo) and repo != "" ->
        clone_url = github_clone_url(repo)
        Map.put(base, "hooks", %{"after_create" => "git clone --depth 1 -- #{CymphonyElixir.Shell.escape(clone_url)} .\n"})

      _ ->
        base
    end
  end

  # Prefer HTTPS so clone uses `gh auth` / git credentials. A host SSH key
  # is often a deploy key for a different repo; GitHub then reports
  # "Repository not found" and the workspace stays empty.
  defp github_clone_url(repo) do
    trimmed = String.trim(repo)

    case Regex.run(Regex.compile!("^git@github\\.com:([^/]+)/(.+?)(?:\\.git)?$"), trimmed) do
      [_, owner, name] -> "https://github.com/#{owner}/#{name}.git"
      _ -> trimmed
    end
  end
end
