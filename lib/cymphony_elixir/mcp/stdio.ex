defmodule CymphonyElixir.Mcp.Stdio do
  @moduledoc """
  Minimal stdio entrypoint shared by the packaged CLI and development task.
  Starts the HTTP client dependencies, never Cymphony's runtime/dashboard.
  Stdout contains JSON-RPC responses only; diagnostics go to stderr.
  """

  alias CymphonyElixir.Mcp.LinearGraphqlServer

  @spec run() :: :ok
  def run do
    # app:nil escripts have not started Logger yet. Start it before replacing
    # handlers so Req's dependency startup cannot reinstall a stdout console.
    {:ok, _} = Application.ensure_all_started(:logger)
    # Escript and release boot can install different console handler IDs.
    # This is a dedicated MCP process: replace them all before logging.
    Enum.each(:logger.get_handler_ids(), &:logger.remove_handler/1)
    :logger.add_handler(:cymphony_mcp, :logger_std_h, %{config: %{type: :standard_error}})
    {:ok, _} = Application.ensure_all_started(:req)
    LinearGraphqlServer.log_started(%{workspace_path: File.cwd!()})
    loop(LinearGraphqlServer.env_from_system())
  end

  defp loop(env) do
    case IO.read(:stdio, :line) do
      data when is_binary(data) ->
        line = String.trim_trailing(data)
        if line != "", do: handle_line(line, env)
        loop(env)

      _eof_or_error ->
        :ok
    end
  end

  defp handle_line(line, env) do
    case LinearGraphqlServer.handle_message(line, env) do
      :no_reply -> :ok
      response when is_binary(response) -> IO.puts(response)
    end
  end
end
