defmodule CymphonyElixir.Mcp.CommandTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Mcp.Command

  setup do
    executable = Path.join(System.tmp_dir!(), "cymphony-mcp-binary-#{System.unique_integer([:positive])}")
    File.write!(executable, "#!/bin/sh\n")
    File.chmod!(executable, 0o700)
    on_exit(fn -> File.rm!(executable) end)
    {:ok, executable: executable}
  end

  test "Burrito command reuses its own installed wrapper", %{executable: path} do
    assert {^path, ["mcp", "linear-graphql"]} =
             Command.build(%{
               burrito_bin_path: fn -> path end,
               escript_name: fn -> [] end
             })
  end

  test "escript command reuses its own archive", %{executable: path} do
    assert {^path, ["mcp", "linear-graphql"]} =
             Command.build(%{
               burrito_bin_path: fn -> nil end,
               escript_name: fn -> String.to_charlist(path) end,
               module_path: fn -> String.to_charlist(path <> "/cymphony_elixir/ebin/Elixir.CymphonyElixir.Mcp.Command.beam") end
             })
  end

  for location <- [:cover_compiled, :non_existing, :preloaded, nil] do
    test "a #{inspect(location)} module location safely selects compiled development startup", %{executable: path} do
      location = unquote(location)

      assert {executable, args} =
               Command.build(%{
                 burrito_bin_path: fn -> nil end,
                 escript_name: fn -> String.to_charlist(path) end,
                 module_path: fn -> location end
               })

      assert executable == System.find_executable("elixir")
      assert Enum.take(args, -2) == ["-e", "CymphonyElixir.Mcp.Stdio.run()"]
      refute "mix" in args
    end
  end

  test "a Mix script does not own a separate compiled module", %{executable: path} do
    assert {executable, args} =
             Command.build(%{
               burrito_bin_path: fn -> nil end,
               escript_name: fn -> String.to_charlist(path) end,
               module_path: fn -> ~c"/tmp/another-build/ebin/Elixir.CymphonyElixir.Mcp.Command.beam" end
             })

    assert executable == System.find_executable("elixir")
    assert Enum.take(args, -2) == ["-e", "CymphonyElixir.Mcp.Stdio.run()"]
  end

  test "the current Mix runtime resolves development startup while coverage instruments the module" do
    assert {executable, args} = Command.build(%{burrito_bin_path: fn -> nil end})
    assert executable == System.find_executable("elixir")
    assert Enum.take(args, -2) == ["-e", "CymphonyElixir.Mcp.Stdio.run()"]
  end
end
