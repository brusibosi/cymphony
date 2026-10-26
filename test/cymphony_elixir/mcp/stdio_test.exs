defmodule CymphonyElixir.Mcp.StdioTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Agent.Codex
  alias CymphonyElixir.Mcp.ConfigWriter

  for agent <- [:claude, :codex] do
    @tag timeout: 20_000
    test "generated #{agent} command serves MCP and GraphQL without Mix or dependencies and exits on EOF" do
      agent = unquote(agent)
      workspace = Path.join(System.tmp_dir!(), "cymphony-mcp-stdio-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf!(workspace) end)
      refute File.exists?(Path.join(workspace, "mix.exs"))

      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_tcp.close(listener) end)
      {:ok, {_, port_number}} = :inet.sockname(listener)
      endpoint = "http://127.0.0.1:#{port_number}/graphql"
      parent = self()

      fixture = Task.async(fn -> serve_graphql(listener, parent) end)

      assert {:ok, path} = ConfigWriter.write(workspace, %{api_key: "fixture-only-key", endpoint: endpoint})
      %{"mcpServers" => %{"cymphony-linear" => server}} = Jason.decode!(File.read!(path))
      server = server_command(agent, workspace, endpoint, server)

      frames = [
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}},
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"},
        %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{
            "name" => "linear_graphql",
            "arguments" => %{"query" => "query Fixture($id: String!) { issue(id: $id) { identifier } }", "variables" => %{"id" => "ALE-1405"}}
          }
        }
      ]

      input_path = Path.join(workspace, "frames.jsonl")
      File.write!(input_path, Enum.map_join(frames, "\n", &Jason.encode!/1) <> "\ninvalid-json\n")

      port =
        Port.open({:spawn_executable, System.find_executable("sh")}, [
          :binary,
          :exit_status,
          args: ["-c", "exec \"$@\" < \"$CYMPHONY_MCP_TEST_INPUT\"", "mcp-test", server["command"] | server["args"]],
          cd: workspace,
          env: Enum.map(Map.put(server["env"], "CYMPHONY_MCP_TEST_INPUT", input_path), fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
        ])

      on_exit(fn -> if Port.info(port), do: Port.close(port) end)
      [initialized, tools, called, malformed] = receive_frames(port, "", [])
      assert initialized["result"]["serverInfo"]["name"] == "cymphony-linear"
      assert [%{"name" => "linear_graphql"}] = tools["result"]["tools"]
      assert called["result"]["isError"] == false
      assert [%{"text" => body}] = called["result"]["content"]
      assert Jason.decode!(body) == %{"success" => true, "data" => %{"issue" => %{"identifier" => "ALE-1405"}}}
      assert_receive {:graphql_request, headers, request}
      assert {"Authorization", "fixture-only-key"} in headers
      assert request["variables"] == %{"id" => "ALE-1405"}
      assert malformed["error"]["code"] == -32_700
      Task.await(fixture)
    end
  end

  defp server_command(:claude, _workspace, _endpoint, server), do: server
  defp server_command(:codex, workspace, endpoint, server), do: codex_server(workspace, endpoint, server["env"])

  defp codex_server(workspace, endpoint, env) do
    # A tiny real CLI records argv after the shell has processed Codex's -c
    # overrides. Launch exactly that parsed server command below.
    capture = Path.join(workspace, "capture-codex")
    File.write!(capture, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
    File.chmod!(capture, 0o700)

    {:ok, command} =
      Codex.build_command(%{
        command: CymphonyElixir.Shell.escape(capture),
        session_id: nil,
        model: nil,
        effort: nil,
        prompt: "fixture prompt",
        mcp_descriptor: %{api_key: "fixture-only-key", endpoint: endpoint},
        settings: %{command: nil, sandbox: "read-only"}
      })

    refute command =~ "fixture-only-key"
    {output, 0} = System.cmd("sh", ["-c", command])

    overrides =
      output
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "mcp_servers.cymphony-linear."))
      |> Map.new(fn line ->
        [key, value] = String.split(line, "=", parts: 2)
        {key, value}
      end)

    assert overrides["mcp_servers.cymphony-linear.env_vars"] == ~s(["LINEAR_API_KEY"])
    assert overrides["mcp_servers.cymphony-linear.env"] == "{LINEAR_ENDPOINT = #{Jason.encode!(endpoint)}}"
    %{"command" => Jason.decode!(overrides["mcp_servers.cymphony-linear.command"]), "args" => Jason.decode!(overrides["mcp_servers.cymphony-linear.args"]), "env" => env}
  end

  defp receive_frames(port, buffer, frames) do
    receive do
      {^port, {:data, bytes}} ->
        lines = String.split(buffer <> bytes, "\n")
        {complete, [rest]} = Enum.split(lines, -1)
        decoded = Enum.map(complete, &Jason.decode!/1)
        receive_frames(port, rest, frames ++ decoded)

      {^port, {:exit_status, status}} ->
        assert status == 0, "MCP server exited #{status}: #{buffer}"
        assert buffer == ""
        frames
    after
      10_000 -> flunk("MCP server did not serve all requests: #{inspect(frames)} #{buffer}")
    end
  end

  defp serve_graphql(listener, parent) do
    {:ok, socket} = :gen_tcp.accept(listener, 15_000)
    {:ok, {:http_request, :POST, {:abs_path, "/graphql"}, _}} = :gen_tcp.recv(socket, 0, 5_000)
    headers = read_headers(socket, [])
    {_, length} = Enum.find(headers, fn {key, _} -> key == "Content-Length" end)
    :ok = :inet.setopts(socket, packet: :raw)
    {:ok, body} = :gen_tcp.recv(socket, String.to_integer(length), 5_000)
    send(parent, {:graphql_request, headers, Jason.decode!(body)})
    response = Jason.encode!(%{"data" => %{"issue" => %{"identifier" => "ALE-1405"}}})
    :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(response)}\r\nConnection: close\r\n\r\n" <> response)
    :gen_tcp.close(socket)
  end

  defp read_headers(socket, headers) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, {:http_header, _, key, _, value}} -> read_headers(socket, [{to_string(key), value} | headers])
      {:ok, :http_eoh} -> headers
    end
  end
end
