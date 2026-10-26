defmodule CymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias CymphonyElixir.Config
  alias CymphonyElixir.Linear.{Issue, RateLimit}

  @issue_page_size 50
  @project_page_size 50
  @max_project_pages 10
  @default_linear_graphql_endpoint "https://api.linear.app/graphql"
  @max_error_body_log_bytes 1_000

  @query """
  query CymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
          type
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query CymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
          type
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @viewer_query """
  query CymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @query_by_ids_project @query_by_ids
                        |> String.replace("($ids:", "($projectSlug: String!, $ids:")
                        |> String.replace("filter: {id: {in: $ids}}", "filter: {id: {in: $ids}, project: {slugId: {eq: $projectSlug}}}")

  @projects_query """
  query CymphonyLinearProjects($first: Int!, $after: String) {
    projects(first: $first, after: $after) {
      nodes { id name slugId }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker
    project_slug = tracker.project_slug

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_linear_api_token}

      is_nil(project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_by_states(project_slug, tracker.active_states, assignee_filter)
        end
    end
  end

  @spec fetch_candidate_issues(term()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(config) when is_struct(config, Config.Schema) do
    tracker = config.tracker
    project_slug = tracker.project_slug

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_linear_api_token}

      is_nil(project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter(config) do
          do_fetch_by_states(project_slug, tracker.active_states, assignee_filter, config)
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker
      project_slug = tracker.project_slug

      cond do
        is_nil(tracker.api_key) ->
          {:error, :missing_linear_api_token}

        is_nil(project_slug) ->
          {:error, :missing_linear_project_slug}

        true ->
          do_fetch_by_states(project_slug, normalized_states, nil)
      end
    end
  end

  @spec fetch_issues_by_states([String.t()], term()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, config) when is_list(state_names) and is_struct(config, Config.Schema) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = config.tracker
      project_slug = tracker.project_slug

      cond do
        is_nil(tracker.api_key) ->
          {:error, :missing_linear_api_token}

        is_nil(project_slug) ->
          {:error, :missing_linear_project_slug}

        true ->
          do_fetch_by_states(project_slug, normalized_states, nil, config)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_issue_states(ids, assignee_filter)
        end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()], term()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, config) when is_list(issue_ids) and is_struct(config, Config.Schema) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with :ok <- require_project_slug(config.tracker.project_slug),
             {:ok, assignee_filter} <- routing_assignee_filter(config) do
          do_fetch_issue_states(ids, assignee_filter, config_graphql_fun(config), config.tracker.project_slug)
        end
    end
  end

  defp require_project_slug(slug) when is_binary(slug) and byte_size(slug) > 0, do: :ok
  defp require_project_slug(_slug), do: {:error, :missing_linear_project_slug}

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    headers_fun = Keyword.get(opts, :graphql_headers_fun, &graphql_headers/0)
    endpoint = graphql_endpoint(opts)

    with {:ok, headers} <- headers_fun.(),
         :ok <- RateLimit.check(endpoint, headers, opts) do
      execute_graphql(payload, headers, endpoint, opts)
    else
      {:error, {:linear_rate_limited, _until_ms}} = limited ->
        limited

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  defp execute_graphql(payload, headers, endpoint, opts) do
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    case request_fun.(payload, headers) do
      {:ok, %{status: 200, body: body} = response} ->
        case RateLimit.observe(endpoint, headers, response, opts) do
          :ok -> {:ok, body}
          limited -> limited
        end

      {:ok, response} ->
        RateLimit.observe(endpoint, headers, response, opts)
        context = RateLimit.redact(linear_error_context(payload, response, headers), headers)
        Logger.error("Linear GraphQL request failed status=#{response.status}" <> context)
        {:error, {:linear_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: " <> RateLimit.redact(inspect(reason, printable_limit: :infinity), headers))
        {:error, {:linear_api_request, reason}}
    end
  end

  defp graphql_endpoint(opts) do
    Keyword.get_lazy(opts, :endpoint, fn ->
      if Keyword.has_key?(opts, :request_fun),
        do: @default_linear_graphql_endpoint,
        else: Config.settings!().tracker.endpoint
    end)
  end

  @doc """
  Build `graphql/3` opts that authorize with `api_key` and do not read `Config.settings!/0`.
  """
  @spec graphql_opts_for_api_key(String.t(), keyword()) :: keyword()
  def graphql_opts_for_api_key(api_key, opts \\ []) when is_binary(api_key) and is_list(opts) do
    endpoint = resolve_linear_graphql_endpoint(opts)

    built_opts = [
      endpoint: endpoint,
      graphql_headers_fun: fn ->
        {:ok,
         [
           {"Authorization", api_key},
           {"Content-Type", "application/json"}
         ]}
      end,
      request_fun: fn payload, headers ->
        post_graphql_request_to(endpoint, payload, headers)
      end
    ]

    app_opts = Application.get_env(:cymphony_elixir, :linear_graphql_opts, [])
    app_opts = if Keyword.keyword?(app_opts), do: app_opts, else: []

    built_opts
    |> Keyword.merge(app_opts)
    |> Keyword.merge(Keyword.delete(opts, :endpoint))
    |> Keyword.put(:endpoint, endpoint)
  end

  @doc """
  Validate a pasted Linear API key via `CymphonyLinearViewer`.
  """
  @spec validate_api_key(String.t(), keyword()) ::
          {:ok, %{id: String.t()}} | {:error, :empty | :unauthorized | :invalid | term()}
  def validate_api_key(api_key, opts \\ []) when is_binary(api_key) and is_list(opts) do
    with {:ok, key} <- normalize_pasted_api_key(api_key) do
      case graphql(@viewer_query, %{}, graphql_opts_for_api_key(key, opts)) do
        {:ok, body} ->
          decode_viewer_validation(body)

        {:error, reason} ->
          map_linear_key_request_error(reason)
      end
    end
  end

  @doc """
  List Linear projects accessible to `api_key` (`slugId` -> `slug_id`).
  """
  @spec list_accessible_projects(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :empty | :unauthorized | term()}
  def list_accessible_projects(api_key, opts \\ []) when is_binary(api_key) and is_list(opts) do
    with {:ok, key} <- normalize_pasted_api_key(api_key) do
      fetch_accessible_projects(graphql_opts_for_api_key(key, opts), nil, [], 1)
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        do_fetch_issue_states(ids, nil, graphql_fun)
    end
  end

  defp do_fetch_by_states(project_slug, state_names, assignee_filter) do
    do_fetch_by_states_page(project_slug, state_names, assignee_filter, nil, [], nil)
  end

  defp do_fetch_by_states(project_slug, state_names, assignee_filter, config) do
    do_fetch_by_states_page(project_slug, state_names, assignee_filter, nil, [], config)
  end

  defp do_fetch_by_states_page(project_slug, state_names, assignee_filter, after_cursor, acc_issues, config) do
    graphql_opts = graphql_opts_for_config(config)

    with {:ok, body} <-
           graphql(
             @query,
             %{
               projectSlug: project_slug,
               stateNames: state_names,
               first: @issue_page_size,
               relationFirst: @issue_page_size,
               after: after_cursor
             },
             graphql_opts
           ),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(project_slug, state_names, assignee_filter, next_cursor, updated_acc, config)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, assignee_filter) do
    do_fetch_issue_states(ids, assignee_filter, &graphql/2)
  end

  defp do_fetch_issue_states(ids, assignee_filter, graphql_fun, project_slug \\ nil)
       when is_list(ids) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    fetch_states_page(ids, assignee_filter, graphql_fun, [], issue_order_index, project_slug)
  end

  defp fetch_states_page([], _assignee_filter, _graphql_fun, acc_issues, issue_order_index, _project_slug) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp fetch_states_page(ids, assignee_filter, graphql_fun, acc_issues, issue_order_index, project_slug) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)
    query = if is_binary(project_slug), do: @query_by_ids_project, else: @query_by_ids
    variables = %{ids: batch_ids, first: length(batch_ids), relationFirst: @issue_page_size}
    variables = if is_binary(project_slug), do: Map.put(variables, :projectSlug, project_slug), else: variables

    case graphql_fun.(query, variables) do
      {:ok, body} ->
        with {:ok, issues} <- decode_linear_response(body, assignee_filter) do
          updated_acc = prepend_page_issues(issues, acc_issues)
          fetch_states_page(rest_ids, assignee_filter, graphql_fun, updated_acc, issue_order_index, project_slug)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response, headers) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body(headers)

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body, headers) when is_binary(body) do
    body
    |> RateLimit.redact(headers)
    |> String.replace(Regex.compile!("\\s+"), " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body, headers) do
    body
    |> inspect(limit: 20, printable_limit: :infinity)
    |> RateLimit.redact(headers)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp graphql_headers(config) when is_struct(config, Config.Schema) do
    case config.tracker.api_key do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(Config.settings!().tracker.endpoint,
      retry: false,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp post_graphql_request(payload, headers, config) when is_struct(config, Config.Schema) do
    Req.post(config.tracker.endpoint,
      retry: false,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp post_graphql_request_to(endpoint, payload, headers) do
    Req.post(endpoint,
      retry: false,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  @doc false
  @spec graphql_opts_for_config(term()) :: keyword()
  def graphql_opts_for_config(nil), do: []

  def graphql_opts_for_config(config) when is_struct(config, Config.Schema) do
    app_opts = Application.get_env(:cymphony_elixir, :linear_graphql_opts, [])
    app_opts = if Keyword.keyword?(app_opts), do: app_opts, else: []

    [
      endpoint: config.tracker.endpoint,
      rate_limit_fallback_ms: min(10_000, config.agent.max_retry_backoff_ms),
      request_fun: fn payload, headers -> post_graphql_request(payload, headers, config) end,
      graphql_headers_fun: fn -> graphql_headers(config) end
    ]
    |> Keyword.merge(app_opts)
    |> Keyword.put(:endpoint, config.tracker.endpoint)
  end

  defp config_graphql_fun(config) do
    fn query, variables -> graphql(query, variables, graphql_opts_for_config(config)) end
  end

  defp normalize_pasted_api_key(api_key) when is_binary(api_key) do
    case String.trim(api_key) do
      "" -> {:error, :empty}
      key -> {:ok, key}
    end
  end

  defp resolve_linear_graphql_endpoint(opts) when is_list(opts) do
    cond do
      usable_linear_endpoint?(Keyword.get(opts, :endpoint)) ->
        String.trim(Keyword.get(opts, :endpoint))

      usable_linear_endpoint?(System.get_env("LINEAR_ENDPOINT")) ->
        String.trim(System.get_env("LINEAR_ENDPOINT"))

      true ->
        @default_linear_graphql_endpoint
    end
  end

  defp usable_linear_endpoint?(value) when is_binary(value), do: String.trim(value) != ""
  defp usable_linear_endpoint?(_value), do: false

  defp map_linear_key_request_error({:linear_api_status, status}) when status in [401, 403] do
    {:error, :unauthorized}
  end

  defp map_linear_key_request_error(reason), do: {:error, reason}

  # `graphql/3` only ever hands back a decoded JSON object, so there is no
  # non-map clause here: dialyzer proves it unreachable.
  defp decode_viewer_validation(body) do
    cond do
      linear_graphql_auth_error?(body) ->
        {:error, :unauthorized}

      viewer_id = viewer_id_from_body(body) ->
        {:ok, %{id: viewer_id}}

      true ->
        {:error, :invalid}
    end
  end

  defp viewer_id_from_body(%{"data" => %{"viewer" => %{"id" => id}}}) when is_binary(id) do
    case String.trim(id) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp viewer_id_from_body(_body), do: nil

  defp fetch_accessible_projects(_opts, _after_cursor, acc, page) when page > @max_project_pages do
    {:ok, Enum.reverse(acc)}
  end

  defp fetch_accessible_projects(opts, after_cursor, acc, page) do
    variables = %{first: @project_page_size, after: after_cursor}

    case graphql(@projects_query, variables, opts) do
      {:ok, body} ->
        collect_projects_page(body, opts, acc, page)

      {:error, reason} ->
        map_linear_key_request_error(reason)
    end
  end

  defp collect_projects_page(body, opts, acc, page) do
    with {:ok, projects, page_info} <- decode_projects_page(body) do
      advance_projects_page(page_info, opts, Enum.reverse(projects, acc), page)
    end
  end

  defp advance_projects_page(page_info, opts, acc, page) do
    case next_project_page_cursor(page_info) do
      {:ok, next_cursor} ->
        fetch_accessible_projects(opts, next_cursor, acc, page + 1)

      :done ->
        {:ok, Enum.reverse(acc)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Same as `decode_viewer_validation/1`: the body is always a decoded object.
  defp decode_projects_page(body) do
    cond do
      linear_graphql_auth_error?(body) ->
        {:error, :unauthorized}

      linear_graphql_errors?(body) ->
        {:error, {:linear_graphql_errors, body["errors"]}}

      match?(%{"data" => %{"projects" => %{"nodes" => nodes}}} when is_list(nodes), body) ->
        nodes = get_in(body, ["data", "projects", "nodes"])
        page_info = get_in(body, ["data", "projects", "pageInfo"])
        {:ok, Enum.flat_map(nodes, &normalize_linear_project/1), page_info}

      true ->
        {:error, :linear_unknown_payload}
    end
  end

  defp normalize_linear_project(%{"id" => id, "name" => name, "slugId" => slug_id})
       when is_binary(id) and is_binary(name) and is_binary(slug_id) do
    case String.trim(slug_id) do
      "" ->
        []

      trimmed_slug ->
        [%{id: id, name: name, slug_id: trimmed_slug}]
    end
  end

  defp normalize_linear_project(_node), do: []

  defp next_project_page_cursor(%{"hasNextPage" => true, "endCursor" => end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_project_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_project_page_cursor(%{"hasNextPage" => true}), do: {:error, :linear_missing_end_cursor}
  defp next_project_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_project_page_cursor(_page_info), do: :done

  defp linear_graphql_errors?(%{"errors" => errors}) when is_list(errors) and errors != [], do: true
  defp linear_graphql_errors?(_body), do: false

  defp linear_graphql_auth_error?(%{"errors" => errors}) when is_list(errors) and errors != [] do
    Enum.any?(errors, &linear_auth_error_entry?/1)
  end

  defp linear_graphql_auth_error?(_body), do: false

  defp linear_auth_error_entry?(error) when is_map(error) do
    linear_auth_error_code?(linear_error_extension_code(error)) or
      linear_auth_error_message?(error["message"])
  end

  defp linear_auth_error_entry?(_error), do: false

  defp linear_error_extension_code(%{"extensions" => %{"code" => code}}) when is_binary(code), do: code
  defp linear_error_extension_code(_error), do: nil

  defp linear_auth_error_code?(code) when is_binary(code) do
    case String.upcase(String.trim(code)) do
      "AUTHENTICATION_ERROR" -> true
      "UNAUTHENTICATED" -> true
      "UNAUTHORIZED" -> true
      "FORBIDDEN" -> true
      _ -> false
    end
  end

  defp linear_auth_error_code?(_code), do: false

  defp linear_auth_error_message?(message) when is_binary(message) do
    Regex.match?(
      Regex.compile!("(?i)(authentication|unauthenticated|unauthorized|forbidden)"),
      message
    )
  end

  defp linear_auth_error_message?(_message), do: false

  defp decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil(&1))

    {:ok, issues}
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter
       ) do
    with {:ok, issues} <- decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter), do: decode_linear_response(response, assignee_filter)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      state_type: get_in(issue, ["state", "type"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      blocked_by: extract_blockers(issue),
      labels: extract_labels(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp routing_assignee_filter(config) when is_struct(config, Config.Schema) do
    case config.tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee, config)
    end
  end

  defp build_assignee_filter(assignee, config \\ nil) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter(config)

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter(config) do
    case graphql(@viewer_query, %{}, graphql_opts_for_config(config)) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
