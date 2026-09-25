defmodule CymphonyElixir.Cymphony.ConfigPersistenceTest do
  # async: false — mutates the global :config_dir_override.
  use ExUnit.Case, async: false

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig

  setup do
    tmp = Path.join(System.tmp_dir!(), "cymphony-cfg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

    on_exit(fn ->
      Application.delete_env(:cymphony_elixir, :config_dir_override)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, path: Path.join(tmp, "config.json")}
  end

  defp write_config!(path, data) when is_map(data) do
    File.write!(path, Jason.encode!(data))
  end

  describe "exists?/0 and load/0" do
    test "reports a missing file and returns a read error", %{path: path} do
      refute File.exists?(path)
      refute CymphonyConfig.exists?()
      assert {:error, msg} = CymphonyConfig.load()
      assert msg =~ "Failed to read"
      assert msg =~ path
    end

    test "loads and normalizes a valid multi-project file", %{path: path} do
      write_config!(path, %{"projects" => [%{"name" => "alpha"}]})

      assert CymphonyConfig.exists?()
      assert {:ok, %{"projects" => [%{"name" => "alpha"}]}} = CymphonyConfig.load()
    end

    test "normalizes a legacy flat file on load", %{path: path} do
      write_config!(path, %{"linear_project_slug" => "farm", "linear_api_key" => "k"})

      assert {:ok, %{"projects" => [project]}} = CymphonyConfig.load()
      assert project["name"] == "farm"
      assert project["linear_api_key"] == "k"
    end

    test "returns an invalid JSON error for a corrupt file", %{path: path} do
      File.write!(path, "{not json")

      assert {:error, msg} = CymphonyConfig.load()
      assert msg =~ "Invalid JSON in #{path}"
    end

    test "rejects valid non-object JSON without raising", %{path: path} do
      for value <- ["[]", "null", "42", ~s("hello")] do
        File.write!(path, value)
        assert {:error, message} = CymphonyConfig.load()
        assert message =~ "Invalid config in #{path}"
      end
    end
  end

  describe "save/1" do
    test "writes pretty JSON and sets 0o600 permissions", %{path: path} do
      config = %{"projects" => [%{"name" => "alpha"}]}
      assert :ok = CymphonyConfig.save(config)

      assert File.read!(path) == Jason.encode!(config, pretty: true)
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    end

    test "returns a mkdir error when the config dir is a file" do
      file = Path.join(System.tmp_dir!(), "cymphony-cfg-file-#{System.unique_integer([:positive])}")
      File.write!(file, "not a directory")
      Application.put_env(:cymphony_elixir, :config_dir_override, file)

      on_exit(fn -> File.rm_rf!(file) end)

      assert {:error, reason} = CymphonyConfig.save(%{"projects" => []})
      assert reason in [:eexist, :enotdir]
    end

    test "returns a write error when config.json is a directory", %{path: path} do
      File.mkdir_p!(path)

      assert {:error, msg} = CymphonyConfig.save(%{"projects" => []})
      assert msg =~ "Failed to write #{path}"
    end

    test "returns an encode error for values Jason cannot serialize", %{tmp: _tmp} do
      assert {:error, %Protocol.UndefinedError{protocol: Jason.Encoder}} =
               CymphonyConfig.save(%{"pid" => self()})
    end
  end

  describe "provider_env/2" do
    test "resolves top-level provider maps with agent-specific filtering", %{path: path} do
      write_config!(path, %{
        "projects" => [%{"name" => "alpha", "providers" => ["cz"]}],
        "providers" => %{
          "cz" => %{
            "ANTHROPIC_API_KEY" => "from-config",
            "OPENAI_API_KEY" => "wrong-agent",
            "API_TIMEOUT" => "30",
            "PATH" => "/unsafe",
            "ANTHROPIC_MODEL" => 123
          }
        }
      })

      assert CymphonyConfig.provider_env("cz", ["ANTHROPIC_", "API_TIMEOUT"]) ==
               {:ok, %{"ANTHROPIC_API_KEY" => "from-config", "API_TIMEOUT" => "30"}}

      assert CymphonyConfig.provider_env("cz", ["OPENAI_"]) ==
               {:ok, %{"OPENAI_API_KEY" => "wrong-agent"}}

      assert CymphonyConfig.provider_env("missing", ["ANTHROPIC_"]) == :not_found
    end
  end

  describe "update_project_queue_pin/3" do
    test "merges simultaneous per-issue patches without losing another pin", %{path: path} do
      write_config!(path, %{"projects" => [%{"name" => "alpha", "queue_pins" => %{}}]})

      1..20
      |> Task.async_stream(
        fn n ->
          CymphonyConfig.update_project_queue_pin("alpha", "ISSUE-#{n}", %{"model" => "m#{n}"})
        end,
        max_concurrency: 20,
        timeout: 10_000
      )
      |> Enum.each(fn {:ok, result} -> assert {:ok, _pins} = result end)

      assert {:ok, config} = CymphonyConfig.load()
      pins = hd(config["projects"])["queue_pins"]
      assert map_size(pins) == 20
      assert pins["ISSUE-1"] == %{"model" => "m1"}
      assert pins["ISSUE-20"] == %{"model" => "m20"}
    end
  end

  describe "update_concurrency/2" do
    test "updates only the named project", %{path: path} do
      write_config!(path, %{"projects" => [%{"name" => "alpha"}, %{"name" => "beta"}]})

      assert {:ok, updated} = CymphonyConfig.update_concurrency("alpha", 4)

      assert updated["projects"] == [
               %{"name" => "alpha", "max_concurrent_agents" => 4},
               %{"name" => "beta"}
             ]

      {:ok, reloaded} = CymphonyConfig.load()
      assert reloaded == updated
    end

    test "nil project name updates every project", %{path: path} do
      write_config!(path, %{"projects" => [%{"name" => "alpha"}, %{"name" => "beta"}]})

      assert {:ok, updated} = CymphonyConfig.update_concurrency(nil, 2)
      assert Enum.all?(updated["projects"], &(&1["max_concurrent_agents"] == 2))
    end

    test "returns the load error when the file is missing" do
      assert {:error, msg} = CymphonyConfig.update_concurrency("alpha", 3)
      assert msg =~ "Failed to read"
    end

    test "applies at the top level when projects is not a list", %{path: path} do
      write_config!(path, %{"projects" => "legacy", "name" => "flat"})

      assert {:ok, updated} = CymphonyConfig.update_concurrency("ignored", 9)
      assert updated["max_concurrent_agents"] == 9
      assert updated["projects"] == "legacy"
    end
  end

  describe "update_dispatch_paused/2 and dispatch_paused?/2" do
    test "round-trips the flag for the named project only", %{path: path} do
      write_config!(path, %{"projects" => [%{"name" => "alpha"}, %{"name" => "beta"}]})

      assert {:ok, updated} = CymphonyConfig.update_dispatch_paused("alpha", true)

      assert updated["projects"] == [
               %{"name" => "alpha", "dispatch_paused" => true},
               %{"name" => "beta"}
             ]

      {:ok, reloaded} = CymphonyConfig.load()
      assert reloaded == updated
      assert CymphonyConfig.dispatch_paused?(reloaded, "alpha")
      refute CymphonyConfig.dispatch_paused?(reloaded, "beta")

      assert {:ok, resumed} = CymphonyConfig.update_dispatch_paused("alpha", false)
      refute CymphonyConfig.dispatch_paused?(resumed, "alpha")
    end

    test "nil project name updates every project", %{path: path} do
      write_config!(path, %{"projects" => [%{"name" => "alpha"}, %{"name" => "beta"}]})

      assert {:ok, updated} = CymphonyConfig.update_dispatch_paused(nil, true)
      assert Enum.all?(updated["projects"], &(&1["dispatch_paused"] == true))
    end

    test "returns the load error when the file is missing" do
      assert {:error, msg} = CymphonyConfig.update_dispatch_paused("alpha", true)
      assert msg =~ "Failed to read"
    end

    test "applies at the top level when projects is not a list", %{path: path} do
      write_config!(path, %{"projects" => "legacy", "name" => "flat"})

      assert {:ok, updated} = CymphonyConfig.update_dispatch_paused("ignored", true)
      assert updated["dispatch_paused"] == true
      assert updated["projects"] == "legacy"
      assert CymphonyConfig.dispatch_paused?(updated, "ignored")
      assert CymphonyConfig.dispatch_paused?(updated, nil)
    end

    test "reads a sole project's flag when no project name is given" do
      assert CymphonyConfig.dispatch_paused?(%{"projects" => [%{"name" => "solo", "dispatch_paused" => true}]}, nil)
    end

    test "is false for a missing, non-boolean, or unknown-project value" do
      refute CymphonyConfig.dispatch_paused?(%{"projects" => [%{"name" => "alpha"}]}, "alpha")
      refute CymphonyConfig.dispatch_paused?(%{"projects" => [%{"name" => "alpha", "dispatch_paused" => "yes"}]}, "alpha")
      refute CymphonyConfig.dispatch_paused?(%{"projects" => [%{"name" => "alpha"}, %{"name" => "beta"}]}, nil)
      refute CymphonyConfig.dispatch_paused?(%{"projects" => []}, "ghost")
    end
  end

  describe "dashboard_refresh_seconds/0, /1 and update_dashboard_refresh_seconds/1" do
    test "reads a named top-level value and defaults to 3", %{path: path} do
      write_config!(path, %{
        "dashboard_refresh_seconds" => 7,
        "projects" => [%{"name" => "alpha", "dashboard_refresh_seconds" => 99}]
      })

      assert CymphonyConfig.dashboard_refresh_seconds() == 7
      assert CymphonyConfig.dashboard_refresh_seconds(%{"dashboard_refresh_seconds" => 7}) == 7
      assert CymphonyConfig.dashboard_refresh_seconds(7) == 7
      assert CymphonyConfig.dashboard_refresh_seconds(%{"projects" => [%{"name" => "alpha"}]}) == 3
      assert CymphonyConfig.dashboard_refresh_seconds(0) == 3
      assert CymphonyConfig.dashboard_refresh_seconds(-1) == 3
      assert CymphonyConfig.dashboard_refresh_seconds("5") == 3
      assert CymphonyConfig.dashboard_refresh_seconds(nil) == 3
    end

    test "dashboard_refresh_seconds/0 defaults to 3 when the file is missing or unreadable", %{path: path} do
      refute File.exists?(path)
      assert CymphonyConfig.dashboard_refresh_seconds() == 3

      File.write!(path, "{not json")
      assert CymphonyConfig.dashboard_refresh_seconds() == 3
    end

    test "update writes a top-level key without mutating named project maps", %{path: path} do
      write_config!(path, %{"projects" => [%{"name" => "alpha"}, %{"name" => "beta"}]})

      assert {:ok, updated} = CymphonyConfig.update_dashboard_refresh_seconds(9)
      assert updated["dashboard_refresh_seconds"] == 9
      assert updated["projects"] == [%{"name" => "alpha"}, %{"name" => "beta"}]
      refute Enum.any?(updated["projects"], &Map.has_key?(&1, "dashboard_refresh_seconds"))

      {:ok, reloaded} = CymphonyConfig.load()
      assert reloaded == updated
      assert CymphonyConfig.dashboard_refresh_seconds() == 9
    end

    test "returns the load error when the file is missing" do
      assert {:error, msg} = CymphonyConfig.update_dashboard_refresh_seconds(5)
      assert msg =~ "Failed to read"
    end

    test "rejects a non-positive interval" do
      assert {:error, :invalid_refresh_interval} = CymphonyConfig.update_dashboard_refresh_seconds(0)
      assert {:error, :invalid_refresh_interval} = CymphonyConfig.update_dashboard_refresh_seconds(-2)
      assert {:error, :invalid_refresh_interval} = CymphonyConfig.update_dashboard_refresh_seconds("5")
      assert {:error, :invalid_refresh_interval} = CymphonyConfig.update_dashboard_refresh_seconds(nil)
    end

    test "writes top-level after normalizing a legacy flat file", %{path: path} do
      write_config!(path, %{"linear_project_slug" => "farm", "linear_api_key" => "k"})

      assert {:ok, updated} = CymphonyConfig.update_dashboard_refresh_seconds(4)
      assert updated["dashboard_refresh_seconds"] == 4
      assert [%{"name" => "farm"} = project] = updated["projects"]
      refute Map.has_key?(project, "dashboard_refresh_seconds")
      refute Map.has_key?(updated, "polling_interval_ms")

      raw = Jason.decode!(File.read!(path))
      assert raw["dashboard_refresh_seconds"] == 4
      refute Map.has_key?(hd(raw["projects"]), "dashboard_refresh_seconds")
    end

    test "writes at the top level when projects is not a list", %{path: path} do
      write_config!(path, %{"projects" => "legacy", "name" => "flat"})

      assert {:ok, updated} = CymphonyConfig.update_dashboard_refresh_seconds(6)
      assert updated["dashboard_refresh_seconds"] == 6
      assert updated["projects"] == "legacy"
      assert updated["name"] == "flat"
    end
  end

  describe "update_providers/2" do
    test "updates only the named project", %{path: path} do
      write_config!(path, %{"projects" => [%{"name" => "alpha"}, %{"name" => "beta"}]})

      assert {:ok, updated} = CymphonyConfig.update_providers("alpha", ["cv1", "cz2"])
      alpha = Enum.find(updated["projects"], &(&1["name"] == "alpha"))
      beta = Enum.find(updated["projects"], &(&1["name"] == "beta"))
      assert alpha["provider"] == "cv1"
      assert alpha["providers"] == ["cv1", "cz2"]
      refute Map.has_key?(beta, "provider")
    end

    test "nil project name updates every project", %{path: path} do
      write_config!(path, %{"projects" => [%{"name" => "alpha"}, %{"name" => "beta"}]})

      assert {:ok, updated} = CymphonyConfig.update_providers(nil, ["ck1"])
      assert Enum.all?(updated["projects"], &(&1["provider"] == "ck1" and &1["providers"] == ["ck1"]))
    end

    test "rejects an empty or non-list provider list" do
      assert CymphonyConfig.update_providers("alpha", []) == {:error, :invalid_providers}
      assert CymphonyConfig.update_providers("alpha", nil) == {:error, :invalid_providers}
      assert CymphonyConfig.update_providers(nil, "cv1") == {:error, :invalid_providers}
    end

    test "returns the load error when the file is missing" do
      assert {:error, msg} = CymphonyConfig.update_providers("alpha", ["cv1"])
      assert msg =~ "Failed to read"
    end

    test "applies at the top level when projects is not a list", %{path: path} do
      write_config!(path, %{"projects" => %{"name" => "flat"}})

      assert {:ok, updated} = CymphonyConfig.update_providers("ignored", ["cz1", "cz2"])
      assert updated["provider"] == "cz1"
      assert updated["providers"] == ["cz1", "cz2"]
      assert updated["projects"] == %{"name" => "flat"}
    end
  end

  describe "update_agent_settings/2" do
    test "returns the load error when the file is missing" do
      assert {:error, msg} = CymphonyConfig.update_agent_settings("alpha", %{"model" => "opus"})
      assert msg =~ "Failed to read"
    end

    test "applies at the top level when projects is not a list", %{path: path} do
      write_config!(path, %{"projects" => nil, "effort" => "low"})

      assert :ok = CymphonyConfig.update_agent_settings("ignored", %{"model" => "opus", "effort" => ""})

      {:ok, updated} = CymphonyConfig.load()
      assert updated["model"] == "opus"
      refute Map.has_key?(updated, "effort")
      assert updated["projects"] == nil
    end
  end

  describe "update_project_queue/2" do
    test "updates only the named project and sets 0o600", %{path: path} do
      write_config!(path, %{
        "dashboard_refresh_seconds" => 9,
        "projects" => [%{"name" => "alpha"}, %{"name" => "beta"}]
      })

      assert {:ok, updated} =
               CymphonyConfig.update_project_queue("alpha", %{
                 "queue_order" => ["LLM-51", " LLM-12 ", ""],
                 "queue_pins" => %{
                   " LLM-51 " => %{
                     "agent_kind" => "codex",
                     "model" => " gpt-5.2-codex ",
                     "effort" => "high",
                     "provider" => "cz1"
                   },
                   "LLM-99" => %{"model" => "keep", "effort" => ""}
                 },
                 "queue_priority_seen" => %{" LLM-51 " => 2, "LLM-12" => nil, "LLM-0" => 0}
               })

      alpha = Enum.find(updated["projects"], &(&1["name"] == "alpha"))
      beta = Enum.find(updated["projects"], &(&1["name"] == "beta"))
      assert alpha["queue_order"] == ["LLM-51", "LLM-12"]

      assert alpha["queue_pins"] == %{
               "LLM-51" => %{
                 "agent_kind" => "codex",
                 "model" => "gpt-5.2-codex",
                 "effort" => "high"
               }
             }

      assert alpha["queue_priority_seen"] == %{"LLM-51" => 2, "LLM-12" => nil, "LLM-0" => 0}
      refute Map.has_key?(beta, "queue_order")
      refute Map.has_key?(beta, "queue_pins")
      refute Map.has_key?(beta, "queue_priority_seen")
      assert updated["dashboard_refresh_seconds"] == 9

      {:ok, reloaded} = CymphonyConfig.load()
      assert reloaded == updated
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    end

    test "nil project name updates every project", %{path: path} do
      write_config!(path, %{"projects" => [%{"name" => "alpha"}, %{"name" => "beta"}]})

      assert {:ok, updated} =
               CymphonyConfig.update_project_queue(nil, %{"queue_order" => ["LLM-1"]})

      assert Enum.all?(updated["projects"], &(&1["queue_order"] == ["LLM-1"]))
    end

    test "normalizes a legacy flat file when project name is nil", %{path: path} do
      write_config!(path, %{"linear_project_slug" => "farm", "linear_api_key" => "k"})

      assert {:ok, updated} =
               CymphonyConfig.update_project_queue(nil, %{"queue_order" => ["LLM-51"]})

      assert [%{"name" => "farm", "queue_order" => ["LLM-51"]}] = updated["projects"]
      refute Map.has_key?(updated, "queue_order")
    end

    test "returns the load error when the file is missing" do
      assert {:error, msg} = CymphonyConfig.update_project_queue("alpha", %{"queue_order" => []})
      assert msg =~ "Failed to read"
    end

    test "applies at the top level when projects is not a list", %{path: path} do
      write_config!(path, %{"projects" => "legacy", "name" => "flat"})

      assert {:ok, updated} =
               CymphonyConfig.update_project_queue("ignored", %{"queue_order" => ["LLM-1"]})

      assert updated["queue_order"] == ["LLM-1"]
      assert updated["projects"] == "legacy"
    end

    test "replaces queue_pins/order/seen and drops empty pin fields", %{path: path} do
      write_config!(path, %{
        "projects" => [
          %{
            "name" => "alpha",
            "queue_order" => ["OLD"],
            "queue_pins" => %{"LLM-51" => %{"agent_kind" => "claude", "effort" => "low"}},
            "queue_priority_seen" => %{"LLM-51" => 3, "LLM-12" => 4}
          }
        ]
      })

      assert {:ok, updated} =
               CymphonyConfig.update_project_queue("alpha", %{
                 "queue_order" => ["LLM-51", "LLM-12"],
                 "queue_pins" => %{
                   "LLM-51" => %{"model" => "opus", "agent_kind" => 1},
                   "LLM-12" => %{"effort" => "high"}
                 },
                 "queue_priority_seen" => %{"LLM-51" => 1}
               })

      [project] = updated["projects"]
      assert project["queue_order"] == ["LLM-51", "LLM-12"]
      assert project["queue_priority_seen"] == %{"LLM-51" => 1}

      assert project["queue_pins"] == %{
               "LLM-51" => %{"model" => "opus"},
               "LLM-12" => %{"effort" => "high"}
             }

      assert {:ok, deleted} =
               CymphonyConfig.update_project_queue("alpha", %{
                 "queue_pins" => %{"LLM-51" => %{}, "LLM-12" => %{"agent_kind" => "", "model" => "keep"}}
               })

      assert hd(deleted["projects"])["queue_pins"] == %{}
    end

    test "replaces a project's pins without touching another project", %{path: path} do
      write_config!(path, %{
        "projects" => [
          %{"name" => "alpha", "queue_pins" => %{"LLM-51" => "bad"}},
          %{"name" => "beta", "queue_pins" => %{"LLM-9" => %{"effort" => "low"}}}
        ]
      })

      assert {:ok, updated} =
               CymphonyConfig.update_project_queue("alpha", %{
                 "queue_pins" => %{"LLM-51" => %{"agent_kind" => "codex"}}
               })

      alpha = Enum.find(updated["projects"], &(&1["name"] == "alpha"))
      beta = Enum.find(updated["projects"], &(&1["name"] == "beta"))
      assert alpha["queue_pins"] == %{"LLM-51" => %{"agent_kind" => "codex"}}
      assert beta["queue_pins"] == %{"LLM-9" => %{"effort" => "low"}}
    end

    test "does not change other projects when the name is unknown", %{path: path} do
      write_config!(path, %{"projects" => [%{"name" => "alpha"}]})

      assert {:ok, updated} =
               CymphonyConfig.update_project_queue("ghost", %{"queue_order" => ["LLM-51"]})

      assert updated["projects"] == [%{"name" => "alpha"}]

      assert {:ok, same} = CymphonyConfig.update_project_queue("alpha", %{})
      assert same["projects"] == [%{"name" => "alpha"}]

      assert {:ok, emptied} = CymphonyConfig.update_project_queue("alpha", %{"queue_order" => ["", "  "]})
      assert hd(emptied["projects"])["queue_order"] == []

      assert {:ok, pins} = CymphonyConfig.update_project_queue("alpha", %{"queue_pins" => %{}})
      assert hd(pins["projects"])["queue_pins"] == %{}
    end

    test "rejects invalid payloads without writing", %{path: path} do
      write_config!(path, %{"projects" => [%{"name" => "alpha"}]})
      before = File.read!(path)

      assert CymphonyConfig.update_project_queue("alpha", "nope") == {:error, :invalid_queue}
      assert CymphonyConfig.update_project_queue(1, %{"queue_order" => []}) == {:error, :invalid_queue}
      assert CymphonyConfig.update_project_queue("alpha", %{"queue_order" => "LLM-51"}) == {:error, :invalid_queue}
      assert CymphonyConfig.update_project_queue("alpha", %{"queue_order" => [1]}) == {:error, :invalid_queue}
      assert CymphonyConfig.update_project_queue("alpha", %{"queue_pins" => []}) == {:error, :invalid_queue}
      assert CymphonyConfig.update_project_queue("alpha", %{"queue_pins" => %{"" => %{}}}) == {:error, :invalid_queue}
      assert CymphonyConfig.update_project_queue("alpha", %{"queue_pins" => %{1 => %{}}}) == {:error, :invalid_queue}

      assert CymphonyConfig.update_project_queue("alpha", %{"queue_pins" => %{"LLM-51" => "codex"}}) ==
               {:error, :invalid_queue}

      assert CymphonyConfig.update_project_queue("alpha", %{"queue_priority_seen" => []}) ==
               {:error, :invalid_queue}

      assert CymphonyConfig.update_project_queue("alpha", %{"queue_priority_seen" => %{"" => 1}}) ==
               {:error, :invalid_queue}

      assert CymphonyConfig.update_project_queue("alpha", %{"queue_priority_seen" => %{"LLM-51" => "2"}}) ==
               {:error, :invalid_queue}

      assert CymphonyConfig.update_project_queue("alpha", %{"queue_priority_seen" => %{1 => 2}}) ==
               {:error, :invalid_queue}

      assert File.read!(path) == before
    end
  end
end
