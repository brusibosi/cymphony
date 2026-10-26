defmodule Mix.Tasks.Cymphony.Mcp.LinearGraphql do
  @moduledoc """
  Run the Cymphony `linear_graphql` MCP server over stdio.

  Invoked by Claude Code via the MCP descriptor written by
  `CymphonyElixir.Mcp.ConfigWriter`. Reads newline-delimited JSON-RPC 2.0
  frames from stdin, dispatches them through
  `CymphonyElixir.Mcp.LinearGraphqlServer.handle_message/2`, and writes
  responses to stdout.

  Not a developer-facing task. Reaches Linear via `LINEAR_API_KEY` and
  `LINEAR_ENDPOINT` in the environment.
  """

  use Mix.Task

  alias CymphonyElixir.Mcp.Stdio

  @shortdoc false

  @impl Mix.Task
  def run(_args) do
    Stdio.run()
  end
end
