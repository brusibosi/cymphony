defmodule CymphonyElixir.Mcp.Command do
  @moduledoc """
  Builds the shared local MCP command without depending on the agent's cwd.

  Packaged builds re-execute their own wrapper/archive. Development launches
  start Elixir directly with the running node's absolute compiled code paths;
  neither Mix nor a source checkout is needed in the worker directory.
  """

  alias CymphonyElixir.Daemon

  @spec build(Daemon.lookups()) :: {String.t(), [String.t()]}
  def build(lookups \\ %{}) do
    runtime =
      Map.merge(
        %{
          escript_name: &:escript.script_name/0,
          module_path: fn -> :code.which(__MODULE__) end
        },
        lookups
      )

    # Only the running package is valid here. A different `cymphony` on PATH
    # may be an older install; Mix/erl's progname is not the Cymphony CLI.
    package_lookups =
      runtime
      |> Map.merge(%{
        escript_name: fn -> running_escript(runtime.escript_name.(), runtime.module_path.()) end,
        progname: fn -> :error end,
        find_executable: fn _ -> nil end
      })

    case Daemon.executable_path(package_lookups) do
      {:ok, executable} -> {executable, ["mcp", "linear-graphql"]}
      {:error, _} -> development_command()
    end
  end

  defp running_escript(script, beam) when is_list(script) and script != [] and is_list(beam) do
    script = List.to_string(script)
    beam = List.to_string(beam)

    # Elixir scripts (including Mix) also report script_name. An escript
    # archive actually owns the running module's code path.
    if String.starts_with?(beam, script <> "/"), do: String.to_charlist(script), else: []
  end

  # Cover-instrumented, unloaded and preloaded modules have atom locations,
  # rather than a BEAM filename. They cannot prove archive ownership.
  defp running_escript(_script, _beam), do: []

  defp development_command do
    executable = System.find_executable("elixir") || raise "Elixir executable is required for the development MCP server"

    code_paths =
      :code.get_path()
      |> Enum.map(&(&1 |> List.to_string() |> Path.expand()))
      |> Enum.filter(&File.dir?/1)

    args = Enum.flat_map(code_paths, &["-pa", &1])
    {executable, args ++ ["-e", "CymphonyElixir.Mcp.Stdio.run()"]}
  end
end
