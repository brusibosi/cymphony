defmodule CymphonyElixir.Cymphony.ConfigClaudeRetryTest do
  # async: false — mutates the global :config_dir_override.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CymphonyElixir.Agent.Claude
  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.Cymphony.WorkflowGenerator
  alias CymphonyElixir.Workflow

  @project %{"name" => "alpha", "linear_project_slug" => "alpha", "linear_api_key" => "k"}

  setup do
    tmp = Path.join(System.tmp_dir!(), "cymphony-claude-retry-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

    on_exit(fn ->
      Application.delete_env(:cymphony_elixir, :config_dir_override)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  # Generates a real WORKFLOW.md for `project`, reloads it through the native
  # workflow loader and parses it with the runtime schema.
  defp runtime_settings(project, tmp) do
    path = Path.join(tmp, "WORKFLOW-#{System.unique_integer([:positive])}.md")
    assert :ok = WorkflowGenerator.write(path, project)
    assert {:ok, %{config: parsed}} = Workflow.load(path)
    assert {:ok, settings} = Schema.parse(parsed)
    {settings, parsed}
  end

  defp claude_command(settings) do
    run_spec = %{
      kind: "claude",
      command: nil,
      model: nil,
      effort: nil,
      provider: nil,
      session_id: nil,
      prompt: "go",
      workspace: "/tmp/ws",
      mcp_descriptor: nil,
      settings: settings.claude
    }

    assert {:ok, command} = Claude.build_command(run_spec)
    command
  end

  describe "generated workflow mapping" do
    test "absent keys keep the backwards-compatible defaults", %{tmp: tmp} do
      {settings, parsed} = runtime_settings(@project, tmp)

      refute Map.has_key?(parsed["claude"], "bare_mode")
      refute Map.has_key?(parsed["agent"], "max_retry_backoff_ms")
      assert settings.claude.bare_mode == true
      assert settings.agent.max_retry_backoff_ms == 300_000
      assert claude_command(settings) =~ "claude --bare -p"
    end

    test "explicit claude_bare_mode false reaches the Claude command and differs from absent", %{tmp: tmp} do
      {settings, parsed} = runtime_settings(Map.put(@project, "claude_bare_mode", false), tmp)

      assert parsed["claude"]["bare_mode"] == false
      assert settings.claude.bare_mode == false
      refute claude_command(settings) =~ "--bare"
    end

    test "explicit claude_bare_mode true is generated and keeps --bare", %{tmp: tmp} do
      {settings, parsed} = runtime_settings(Map.put(@project, "claude_bare_mode", true), tmp)

      assert parsed["claude"]["bare_mode"] == true
      assert claude_command(settings) =~ "--bare"
    end

    test "max_retry_backoff_ms maps to agent.max_retry_backoff_ms", %{tmp: tmp} do
      {settings, parsed} = runtime_settings(Map.put(@project, "max_retry_backoff_ms", 600_000), tmp)

      assert parsed["agent"]["max_retry_backoff_ms"] == 600_000
      assert settings.agent.max_retry_backoff_ms == 600_000
    end

    test "invalid stored values fall back to the safe defaults instead of breaking the project", %{tmp: tmp} do
      log =
        capture_log(fn ->
          for bad_bare <- ["false", 0, nil], bad_backoff <- [0, -1, 1.5, "600000", false] do
            project =
              @project
              |> Map.put("claude_bare_mode", bad_bare)
              |> Map.put("max_retry_backoff_ms", bad_backoff)

            {settings, _parsed} = runtime_settings(project, tmp)
            assert settings.claude.bare_mode == true
            assert settings.agent.max_retry_backoff_ms == 300_000
          end
        end)

      assert log =~ "Ignoring invalid max_retry_backoff_ms"
      assert log =~ "Ignoring invalid claude_bare_mode"
    end

    test "claude_bare_mode is not generated into other agents' sections", %{tmp: tmp} do
      project = @project |> Map.put("agent", "codex") |> Map.put("claude_bare_mode", false)
      {_settings, parsed} = runtime_settings(project, tmp)

      refute Map.has_key?(parsed["codex"], "bare_mode")
      refute Map.has_key?(parsed["antigravity"], "bare_mode")
    end
  end

  describe "update_agent_settings/2 persistence" do
    setup %{tmp: tmp} do
      config = %{
        "linear_api_key" => "k",
        "projects" => [
          Map.merge(@project, %{
            "agent" => "claude",
            "model" => "opus",
            "dispatch_paused" => true,
            "providers" => ["p1", "p2"],
            "extra_args" => %{"claude" => ["--debug"]},
            "queue_order" => ["ALE-1", "ALE-2"],
            "queue_pins" => %{"ALE-1" => %{"model" => "sonnet"}}
          }),
          %{"name" => "beta", "linear_project_slug" => "beta"}
        ]
      }

      assert :ok = CymphonyConfig.save(config)
      {:ok, path: Path.join(tmp, "config.json")}
    end

    defp project(name) do
      {:ok, config} = CymphonyConfig.load()
      {:ok, project} = CymphonyConfig.find_project(config, name)
      project
    end

    test "false and 600000 survive save/reload, unrelated settings changes and regeneration", %{tmp: tmp, path: path} do
      assert :ok =
               CymphonyConfig.update_agent_settings("alpha", %{
                 "claude_bare_mode" => false,
                 "max_retry_backoff_ms" => 600_000
               })

      # An unrelated agent/API settings change must not touch the new keys.
      assert :ok = CymphonyConfig.update_agent_settings("alpha", %{"model" => "sonnet", "effort" => "high"})

      alpha = project("alpha")
      assert alpha["claude_bare_mode"] == false
      assert alpha["max_retry_backoff_ms"] == 600_000
      assert alpha["agent"] == "claude"
      assert is_binary(alpha["agent"])

      {settings, _parsed} = runtime_settings(alpha, tmp)
      assert settings.claude.bare_mode == false
      assert settings.agent.max_retry_backoff_ms == 600_000
      assert settings.agent.model == "sonnet"
      refute claude_command(settings) =~ "--bare"

      # Unrelated flags, queue state, pause and providers are preserved.
      assert alpha["dispatch_paused"] == true
      assert alpha["providers"] == ["p1", "p2"]
      assert alpha["extra_args"] == %{"claude" => ["--debug"]}
      assert alpha["queue_order"] == ["ALE-1", "ALE-2"]
      assert alpha["queue_pins"] == %{"ALE-1" => %{"model" => "sonnet"}}
      assert settings.claude.extra_args == ["--debug"]

      # The other project is untouched and keeps the defaults.
      beta = project("beta")
      refute Map.has_key?(beta, "claude_bare_mode")
      refute Map.has_key?(beta, "max_retry_backoff_ms")

      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    end

    test "nil clears a key back to absent, distinct from an explicit false", %{tmp: tmp} do
      assert :ok = CymphonyConfig.update_agent_settings("alpha", %{"claude_bare_mode" => false, "max_retry_backoff_ms" => 600_000})
      assert :ok = CymphonyConfig.update_agent_settings("alpha", %{"claude_bare_mode" => nil, "max_retry_backoff_ms" => nil})

      alpha = project("alpha")
      refute Map.has_key?(alpha, "claude_bare_mode")
      refute Map.has_key?(alpha, "max_retry_backoff_ms")

      {settings, _parsed} = runtime_settings(alpha, tmp)
      assert settings.claude.bare_mode == true
      assert settings.agent.max_retry_backoff_ms == 300_000
    end

    test "an unrelated settings change leaves absent keys absent" do
      assert :ok = CymphonyConfig.update_agent_settings("alpha", %{"model" => "haiku"})

      alpha = project("alpha")
      refute Map.has_key?(alpha, "claude_bare_mode")
      refute Map.has_key?(alpha, "max_retry_backoff_ms")
    end

    test "invalid claude_bare_mode is rejected without replacing the valid config", %{path: path} do
      assert :ok = CymphonyConfig.update_agent_settings("alpha", %{"claude_bare_mode" => false})
      before = File.read!(path)

      for bad <- ["false", "true", 0, 1, [], %{}] do
        assert {:error, :invalid_claude_bare_mode} =
                 CymphonyConfig.update_agent_settings("alpha", %{"claude_bare_mode" => bad, "model" => "x"})
      end

      assert File.read!(path) == before
    end

    test "invalid max_retry_backoff_ms is rejected without replacing the valid config", %{path: path} do
      assert :ok = CymphonyConfig.update_agent_settings("alpha", %{"max_retry_backoff_ms" => 600_000})
      before = File.read!(path)

      for bad <- [0, -1, 1.5, "600000", "", true, [], %{}] do
        assert {:error, :invalid_max_retry_backoff_ms} =
                 CymphonyConfig.update_agent_settings("alpha", %{"max_retry_backoff_ms" => bad, "model" => "x"})
      end

      assert File.read!(path) == before
    end
  end
end
