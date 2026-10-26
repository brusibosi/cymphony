defmodule CymphonyElixir.Mcp.ConfigWriter do
  @moduledoc """
  Writes a per-session Claude Code MCP descriptor (`mcp_config.json`) that
  advertises Cymphony's `linear_graphql` tool via the `cymphony-linear` server.

  The descriptor is written into the per-issue workspace at
  `<workspace>/.cymphony/mcp_config.json` with mode `0600`. The Linear API key
  is placed in the spawned server's `env` map — never on the command line —
  so it does not leak to `ps`-style process listings.
  """

  @descriptor_subpath ".cymphony/mcp_config.json"
  @default_endpoint "https://api.linear.app/graphql"

  alias CymphonyElixir.Mcp.Command

  @type tracker_config :: %{
          required(:api_key) => String.t(),
          optional(:endpoint) => String.t() | nil
        }

  @doc """
  Write the MCP descriptor for `workspace` and return its absolute path.

  Returns `{:ok, path}` on success, `{:error, reason}` if the workspace is not
  usable or the api_key is empty.
  """
  @spec write(Path.t(), tracker_config()) :: {:ok, Path.t()} | {:error, term()}
  def write(workspace, %{api_key: api_key} = tracker)
      when is_binary(workspace) and is_binary(api_key) and api_key != "" do
    endpoint = Map.get(tracker, :endpoint) || @default_endpoint
    descriptor_path = Path.join(workspace, @descriptor_subpath)
    {command, args} = Command.build()

    descriptor = %{
      "mcpServers" => %{
        "cymphony-linear" => %{
          "command" => command,
          "args" => args,
          "env" => %{
            "LINEAR_API_KEY" => api_key,
            "LINEAR_ENDPOINT" => endpoint
          }
        }
      }
    }

    with :ok <- File.mkdir_p(Path.dirname(descriptor_path)),
         {:ok, json} <- Jason.encode(descriptor, pretty: true),
         :ok <- File.write(descriptor_path, json),
         :ok <- File.chmod(descriptor_path, 0o600) do
      {:ok, descriptor_path}
    end
  end

  def write(_workspace, _tracker), do: {:error, :missing_api_key}

  @doc """
  Return the relative subpath under a workspace where the descriptor lives.

  Exposed so callers (cleanup, tests) can reason about the file without
  duplicating the constant.
  """
  @spec descriptor_subpath() :: String.t()
  def descriptor_subpath, do: @descriptor_subpath

  @doc """
  Build the tracker MCP descriptor data from a parsed config, or `nil` when
  the tracker has no usable Linear credentials.
  """
  @spec descriptor_from_config(term()) :: tracker_config() | nil
  def descriptor_from_config(%{tracker: %{kind: "linear", api_key: key} = tracker})
      when is_binary(key) and key != "" do
    %{api_key: key, endpoint: Map.get(tracker, :endpoint)}
  end

  def descriptor_from_config(_config), do: nil
end
