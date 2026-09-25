defmodule CymphonyElixir.HardeningConfigControlCoverageTest do
  use ExUnit.Case, async: false

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.Cymphony.WorkflowGenerator
  alias CymphonyElixir.ProjectSupervisor
  alias CymphonyElixir.WorkflowStore
  alias CymphonyElixirWeb.Control

  defmodule RegisteredOrchestrator do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)

    @impl true
    def init(:ok), do: {:ok, :ok}
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "cymphony-hardening-coverage-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    prior_dir = Application.get_env(:cymphony_elixir, :config_dir_override)
    prior_graphql = Application.get_env(:cymphony_elixir, :linear_graphql_opts)
    prior_key = System.get_env("LINEAR_API_KEY")

    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)
    System.delete_env("LINEAR_API_KEY")

    on_exit(fn ->
      restore_app_env(:config_dir_override, prior_dir)
      restore_app_env(:linear_graphql_opts, prior_graphql)
      restore_system_env("LINEAR_API_KEY", prior_key)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, config_path: Path.join(tmp, "config.json")}
  end

  test "a malformed provider entry cannot be treated as an environment map", %{config_path: path} do
    File.write!(path, Jason.encode!(%{"projects" => [], "providers" => %{"alias" => ["OPENAI_API_KEY=wrong"]}}))
    assert CymphonyConfig.provider_env("alias", ["OPENAI_"]) == :not_found

    File.write!(path, Jason.encode!(%{"projects" => [], "providers" => ["alias"]}))
    assert CymphonyConfig.provider_env("alias", ["OPENAI_"]) == :not_found

    File.write!(path, "{bad JSON")
    assert CymphonyConfig.provider_env("alias", ["OPENAI_"]) == :not_found
  end

  test "an invalid stored pin map is not overwritten by an atomic pin patch", %{config_path: path} do
    original = %{"projects" => [%{"name" => "alpha", "queue_pins" => ["not", "a", "map"]}]}
    File.write!(path, Jason.encode!(original))

    assert CymphonyConfig.update_project_queue_pin("alpha", "ISSUE-1", %{"model" => "safe"}) ==
             {:error, :invalid_queue_pin}

    assert {:ok, ^original} = CymphonyConfig.load()
  end

  test "blank issue identifiers and malformed pin arguments never modify stored queue state", %{config_path: path} do
    original = %{"projects" => [%{"name" => "alpha", "queue_pins" => %{"ISSUE-1" => %{"model" => "old"}}}]}
    File.write!(path, Jason.encode!(original))

    assert CymphonyConfig.update_project_queue_pin("alpha", "  ", %{"model" => "new"}) ==
             {:error, :invalid_queue_pin}

    assert CymphonyConfig.update_project_queue_pin("alpha", "ISSUE-1", "not a map") ==
             {:error, :invalid_queue_pin}

    assert {:ok, ^original} = CymphonyConfig.load()
  end

  test "atomic pin patch supports a legacy flat config without a projects list", %{config_path: path} do
    original = %{"projects" => "legacy", "queue_pins" => %{"ISSUE-1" => %{"model" => "old"}}}
    File.write!(path, Jason.encode!(original))

    assert {:ok, pins} = CymphonyConfig.update_project_queue_pin("ignored", "ISSUE-2", %{"effort" => "high"})

    assert pins == %{
             "ISSUE-1" => %{"model" => "old"},
             "ISSUE-2" => %{"effort" => "high"}
           }

    assert {:ok, stored} = CymphonyConfig.load()
    assert stored["projects"] == "legacy"
    assert stored["queue_pins"] == pins
  end

  test "pin patch merges one field and an empty patch deletes only the selected issue", %{config_path: path} do
    config = %{
      "projects" => [
        %{
          "name" => "alpha",
          "queue_pins" => %{
            "ISSUE-1" => %{"agent_kind" => "codex", "model" => "old"},
            "ISSUE-2" => %{"effort" => "high"}
          }
        }
      ]
    }

    File.write!(path, Jason.encode!(config))

    assert {:ok, merged} = CymphonyConfig.update_project_queue_pin("alpha", "ISSUE-1", %{"model" => "new"})

    assert merged == %{
             "ISSUE-1" => %{"agent_kind" => "codex", "model" => "new"},
             "ISSUE-2" => %{"effort" => "high"}
           }

    assert {:ok, remaining} = CymphonyConfig.update_project_queue_pin("alpha", "ISSUE-1", %{})
    assert remaining == %{"ISSUE-2" => %{"effort" => "high"}}
    assert {:ok, persisted} = CymphonyConfig.load()
    assert hd(persisted["projects"])["queue_pins"] == remaining
  end

  test "Linear key connection rewrites healthy projects after multiple workflow write errors", %{
    tmp: tmp,
    config_path: path
  } do
    projects =
      for name <- ["alpha", "beta", "gamma"] do
        %{
          "name" => name,
          "linear_project_slug" => "#{name}-slug",
          "linear_api_key" => "lin_test_old",
          "workspace_root" => Path.join(tmp, "workspace-#{name}")
        }
      end

    File.write!(path, Jason.encode!(%{"projects" => projects}))

    for project <- projects do
      name = project["name"]
      dir = Path.join(tmp, "workflow-#{name}")
      File.mkdir_p!(dir)
      workflow_path = Path.join(dir, "WORKFLOW.md")
      File.write!(workflow_path, WorkflowGenerator.generate(project))
      store_name = ProjectSupervisor.via_tuple(name, :workflow_store)

      start_supervised!(%{
        id: {:store, name},
        start: {WorkflowStore, :start_link, [[name: store_name, workflow_path: workflow_path]]}
      })

      start_supervised!(%{
        id: {:orchestrator, name},
        start: {RegisteredOrchestrator, :start_link, [ProjectSupervisor.via_tuple(name, :orchestrator)]}
      })
    end

    File.rm_rf!(Path.join(tmp, "workflow-alpha"))
    File.rm_rf!(Path.join(tmp, "workflow-beta"))

    Application.put_env(:cymphony_elixir, :linear_graphql_opts,
      request_fun: fn _payload, _headers ->
        {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "fake-viewer"}}}}}
      end
    )

    assert {:error, {:workflow_rewrite_failed, failed_name, :enoent}} =
             Control.connect_linear("lin_test_new")

    assert failed_name in ["alpha", "beta"]
    assert File.read!(Path.join(tmp, "workflow-gamma/WORKFLOW.md")) =~ "lin_test_new"
    assert {:ok, config} = CymphonyConfig.load()
    assert config["linear_api_key"] == "lin_test_new"
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:cymphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:cymphony_elixir, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
