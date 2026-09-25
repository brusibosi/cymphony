defmodule CymphonyElixir.LinearApiTest do
  # async: false — mutates :config_dir_override, LINEAR_API_KEY, and the Endpoint.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.Cymphony.WorkflowGenerator
  alias CymphonyElixir.ProjectSupervisor
  alias CymphonyElixir.WorkflowStore

  @endpoint CymphonyElixirWeb.Endpoint
  @fake_key "lin_api_fake"
  @test_key "lin_test"

  setup do
    previous_key = System.get_env("LINEAR_API_KEY")
    previous_opts = Application.get_env(:cymphony_elixir, :linear_graphql_opts)
    previous_start_args = Application.get_env(:cymphony_elixir, :start_project_args)
    previous_workflow_temp_dir = Application.get_env(:cymphony_elixir, :workflow_temp_dir)
    endpoint_config = Application.get_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, [])

    tmp = Path.join(System.tmp_dir!(), "cymphony-linear-api-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)
    System.delete_env("LINEAR_API_KEY")
    Application.delete_env(:cymphony_elixir, :linear_graphql_opts)
    Application.delete_env(:cymphony_elixir, :start_project_args)
    Application.delete_env(:cymphony_elixir, :workflow_temp_dir)

    Application.put_env(
      :cymphony_elixir,
      CymphonyElixirWeb.Endpoint,
      endpoint_config
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
    )

    start_supervised!({CymphonyElixirWeb.Endpoint, []})

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_key)
      restore_app_env(:linear_graphql_opts, previous_opts)
      restore_app_env(:start_project_args, previous_start_args)
      restore_app_env(:workflow_temp_dir, previous_workflow_temp_dir)
      Application.delete_env(:cymphony_elixir, :config_dir_override)
      Application.put_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, endpoint_config)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, path: Path.join(tmp, "config.json")}
  end

  test "GET /api/v1/linear is 200 disconnected when no key is configured" do
    conn = get(build_conn(), "/api/v1/linear")

    assert json_response(conn, 200) == %{
             "connected" => false,
             "masked_key" => nil,
             "source" => nil
           }

    refute_raw_key(conn)
  end

  test "GET /api/v1/linear reports env source without echoing the raw key" do
    System.put_env("LINEAR_API_KEY", @fake_key)
    conn = get(build_conn(), "/api/v1/linear")

    assert json_response(conn, 200) == %{
             "connected" => true,
             "masked_key" => "••••fake",
             "source" => "env"
           }

    refute_raw_key(conn)
  end

  test "GET /api/v1/linear reports config source and last-4 mask", %{path: path} do
    File.write!(path, Jason.encode!(%{"linear_api_key" => @fake_key, "projects" => []}))
    conn = get(build_conn(), "/api/v1/linear")

    assert json_response(conn, 200) == %{
             "connected" => true,
             "masked_key" => "••••fake",
             "source" => "config"
           }

    refute_raw_key(conn)
  end

  test "POST /api/v1/linear returns 202 and never echoes the key" do
    stub_linear_viewer()

    conn = post(build_conn(), "/api/v1/linear", %{"api_key" => @fake_key})

    assert json_response(conn, 202) == %{
             "connected" => true,
             "masked_key" => "••••fake",
             "source" => "config"
           }

    refute_raw_key(conn)
    {:ok, cfg} = CymphonyConfig.load()
    assert cfg["linear_api_key"] == @fake_key
  end

  test "POST /api/v1/linear reports workflow rewrite failure without exposing the key", %{tmp: tmp, path: path} do
    project = %{"name" => "Farm", "linear_project_slug" => "farm-slug", "linear_api_key" => @test_key}
    File.write!(path, Jason.encode!(%{"projects" => [project]}))
    workflow_dir = Path.join(tmp, "workflow")
    File.mkdir_p!(workflow_dir)
    workflow_path = Path.join(workflow_dir, "WORKFLOW.md")
    File.write!(workflow_path, WorkflowGenerator.generate(project))

    start_supervised!(%{
      id: {:failed_linear_rewrite_store, "Farm"},
      start: {WorkflowStore, :start_link, [[name: ProjectSupervisor.via_tuple("Farm", :workflow_store), workflow_path: workflow_path]]}
    })

    owner = self()

    orch =
      spawn(fn ->
        {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {"Farm", :orchestrator}, nil)
        send(owner, :orch_registered)
        Process.sleep(:infinity)
      end)

    assert_receive :orch_registered
    on_exit(fn -> Process.exit(orch, :kill) end)
    File.rm_rf!(workflow_dir)
    stub_linear_viewer()

    conn = post(build_conn(), "/api/v1/linear", %{"api_key" => @fake_key})
    assert json_response(conn, 422)["error"]["code"] == "linear_workflow_rewrite_failed"
    refute_raw_key(conn)
  end

  test "POST /api/v1/linear returns 422 empty_api_key for a blank key" do
    conn = post(build_conn(), "/api/v1/linear", %{"api_key" => "  "})

    assert json_response(conn, 422) == %{
             "error" => %{"code" => "empty_api_key", "message" => "API key cannot be empty"}
           }

    refute_raw_key(conn)
  end

  test "POST /api/v1/linear returns 422 empty_api_key when api_key is omitted" do
    conn = post(build_conn(), "/api/v1/linear", %{})

    assert json_response(conn, 422)["error"]["code"] == "empty_api_key"
    refute_raw_key(conn)
  end

  test "POST /api/v1/linear returns 422 linear_unauthorized for HTTP 401" do
    stub_linear_request(fn _payload, _headers ->
      {:ok, %{status: 401, body: %{"errors" => [%{"message" => "Unauthorized"}]}}}
    end)

    {conn, _log} =
      with_log(fn ->
        post(build_conn(), "/api/v1/linear", %{"api_key" => @fake_key})
      end)

    assert json_response(conn, 422) == %{
             "error" => %{
               "code" => "linear_unauthorized",
               "message" => "Linear rejected that API key"
             }
           }

    refute_raw_key(conn)
  end

  test "POST /api/v1/linear returns 422 invalid_api_key when viewer.id is missing" do
    stub_linear_request(fn _payload, _headers ->
      {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{}}}}}
    end)

    conn = post(build_conn(), "/api/v1/linear", %{"api_key" => @fake_key})

    assert json_response(conn, 422) == %{
             "error" => %{
               "code" => "invalid_api_key",
               "message" => "Linear rejected that API key"
             }
           }

    refute_raw_key(conn)
  end

  test "POST /api/v1/linear returns 422 linear_error on transport failure" do
    stub_linear_request(fn _payload, _headers -> {:error, :nxdomain} end)

    {conn, _log} =
      with_log(fn ->
        post(build_conn(), "/api/v1/linear", %{"api_key" => @fake_key})
      end)

    assert json_response(conn, 422) == %{
             "error" => %{"code" => "linear_error", "message" => "Could not reach Linear"}
           }

    refute_raw_key(conn)
  end

  test "GET /api/v1/linear/projects is 422 linear_not_connected without a key" do
    conn = get(build_conn(), "/api/v1/linear/projects")

    assert json_response(conn, 422) == %{
             "error" => %{
               "code" => "linear_not_connected",
               "message" => "Connect Linear to list projects"
             }
           }
  end

  test "GET /api/v1/linear/projects is 422 linear_unauthorized when Linear rejects the key", %{
    path: path
  } do
    File.write!(path, Jason.encode!(%{"linear_api_key" => @fake_key, "projects" => []}))

    stub_linear_request(fn _payload, _headers ->
      {:ok, %{status: 401, body: "nope"}}
    end)

    {conn, _log} = with_log(fn -> get(build_conn(), "/api/v1/linear/projects") end)

    assert json_response(conn, 422)["error"]["code"] == "linear_unauthorized"
    refute_raw_key(conn)
  end

  test "GET /api/v1/linear/projects is 422 linear_error on transport failure", %{path: path} do
    File.write!(path, Jason.encode!(%{"linear_api_key" => @fake_key, "projects" => []}))
    stub_linear_request(fn _payload, _headers -> {:error, :nxdomain} end)

    {conn, _log} = with_log(fn -> get(build_conn(), "/api/v1/linear/projects") end)

    assert json_response(conn, 422)["error"]["code"] == "linear_error"
    refute_raw_key(conn)
  end

  test "GET /api/v1/linear/projects is 200 with id/name/slug_id", %{path: path} do
    File.write!(path, Jason.encode!(%{"linear_api_key" => @fake_key, "projects" => []}))

    stub_linear_request(fn payload, headers ->
      assert payload["query"] =~ "CymphonyLinearProjects"
      assert {"Authorization", @fake_key} in headers

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "projects" => %{
               "nodes" => [
                 %{"id" => "p1", "name" => "AI Logic", "slugId" => "ailogic-ced4159f70c4"}
               ],
               "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
             }
           }
         }
       }}
    end)

    conn = get(build_conn(), "/api/v1/linear/projects")

    assert json_response(conn, 200) == %{
             "projects" => [
               %{"id" => "p1", "name" => "AI Logic", "slug_id" => "ailogic-ced4159f70c4"}
             ]
           }

    refute_raw_key(conn)
  end

  test "GET /api/v1/projects still returns running counts" do
    conn = get(build_conn(), "/api/v1/projects")
    assert %{"projects" => projects} = json_response(conn, 200)
    assert is_list(projects)
  end

  test "POST /api/v1/projects is 422 not_connected without a key" do
    conn =
      post(build_conn(), "/api/v1/projects", %{
        "name" => "Farm",
        "linear_project_slug" => "farm-abc"
      })

    assert json_response(conn, 422) == %{
             "error" => %{"code" => "not_connected", "message" => "Connect Linear to add a project"}
           }
  end

  test "POST /api/v1/projects is 422 invalid_project when name or slug is missing", %{path: path} do
    File.write!(path, Jason.encode!(%{"linear_api_key" => @test_key, "projects" => []}))

    conn = post(build_conn(), "/api/v1/projects", %{"name" => "Farm"})

    assert json_response(conn, 422) == %{
             "error" => %{
               "code" => "invalid_project",
               "message" => "Project name and Linear slug are required"
             }
           }
  end

  test "POST /api/v1/projects is 202 and starts the project without echoing the key", %{
    tmp: tmp,
    path: path
  } do
    File.write!(path, Jason.encode!(%{"linear_api_key" => @fake_key, "projects" => []}))
    name = "api-#{System.unique_integer([:positive])}"
    slug = "api-slug-#{System.unique_integer([:positive])}"
    memory_path = write_memory_workflow!(tmp)
    Application.put_env(:cymphony_elixir, :start_project_args, {name, memory_path})

    on_exit(fn -> _ = ProjectSupervisor.stop_project(name) end)

    conn =
      post(build_conn(), "/api/v1/projects", %{
        "name" => name,
        "linear_project_slug" => slug,
        "workspace_root" => Path.join(tmp, "ws")
      })

    assert json_response(conn, 202) == %{
             "name" => name,
             "linear_project_slug" => slug,
             "started" => true
           }

    refute_raw_key(conn)
    assert is_pid(ProjectSupervisor.lookup(name, :supervisor))
  end

  test "POST /api/v1/projects is 422 duplicate_project_name", %{tmp: tmp, path: path} do
    File.write!(path, Jason.encode!(%{"linear_api_key" => @test_key, "projects" => []}))
    name = "dup-#{System.unique_integer([:positive])}"
    memory_path = write_memory_workflow!(tmp)
    Application.put_env(:cymphony_elixir, :start_project_args, {name, memory_path})

    on_exit(fn -> _ = ProjectSupervisor.stop_project(name) end)

    assert %{status: 202} =
             post(build_conn(), "/api/v1/projects", %{
               "name" => name,
               "linear_project_slug" => "slug-a-#{System.unique_integer([:positive])}"
             })

    conn =
      post(build_conn(), "/api/v1/projects", %{
        "name" => name,
        "linear_project_slug" => "slug-b-#{System.unique_integer([:positive])}"
      })

    assert json_response(conn, 422) == %{
             "error" => %{
               "code" => "duplicate_project_name",
               "message" => "A project with that name already exists"
             }
           }
  end

  test "POST /api/v1/projects is 422 duplicate_project_slug", %{tmp: tmp, path: path} do
    File.write!(path, Jason.encode!(%{"linear_api_key" => @test_key, "projects" => []}))
    name = "slugproj-#{System.unique_integer([:positive])}"
    slug = "shared-slug-#{System.unique_integer([:positive])}"
    memory_path = write_memory_workflow!(tmp)
    Application.put_env(:cymphony_elixir, :start_project_args, {name, memory_path})

    on_exit(fn -> _ = ProjectSupervisor.stop_project(name) end)

    assert %{status: 202} =
             post(build_conn(), "/api/v1/projects", %{
               "name" => name,
               "linear_project_slug" => slug
             })

    conn =
      post(build_conn(), "/api/v1/projects", %{
        "name" => "other-#{System.unique_integer([:positive])}",
        "linear_project_slug" => slug
      })

    assert json_response(conn, 422) == %{
             "error" => %{
               "code" => "duplicate_project_slug",
               "message" => "A project with that Linear slug already exists"
             }
           }
  end

  test "POST /api/v1/projects is 422 project_start_failed when start fails", %{path: path} do
    File.write!(path, Jason.encode!(%{"linear_api_key" => @test_key, "projects" => []}))

    Application.put_env(
      :cymphony_elixir,
      :start_project_args,
      {"boom-#{System.unique_integer([:positive])}", "/missing-cymphony-workflow.md"}
    )

    conn =
      post(build_conn(), "/api/v1/projects", %{
        "name" => "Boom",
        "linear_project_slug" => "boom-#{System.unique_integer([:positive])}"
      })

    assert json_response(conn, 422) == %{
             "error" => %{
               "code" => "project_start_failed",
               "message" => "Project was saved but failed to start"
             }
           }
  end

  test "POST /api/v1/projects reports generated workflow failure instead of crashing", %{tmp: tmp, path: path} do
    File.write!(path, Jason.encode!(%{"linear_api_key" => @test_key, "projects" => []}))
    Application.put_env(:cymphony_elixir, :workflow_temp_dir, Path.join(tmp, "missing"))

    conn = post(build_conn(), "/api/v1/projects", %{"name" => "Farm", "linear_project_slug" => "farm-slug"})
    assert json_response(conn, 422)["error"]["code"] == "project_workflow_failed"
    refute_raw_key(conn)
  end

  test "unsupported methods on the new routes return 405" do
    assert json_response(put(build_conn(), "/api/v1/linear", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/linear/projects", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(put(build_conn(), "/api/v1/projects", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}
  end

  defp stub_linear_viewer do
    stub_linear_request(fn _payload, _headers ->
      {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "user-1"}}}}}
    end)
  end

  defp stub_linear_request(fun) when is_function(fun, 2) do
    Application.put_env(:cymphony_elixir, :linear_graphql_opts, request_fun: fun)
  end

  defp write_memory_workflow!(dir) do
    path = Path.join(dir, "memory_workflow.md")

    File.write!(path, """
    ---
    tracker:
      kind: "memory"
    polling:
      interval_ms: 60000
    workspace:
      root: "#{Path.join(dir, "ws")}"
    agent:
      kind: "claude"
      max_concurrent_agents: 1
      max_turns: 1
    ---
    Test prompt
    """)

    path
  end

  defp refute_raw_key(conn) do
    refute conn.resp_body =~ @fake_key
    refute conn.resp_body =~ @test_key
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:cymphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:cymphony_elixir, key, value)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
