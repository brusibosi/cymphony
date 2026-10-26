defmodule CymphonyElixir.Mcp.LinearGraphqlServer do
  @moduledoc """
  Pure request/response logic for the `linear_graphql` MCP tool.

  The stdio loop lives in `CymphonyElixir.Mcp.Stdio` and calls
  `handle_message/2` per frame; everything in this module is side-effect-free
  apart from the injected `graphql_fun`, which makes the handler trivially
  testable.

  Protocol: newline-delimited JSON-RPC 2.0 over stdio, per the Model Context
  Protocol spec. Three methods are recognised:

    - `initialize` → capabilities + server info
    - `tools/list` → the single `linear_graphql` tool descriptor
    - `tools/call` → execute a GraphQL query/mutation against Linear

  Any other method returns a `-32601` (method not found) error.
  """

  require Logger

  alias CymphonyElixir.Linear.Client

  @protocol_version "2024-11-05"
  @server_name "cymphony-linear"
  @server_version "1.0.0"
  @tool_name "linear_graphql"

  @tool_input_schema %{
    "type" => "object",
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "A single GraphQL query or mutation document."
      },
      "variables" => %{
        "type" => "object",
        "description" => "Optional variables object passed to the operation."
      }
    },
    "required" => ["query"],
    "additionalProperties" => false
  }

  @type env :: %{
          optional(:api_key) => String.t() | nil,
          optional(:endpoint) => String.t() | nil,
          optional(:graphql_fun) => (String.t(), map(), keyword() -> {:ok, map()} | {:error, term()})
        }

  @doc """
  Handle one JSON-RPC frame. Returns the response JSON string, or `:no_reply`
  for notifications (requests without an `id` field).
  """
  @spec handle_message(String.t(), env()) :: String.t() | :no_reply
  def handle_message(json_string, env) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"jsonrpc" => "2.0"} = msg} ->
        respond(msg, env)

      {:ok, _other} ->
        encode_error(nil, -32_600, "Invalid Request")

      {:error, _reason} ->
        encode_error(nil, -32_700, "Parse error")
    end
  end

  defp respond(%{"method" => method, "id" => id} = msg, env) do
    params = Map.get(msg, "params", %{})

    case dispatch(method, params, env) do
      {:ok, result} -> encode_result(id, result)
      {:error, code, message} -> encode_error(id, code, message)
    end
  end

  defp respond(_notification, _env), do: :no_reply

  @doc false
  @spec dispatch(String.t(), map(), env()) ::
          {:ok, map()} | {:error, integer(), String.t()}
  def dispatch("initialize", _params, _env) do
    {:ok,
     %{
       "protocolVersion" => @protocol_version,
       "capabilities" => %{"tools" => %{}},
       "serverInfo" => %{"name" => @server_name, "version" => @server_version}
     }}
  end

  def dispatch("tools/list", _params, _env) do
    {:ok,
     %{
       "tools" => [
         %{
           "name" => @tool_name,
           "description" => "Execute a Linear GraphQL query or mutation. Pass `query` (a single operation) and optional `variables`.",
           "inputSchema" => @tool_input_schema
         }
       ]
     }}
  end

  def dispatch("tools/call", %{"name" => @tool_name, "arguments" => args}, env)
      when is_map(args) do
    {:ok, tool_result(execute_tool(args, env))}
  end

  def dispatch("tools/call", %{"name" => other}, _env) when is_binary(other) do
    {:error, -32_602, "Unknown tool: #{other}"}
  end

  def dispatch(_method, _params, _env), do: {:error, -32_601, "Method not found"}

  defp tool_result(payload_map) when is_map(payload_map) do
    %{
      "content" => [
        %{
          "type" => "text",
          "text" => Jason.encode!(payload_map)
        }
      ],
      "isError" => Map.get(payload_map, "success") != true
    }
  end

  defp execute_tool(args, env) do
    started = System.monotonic_time(:microsecond)
    query = Map.get(args, "query")
    variables = Map.get(args, "variables") || %{}

    with :ok <- validate_query(query),
         :ok <- validate_single_operation(query),
         :ok <- validate_variables(variables) do
      result = call_linear(query, variables, env)
      log_call(query, result, started)
      result
    else
      {:error, message} ->
        log_call(query, %{"success" => false, "error" => message}, started)
        %{"success" => false, "error" => message}
    end
  end

  defp call_linear(query, variables, env) do
    graphql_fun = Map.get(env, :graphql_fun) || (&default_graphql/3)
    api_key = Map.get(env, :api_key)
    endpoint = Map.get(env, :endpoint)
    opts = build_graphql_opts(api_key, endpoint)

    case graphql_fun.(query, variables, opts) do
      {:ok, %{"errors" => errors} = body} when is_list(errors) and errors != [] ->
        %{"success" => false, "errors" => errors, "data" => Map.get(body, "data")}

      {:ok, body} ->
        %{"success" => true, "data" => Map.get(body, "data")}

      {:error, reason} ->
        %{"success" => false, "error" => format_error(reason)}
    end
  end

  defp default_graphql(query, variables, opts) do
    Client.graphql(query, variables, opts)
  end

  defp build_graphql_opts(api_key, endpoint) when is_binary(api_key) and api_key != "" do
    Client.graphql_opts_for_api_key(api_key, endpoint: endpoint)
  end

  defp build_graphql_opts(_api_key, _endpoint), do: []

  defp validate_query(query) when is_binary(query) do
    if String.trim(query) == "", do: {:error, "query must be a non-empty string"}, else: :ok
  end

  defp validate_query(_query), do: {:error, "query must be a string"}

  # Crude single-operation check: at most one top-level `query`, `mutation`,
  # or `subscription` keyword outside of comments. Good enough to reject the
  # obvious multi-op case without parsing GraphQL.
  defp validate_single_operation(query) when is_binary(query) do
    stripped = strip_graphql_comments(query)

    count =
      Regex.scan(Regex.compile!(~S"(?m)(?:^|\s)(query|mutation|subscription)\b"), stripped)
      |> length()

    if count <= 1 do
      :ok
    else
      {:error, "query must contain exactly one GraphQL operation"}
    end
  end

  defp validate_variables(value) when is_map(value), do: :ok
  defp validate_variables(_), do: {:error, "variables must be an object when provided"}

  defp strip_graphql_comments(query) do
    Regex.replace(Regex.compile!(~S"(?m)#.*$"), query, "")
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp encode_result(id, result) do
    Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp encode_error(id, code, message) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp log_call(_query, result, started) do
    duration_ms = div(System.monotonic_time(:microsecond) - started, 1_000)
    success = Map.get(result, "success") == true

    Logger.info("event=\"mcp.linear_graphql.call\" success=#{success} duration_ms=#{duration_ms}")
  end

  @doc """
  Build the env map a stdio runner should pass to `handle_message/2` from the
  OS environment. Useful for the Mix.Task entrypoint and integration tests.
  """
  @spec env_from_system() :: env()
  def env_from_system do
    %{
      api_key: System.get_env("LINEAR_API_KEY"),
      endpoint: System.get_env("LINEAR_ENDPOINT")
    }
  end

  @doc """
  Emit the structured `mcp.linear_graphql.started` event. Called from the
  Mix.Task entrypoint immediately before the stdio loop begins.
  """
  @spec log_started(map()) :: :ok
  def log_started(meta) when is_map(meta) do
    Logger.info("event=\"mcp.linear_graphql.started\" workspace_path=#{inspect(Map.get(meta, :workspace_path))} pid=#{System.pid()}")

    :ok
  end
end
