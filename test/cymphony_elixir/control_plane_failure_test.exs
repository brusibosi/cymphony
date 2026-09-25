defmodule CymphonyElixir.ControlPlaneFailureTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias CymphonyElixir.ProjectSupervisor

  @endpoint CymphonyElixirWeb.Endpoint

  defmodule FakeOrch do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :recipient)}

    @impl true
    def handle_call(message, _from, recipient) do
      send(recipient, {:orchestrator_call, message})
      {:reply, :ok, recipient}
    end
  end

  setup do
    previous = Application.get_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, [])
    tmp = Path.join(System.tmp_dir!(), "cymphony-control-plane-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    path = Path.join(tmp, "config.json")
    File.write!(path, Jason.encode!(%{"projects" => [%{"name" => "Farm"}]}))
    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)
    Application.put_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, Keyword.merge(previous, server: false, secret_key_base: String.duplicate("s", 64)))
    start_supervised!({CymphonyElixirWeb.Endpoint, []})

    start_supervised!(%{
      id: FakeOrch,
      start: {FakeOrch, :start_link, [[name: ProjectSupervisor.via_tuple("Farm", :orchestrator), recipient: self()]]}
    })

    on_exit(fn ->
      Application.delete_env(:cymphony_elixir, :config_dir_override)
      Application.put_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, previous)
      File.rm_rf!(tmp)
    end)

    {:ok, path: path}
  end

  for {route, body, call, code} <- [
        {"concurrency", %{"value" => 4}, {:set_concurrency, 4}, "concurrency_not_persisted"},
        {"providers", %{"value" => "cv1,cz2"}, {:set_providers, ["cv1", "cz2"]}, "providers_not_persisted"},
        {"agent", %{"kind" => "codex"}, {:set_agent_settings, %{"agent" => "codex"}}, "agent_settings_not_persisted"}
      ] do
    test "POST /api/v1/#{route} reports applied but unpersisted update", %{path: path} do
      File.rm!(path)
      conn = post(build_conn(), "/api/v1/#{unquote(route)}?project=Farm", unquote(Macro.escape(body)))
      assert json_response(conn, 422)["error"]["code"] == unquote(code)
      assert_receive {:orchestrator_call, unquote(Macro.escape(call))}
    end

    test "POST /api/v1/#{route} rejects an unknown registered project" do
      conn = post(build_conn(), "/api/v1/#{unquote(route)}?project=Missing", unquote(Macro.escape(body)))
      assert json_response(conn, 422)["error"]["code"] == "project_not_found"
      refute_receive {:orchestrator_call, _}, 50
    end
  end

  test "POST /api/v1/providers rejects malformed lists without crashing or dispatching" do
    for value <- [["cv1", %{"bad" => "x"}], ["cv1; echo bad"], ["cv1,cz2"], "cv1; echo bad"] do
      conn = post(build_conn(), "/api/v1/providers?project=Farm", %{"value" => value})
      assert json_response(conn, 422)["error"]["code"] == "invalid_providers"
    end

    refute_receive {:orchestrator_call, _}, 50
  end

  test "control routes reject a non-string project scope without applying fleet-wide updates" do
    for {route, body} <- [
          {"concurrency", %{"value" => 4}},
          {"providers", %{"value" => "cv1"}},
          {"agent", %{"kind" => "codex"}}
        ] do
      conn = post(build_conn(), "/api/v1/#{route}", Map.put(body, "project", %{"bad" => "scope"}))
      assert json_response(conn, 422)["error"]["code"] == "invalid_scope"
    end

    refute_receive {:orchestrator_call, _}, 50
  end
end
