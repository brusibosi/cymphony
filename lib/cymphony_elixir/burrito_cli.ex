defmodule CymphonyElixir.BurritoCLI do
  @moduledoc """
  OTP Application entrypoint for the Burrito-wrapped standalone binary.
  Starts the full Cymphony supervision tree, then hands off to CLI.main/1.
  """

  use Application

  alias Burrito.Util.Args
  alias CymphonyElixir.Application, as: CymphonyApplication
  alias CymphonyElixir.CLI

  require Logger

  @impl true
  def start(_type, _args) do
    args = Args.argv()

    children =
      if args == ["mcp", "linear-graphql"] do
        []
      else
        :ok = CymphonyElixir.LogFile.configure()
        CymphonyApplication.children()
      end

    with {:ok, sup_pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: CymphonyElixir.Supervisor) do
      Task.start(__MODULE__, :run_cli, [args])

      {:ok, sup_pid}
    end
  end

  @doc false
  @spec run_cli([String.t()]) :: no_return()
  def run_cli(args) do
    CLI.main(args)
  catch
    kind, reason ->
      Logger.error("Unhandled CLI error: #{inspect({kind, reason})}")
      # `CLI.halt/1`, never `System.halt/1`: this is the only record of a crash
      # in the shipped binary, `LogFile.configure/0` has already removed the
      # console handler, and the disk handlers buffer — halting directly drops
      # the line this just logged and leaves the operator with exit 1 and empty
      # logs.
      CLI.halt(1)
  end

  @impl true
  def stop(_state) do
    CymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end
end
