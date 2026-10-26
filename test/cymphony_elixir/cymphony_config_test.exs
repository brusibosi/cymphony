defmodule CymphonyElixir.Cymphony.ConfigTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Agent
  alias CymphonyElixir.Agent.Claude
  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.Cymphony.WorkflowGenerator
  alias CymphonyElixir.Linear.Issue
  alias CymphonyElixir.RunSpecResolver
  alias CymphonyElixir.Workflow

  describe "normalize/1" do
    test "keeps a non-empty projects list as-is" do
      config = %{"projects" => [%{"name" => "alpha"}], "extra" => 1}
      assert CymphonyConfig.normalize(config) == config
    end

    test "keeps a config that already has a projects key even when the list is empty" do
      config = %{"projects" => []}
      assert CymphonyConfig.normalize(config) == config
    end

    test "wraps a flat config using linear_project_slug as the project name" do
      config = %{"linear_project_slug" => "farm", "linear_api_key" => "k"}

      assert CymphonyConfig.normalize(config) == %{
               "projects" => [
                 %{
                   "linear_project_slug" => "farm",
                   "linear_api_key" => "k",
                   "name" => "farm"
                 }
               ]
             }
    end

    test "wraps a flat config with name default when slug is missing" do
      assert CymphonyConfig.normalize(%{"workspace_root" => "/tmp"}) == %{
               "projects" => [%{"workspace_root" => "/tmp", "name" => "default"}]
             }
    end
  end

  describe "projects/1" do
    test "returns the projects list from a normalized config" do
      projects = [%{"name" => "alpha"}, %{"name" => "beta"}]
      assert CymphonyConfig.projects(%{"projects" => projects}) == projects
    end

    test "returns an empty list when projects is absent or not a list" do
      assert CymphonyConfig.projects(%{}) == []
      assert CymphonyConfig.projects(%{"projects" => "oops"}) == []
      assert CymphonyConfig.projects(%{"projects" => %{}}) == []
      assert CymphonyConfig.projects("not a map") == []
    end
  end

  describe "find_project/2" do
    @config %{"projects" => [%{"name" => "alpha", "agent" => "claude"}, %{"name" => "beta"}]}

    test "returns the matching project by name" do
      assert {:ok, %{"name" => "alpha", "agent" => "claude"}} =
               CymphonyConfig.find_project(@config, "alpha")
    end

    test "returns :project_not_found when no project matches" do
      assert CymphonyConfig.find_project(@config, "ghost") == {:error, :project_not_found}
      assert CymphonyConfig.find_project(%{}, "alpha") == {:error, :project_not_found}
    end
  end

  describe "parse_providers_csv/1" do
    test "parses, trims, and drops empty segments" do
      assert CymphonyConfig.parse_providers_csv("cv1, cz2,,ck1 ,") == {:ok, ["cv1", "cz2", "ck1"]}
    end

    test "returns :empty for a blank string" do
      assert CymphonyConfig.parse_providers_csv("") == {:error, :empty}
      assert CymphonyConfig.parse_providers_csv(" , , ") == {:error, :empty}
    end

    test "returns :empty for non-binary values" do
      assert CymphonyConfig.parse_providers_csv(nil) == {:error, :empty}
      assert CymphonyConfig.parse_providers_csv(123) == {:error, :empty}
      assert CymphonyConfig.parse_providers_csv(["cv1"]) == {:error, :empty}
    end

    test "rejects aliases unsafe for shell function invocation" do
      assert CymphonyConfig.parse_providers_csv("cz,$(touch /tmp/unsafe)") == {:error, :invalid}
    end
  end

  describe "to_schema_map/1" do
    test "builds a Schema-parseable map with generation defaults applied" do
      map = CymphonyConfig.to_schema_map(%{"linear_api_key" => "k", "linear_project_slug" => "slug"})

      assert {:ok, %Schema{} = parsed} = Schema.parse(map)
      assert parsed.tracker.kind == "linear"
      assert parsed.tracker.api_key == "k"
      assert parsed.tracker.project_slug == "slug"
      assert parsed.tracker.active_states == ["Todo", "In Progress", "Merging", "Rework"]
      assert parsed.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
      assert parsed.polling.interval_ms == 5000
      assert parsed.agent.max_concurrent_agents == 10
      assert parsed.agent.max_turns == 20
      assert parsed.agent.stall_timeout_ms == 300_000
      assert parsed.claude.command == "claude"
      assert parsed.claude.output_format == "stream-json"
      assert map["antigravity"]["command"] == "agy"
      assert map["antigravity"]["output_format"] == "stream-json"
      assert map["antigravity"]["skip_permissions"] == true
    end

    test "explicit values override defaults" do
      map =
        CymphonyConfig.to_schema_map(%{
          "polling_interval_ms" => 1234,
          "max_concurrent_agents" => 7,
          "stall_timeout_ms" => 1_800_000,
          "workspace_root" => "/custom/root"
        })

      assert map["polling"]["interval_ms"] == 1234
      assert map["agent"]["max_concurrent_agents"] == 7
      assert map["agent"]["stall_timeout_ms"] == 1_800_000
      assert map["workspace"]["root"] == "/custom/root"
      assert {:ok, %Schema{} = parsed} = Schema.parse(map)
      assert parsed.agent.stall_timeout_ms == 1_800_000
    end

    test "only a positive integer stall_timeout_ms overrides the default" do
      # A typo must not silently disable the watchdog (<= 0 turns it off) or
      # generate front matter that fails Schema.parse/1.
      for bad <- [0, -1, "600000", 600_000.0, nil, true, %{}] do
        map = CymphonyConfig.to_schema_map(%{"stall_timeout_ms" => bad})
        assert map["agent"]["stall_timeout_ms"] == 300_000
      end

      assert CymphonyConfig.to_schema_map(%{})["agent"]["stall_timeout_ms"] == 300_000
      assert CymphonyConfig.to_schema_map(%{"stall_timeout_ms" => 1})["agent"]["stall_timeout_ms"] == 1
    end

    test "provider list sets providers + head; single provider sets provider; none omits both" do
      list_map = CymphonyConfig.to_schema_map(%{"providers" => ["cv1", "cz2"]})
      assert list_map["claude"]["providers"] == ["cv1", "cz2"]
      assert list_map["claude"]["provider"] == "cv1"

      single_map = CymphonyConfig.to_schema_map(%{"provider" => "ck1"})
      assert single_map["claude"]["provider"] == "ck1"
      refute Map.has_key?(single_map["claude"], "providers")

      none_map = CymphonyConfig.to_schema_map(%{})
      refute Map.has_key?(none_map["claude"], "provider")
      refute Map.has_key?(none_map["claude"], "providers")
    end

    test "empty provider values fall through and omit both keys" do
      empty_list = CymphonyConfig.to_schema_map(%{"providers" => [], "provider" => ""})
      refute Map.has_key?(empty_list["claude"], "provider")
      refute Map.has_key?(empty_list["claude"], "providers")

      non_list = CymphonyConfig.to_schema_map(%{"providers" => "cv1", "provider" => nil})
      refute Map.has_key?(non_list["claude"], "provider")
      refute Map.has_key?(non_list["claude"], "providers")
    end

    test "github_repo_url adds an after_create clone hook; absence omits hooks" do
      with_repo = CymphonyConfig.to_schema_map(%{"github_repo_url" => "git@github.com:me/repo.git"})
      assert with_repo["hooks"]["after_create"] == "git clone --depth 1 -- 'https://github.com/me/repo.git' .\n"

      refute Map.has_key?(CymphonyConfig.to_schema_map(%{}), "hooks")
      refute Map.has_key?(CymphonyConfig.to_schema_map(%{"github_repo_url" => ""}), "hooks")
      refute Map.has_key?(CymphonyConfig.to_schema_map(%{"github_repo_url" => 1}), "hooks")
    end

    test "github_repo_url that is not an scp-style git@ remote is cloned verbatim" do
      https = CymphonyConfig.to_schema_map(%{"github_repo_url" => "  https://github.com/me/repo.git  "})
      assert https["hooks"]["after_create"] == "git clone --depth 1 -- 'https://github.com/me/repo.git' .\n"

      other_host = CymphonyConfig.to_schema_map(%{"github_repo_url" => "git@gitlab.com:me/repo.git"})
      assert other_host["hooks"]["after_create"] == "git clone --depth 1 -- 'git@gitlab.com:me/repo.git' .\n"
    end

    test "clone hook quotes URL as one operand and prevents option parsing" do
      url = "--upload-pack=$(touch /tmp/cymphony-unsafe)"
      hook = CymphonyConfig.to_schema_map(%{"github_repo_url" => url})["hooks"]["after_create"]
      assert hook == "git clone --depth 1 -- '--upload-pack=$(touch /tmp/cymphony-unsafe)' .\n"

      quoted = "https://example.test/a b'c.git"
      hook = CymphonyConfig.to_schema_map(%{"github_repo_url" => quoted})["hooks"]["after_create"]
      assert hook == "git clone --depth 1 -- 'https://example.test/a b'\"'\"'c.git' .\n"
    end
  end

  describe "to_schema_map/1 agent shape" do
    test "maps agent/model/effort project keys and routes providers to the active kind section" do
      config = %{
        "name" => "P",
        "agent" => "codex",
        "model" => "gpt-5.2-codex",
        "effort" => "high",
        "providers" => ["oa1", "oa2"]
      }

      schema_map = CymphonyConfig.to_schema_map(config)

      assert schema_map["agent"]["kind"] == "codex"
      assert schema_map["agent"]["model"] == "gpt-5.2-codex"
      assert schema_map["agent"]["effort"] == "high"
      assert schema_map["codex"]["providers"] == ["oa1", "oa2"]
      assert schema_map["codex"]["provider"] == "oa1"
      refute Map.has_key?(schema_map["claude"], "providers")
      refute Map.has_key?(schema_map["claude"], "approval_policy")
    end

    test "defaults to claude kind and routes providers to claude section" do
      schema_map = CymphonyConfig.to_schema_map(%{"provider" => "cz"})
      assert schema_map["agent"]["kind"] == "claude"
      assert schema_map["claude"]["provider"] == "cz"
      assert schema_map["claude"]["command"] == "claude"
      assert schema_map["codex"]["command"] == "codex"
      assert schema_map["antigravity"]["command"] == "agy"
      refute Map.has_key?(schema_map["codex"], "provider")
      refute Map.has_key?(schema_map["antigravity"], "provider")
    end

    test "unknown agent kind falls back to claude" do
      schema_map = CymphonyConfig.to_schema_map(%{"agent" => "gemini"})
      assert schema_map["agent"]["kind"] == "claude"
    end

    test "routes providers onto the antigravity section when that kind is active" do
      schema_map =
        CymphonyConfig.to_schema_map(%{
          "agent" => "antigravity",
          "providers" => ["g1", "g2"]
        })

      assert schema_map["agent"]["kind"] == "antigravity"
      assert schema_map["antigravity"]["command"] == "agy"
      assert schema_map["antigravity"]["output_format"] == "stream-json"
      assert schema_map["antigravity"]["skip_permissions"] == true
      assert schema_map["antigravity"]["providers"] == ["g1", "g2"]
      assert schema_map["antigravity"]["provider"] == "g1"
      refute Map.has_key?(schema_map["claude"], "providers")
      refute Map.has_key?(schema_map["claude"], "provider")
      refute Map.has_key?(schema_map["codex"], "providers")
      refute Map.has_key?(schema_map["codex"], "provider")
    end
  end

  describe "to_schema_map/1 extra_args" do
    test "a map keyed by kind retains each list in its own agent section" do
      config = %{
        "agent" => "antigravity",
        "extra_args" => %{"antigravity" => ["--new-project"], "codex" => ["--full-auto"]}
      }

      schema_map = CymphonyConfig.to_schema_map(config)

      assert schema_map["antigravity"]["extra_args"] == ["--new-project"]
      assert schema_map["codex"]["extra_args"] == ["--full-auto"]
      refute Map.has_key?(schema_map["claude"], "extra_args")
      assert {:ok, %Schema{} = parsed} = Schema.parse(schema_map)
      assert parsed.antigravity.extra_args == ["--new-project"]
      assert parsed.codex.extra_args == ["--full-auto"]
    end

    test "switching the default agent does not discard other agents' explicit lists" do
      config = %{
        "agent" => "codex",
        "extra_args" => %{"antigravity" => ["--new-project"], "codex" => ["--full-auto"]}
      }

      schema_map = CymphonyConfig.to_schema_map(config)

      # A project pinned to codex must never inherit the antigravity flags.
      assert schema_map["codex"]["extra_args"] == ["--full-auto"]
      assert schema_map["antigravity"]["extra_args"] == ["--new-project"]
      assert {:ok, %Schema{} = parsed} = Schema.parse(schema_map)
      assert parsed.codex.extra_args == ["--full-auto"]
      assert parsed.antigravity.extra_args == ["--new-project"]
    end

    test "a Claude issue override keeps its Linear permission flags on a Codex-default project" do
      config = %{
        "agent" => "codex",
        "claude_bare_mode" => false,
        "extra_args" => %{
          "codex" => ["--codex-only-flag"],
          "claude" => ["--allowedTools", "mcp__claude_ai_Linear__*"]
        }
      }

      assert {:ok, parsed} = config |> CymphonyConfig.to_schema_map() |> Schema.parse()
      issue = %Issue{labels: ["agent:claude"]}
      spec = RunSpecResolver.resolve(issue, parsed)
      assert spec.agent_kind == "claude"

      assert {:ok, command} =
               Claude.build_command(%{
                 settings: Agent.section(parsed, spec.agent_kind),
                 command: nil,
                 prompt: "Read the assigned Linear issue",
                 model: spec.model,
                 effort: spec.effort,
                 session_id: nil,
                 mcp_descriptor: nil,
                 workspace: System.tmp_dir!()
               })

      assert command =~ "mcp__claude_ai_Linear__*"
      refute command =~ "--codex-only-flag"
      refute command =~ "--bare"
    end

    test "a map with no entry for the active kind emits nothing and stays quiet" do
      config = %{"agent" => "claude", "extra_args" => %{"codex" => ["--full-auto"]}}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          schema_map = CymphonyConfig.to_schema_map(config)
          refute Map.has_key?(schema_map["claude"], "extra_args")
        end)

      refute log =~ "Ignoring invalid extra_args"
    end

    test "a bare list is the convenience form and applies to the active kind" do
      claude_map = CymphonyConfig.to_schema_map(%{"extra_args" => ["--add-dir", "/srv/x"]})
      assert claude_map["claude"]["extra_args"] == ["--add-dir", "/srv/x"]
      refute Map.has_key?(claude_map["codex"], "extra_args")

      agy_map = CymphonyConfig.to_schema_map(%{"agent" => "antigravity", "extra_args" => ["--yolo"]})
      assert agy_map["antigravity"]["extra_args"] == ["--yolo"]
      assert {:ok, %Schema{} = parsed} = Schema.parse(agy_map)
      assert parsed.antigravity.extra_args == ["--yolo"]
    end

    test "only lists of strings are honored; anything else is ignored with a warning" do
      # Mirrors stall_timeout_ms: a typo in a hand-edited key must not produce
      # front matter that fails Schema.parse/1 and takes the project down.
      for bad <- ["--new-project", 1, true, ["--ok", 2], [nil], %{"antigravity" => "--x"}] do
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            schema_map = CymphonyConfig.to_schema_map(%{"agent" => "antigravity", "extra_args" => bad})
            refute Map.has_key?(schema_map["antigravity"], "extra_args")
          end)

        assert log =~ "Ignoring invalid extra_args"
      end
    end

    test "a missing key and an empty list emit nothing without warning" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          refute Map.has_key?(CymphonyConfig.to_schema_map(%{})["claude"], "extra_args")
          refute Map.has_key?(CymphonyConfig.to_schema_map(%{"extra_args" => []})["claude"], "extra_args")

          refute Map.has_key?(
                   CymphonyConfig.to_schema_map(%{"agent" => "antigravity", "extra_args" => %{"antigravity" => []}})[
                     "antigravity"
                   ],
                   "extra_args"
                 )
        end)

      refute log =~ "Ignoring invalid extra_args"
    end
  end

  describe "to_schema_map/1 new_project" do
    test "the default is omitted so the adapter keeps --new-project on" do
      schema_map = CymphonyConfig.to_schema_map(%{"agent" => "antigravity"})
      refute Map.has_key?(schema_map["antigravity"], "new_project")
      assert {:ok, %Schema{} = parsed} = Schema.parse(schema_map)
      assert parsed.antigravity.new_project == true
    end

    test "only an explicit false reaches the front matter" do
      schema_map = CymphonyConfig.to_schema_map(%{"agent" => "antigravity", "new_project" => false})
      assert schema_map["antigravity"]["new_project"] == false
      assert {:ok, %Schema{} = parsed} = Schema.parse(schema_map)
      assert parsed.antigravity.new_project == false

      for truthy <- [true, "false", 0, nil] do
        map = CymphonyConfig.to_schema_map(%{"agent" => "antigravity", "new_project" => truthy})
        refute Map.has_key?(map["antigravity"], "new_project")
      end
    end
  end

  describe "generated WORKFLOW.md front matter round-trips safely" do
    test "values with YAML metacharacters survive generation and parsing" do
      # The old hand-built-YAML path would corrupt these (`:`, `#`, quotes);
      # JSON front matter round-trips them losslessly.
      config = %{
        "linear_api_key" => "lin_api_3:foo#bar \"quoted\"",
        "linear_project_slug" => "team/sub: project # hash",
        "workspace_root" => "/tmp/weird: path #1",
        "model" => "model: 'single' \"double\" #tag"
      }

      {:ok, path} = WorkflowGenerator.write_temp(config)
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{config: parsed_map}} = Workflow.load(path)
      assert parsed_map["tracker"]["api_key"] == "lin_api_3:foo#bar \"quoted\""
      assert parsed_map["tracker"]["project_slug"] == "team/sub: project # hash"
      assert parsed_map["workspace"]["root"] == "/tmp/weird: path #1"
      assert parsed_map["agent"]["model"] == "model: 'single' \"double\" #tag"

      assert {:ok, %Schema{}} = Schema.parse(parsed_map)
    end

    test "a project's stall_timeout_ms reaches the parsed agent settings" do
      {:ok, path} =
        WorkflowGenerator.write_temp(%{
          "name" => "Slow",
          "linear_project_slug" => "slow",
          "stall_timeout_ms" => 1_800_000
        })

      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{config: parsed_map}} = Workflow.load(path)
      assert {:ok, %Schema{} = settings} = Schema.parse(parsed_map)
      assert settings.agent.stall_timeout_ms == 1_800_000
    end
  end
end
