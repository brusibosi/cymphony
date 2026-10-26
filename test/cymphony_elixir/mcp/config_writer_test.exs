defmodule CymphonyElixir.Mcp.ConfigWriterTest do
  use ExUnit.Case, async: true
  import Bitwise, only: [band: 2]

  alias CymphonyElixir.Mcp.ConfigWriter

  setup do
    dir = Path.join(System.tmp_dir!(), "cymphony-mcp-cw-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  test "writes a well-formed descriptor with api_key in env not args", %{workspace: ws} do
    assert {:ok, path} =
             ConfigWriter.write(ws, %{api_key: "lin-secret-123", endpoint: "https://lin.example/graphql"})

    assert path == Path.join(ws, ConfigWriter.descriptor_subpath())
    assert File.exists?(path)

    raw = File.read!(path)
    refute raw =~ "lin-secret-123\n", "api_key should not appear standalone in args"

    %{"mcpServers" => %{"cymphony-linear" => server}} = Jason.decode!(raw)
    assert Path.type(server["command"]) == :absolute
    refute "mix" in server["args"]
    refute "lin-secret-123" in server["args"]
    assert server["env"]["LINEAR_API_KEY"] == "lin-secret-123"
    assert server["env"]["LINEAR_ENDPOINT"] == "https://lin.example/graphql"
  end

  test "endpoint defaults to api.linear.app when omitted", %{workspace: ws} do
    {:ok, path} = ConfigWriter.write(ws, %{api_key: "k"})
    %{"mcpServers" => %{"cymphony-linear" => server}} = Jason.decode!(File.read!(path))
    assert server["env"]["LINEAR_ENDPOINT"] == "https://api.linear.app/graphql"
  end

  test "file permissions are 0600", %{workspace: ws} do
    {:ok, path} = ConfigWriter.write(ws, %{api_key: "k"})
    %File.Stat{mode: mode} = File.stat!(path)
    assert band(mode, 0o777) == 0o600
  end

  test "returns error when api_key missing or empty", %{workspace: ws} do
    assert {:error, :missing_api_key} = ConfigWriter.write(ws, %{api_key: ""})
    assert {:error, :missing_api_key} = ConfigWriter.write(ws, %{api_key: nil})
    assert {:error, :missing_api_key} = ConfigWriter.write(ws, %{})
  end

  test "descriptor_subpath/0 is stable" do
    assert ConfigWriter.descriptor_subpath() == ".cymphony/mcp_config.json"
  end
end
