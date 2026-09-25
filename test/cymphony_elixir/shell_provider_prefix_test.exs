defmodule CymphonyElixir.ShellProviderPrefixTest do
  # async: false — mutates :shell_provider_cmd and persistent_term cache.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CymphonyElixir.Cymphony.ShellProvider

  setup do
    previous = Application.get_env(:cymphony_elixir, :shell_provider_cmd)

    on_exit(fn ->
      if previous do
        Application.put_env(:cymphony_elixir, :shell_provider_cmd, previous)
      else
        Application.delete_env(:cymphony_elixir, :shell_provider_cmd)
      end
    end)

    :ok
  end

  defp stub_cmd(fun) do
    Application.put_env(:cymphony_elixir, :shell_provider_cmd, fun)
  end

  defp unique_provider do
    "c" <> Integer.to_string(System.unique_integer([:positive]))
  end

  test "parse_env_output keeps only lines matching the given prefixes" do
    lines = """
    ANTHROPIC_API_KEY=a
    OPENAI_API_KEY=o
    CODEX_HOME=/x
    PATH=/usr/bin
    API_TIMEOUT=30
    """

    claude = ShellProvider.parse_env_output(lines, ["ANTHROPIC_", "API_TIMEOUT", "CLAUDE_CODE_"])
    assert claude == %{"ANTHROPIC_API_KEY" => "a", "API_TIMEOUT" => "30"}

    codex = ShellProvider.parse_env_output(lines, ["OPENAI_", "CODEX_", "API_TIMEOUT"])
    assert codex == %{"OPENAI_API_KEY" => "o", "CODEX_HOME" => "/x", "API_TIMEOUT" => "30"}
  end

  test "antigravity prefixes keep GEMINI_/GOOGLE_/ANTIGRAVITY_/API_TIMEOUT and drop PATH and ANTHROPIC_*" do
    lines = """
    GEMINI_API_KEY=g
    GOOGLE_API_KEY=go
    ANTIGRAVITY_MODEL=gemini
    API_TIMEOUT=30
    PATH=/usr/bin
    ANTHROPIC_API_KEY=a
    ANTHROPIC_BASE_URL=https://api.anthropic.com
    OPENAI_API_KEY=o
    """

    antigravity =
      ShellProvider.parse_env_output(lines, ["ANTIGRAVITY_", "GOOGLE_", "GEMINI_", "API_TIMEOUT"])

    assert antigravity == %{
             "GEMINI_API_KEY" => "g",
             "GOOGLE_API_KEY" => "go",
             "ANTIGRAVITY_MODEL" => "gemini",
             "API_TIMEOUT" => "30"
           }

    refute Map.has_key?(antigravity, "PATH")
    refute Map.has_key?(antigravity, "ANTHROPIC_API_KEY")
    refute Map.has_key?(antigravity, "ANTHROPIC_BASE_URL")
    refute Map.has_key?(antigravity, "OPENAI_API_KEY")
  end

  test "values containing = are preserved whole" do
    assert ShellProvider.parse_env_output("OPENAI_BASE_URL=https://x?a=b", ["OPENAI_"]) ==
             %{"OPENAI_BASE_URL" => "https://x?a=b"}
  end

  test "known_providers returns unique names from a successful zsh listing" do
    stub_cmd(fn "zsh", ["-c", script], stderr_to_stdout: true ->
      assert script =~ "antigravity() { :; }"
      assert script =~ ~s(functions | grep)
      {"cz1\ncz1\nck\n", 0}
    end)

    assert ShellProvider.known_providers() == ["cz1", "ck"]
  end

  test "known_providers returns [] when zsh exits non-zero" do
    stub_cmd(fn "zsh", ["-c", _script], _opts -> {"nope", 127} end)
    assert ShellProvider.known_providers() == []
  end

  test "load_env/1 uses default ANTHROPIC_/API_TIMEOUT/CLAUDE_CODE_ prefixes and caches the result" do
    name = unique_provider()
    calls = :counters.new(1, [])

    stub_cmd(fn "zsh", ["-c", script], stderr_to_stdout: true ->
      :counters.add(calls, 1, 1)
      assert script =~ "type #{name}"
      assert script =~ name

      output = """
      ANTHROPIC_API_KEY=secret
      CLAUDE_CODE_USE_BEDROCK=1
      API_TIMEOUT=30
      PATH=/usr/bin
      OPENAI_API_KEY=o
      """

      {output, 0}
    end)

    assert {:ok, env} = ShellProvider.load_env(name)

    assert env == %{
             "ANTHROPIC_API_KEY" => "secret",
             "CLAUDE_CODE_USE_BEDROCK" => "1",
             "API_TIMEOUT" => "30"
           }

    stub_cmd(fn _, _, _ ->
      flunk("load_env cache hit must not re-invoke zsh")
    end)

    assert {:ok, ^env} = ShellProvider.load_env(name)
    assert :counters.get(calls, 1) == 1
  end

  test "load_env captures ANTIGRAVITY_/GOOGLE_/GEMINI_ prefixes from a successful provider function" do
    name = unique_provider()
    prefixes = ["ANTIGRAVITY_", "GOOGLE_", "GEMINI_", "API_TIMEOUT"]

    stub_cmd(fn "zsh", ["-c", _script], _opts ->
      output = """
      GEMINI_API_KEY=g
      GOOGLE_API_KEY=go
      ANTIGRAVITY_MODEL=gemini
      API_TIMEOUT=30
      PATH=/usr/bin
      ANTHROPIC_API_KEY=a
      OPENAI_API_KEY=o
      """

      {output, 0}
    end)

    assert {:ok, env} = ShellProvider.load_env(name, prefixes)

    assert env == %{
             "GEMINI_API_KEY" => "g",
             "GOOGLE_API_KEY" => "go",
             "ANTIGRAVITY_MODEL" => "gemini",
             "API_TIMEOUT" => "30"
           }
  end

  test "load_env returns :not_found when the provider function is missing (exit 1)" do
    stub_cmd(fn "zsh", ["-c", _script], _opts -> {"type: not found", 1} end)
    assert ShellProvider.load_env(unique_provider()) == {:error, :not_found}
  end

  test "rejects unsafe provider aliases before invoking any shell" do
    stub_cmd(fn _, _, _ -> flunk("unsafe alias reached shell") end)

    for alias_name <- ["cz; touch /tmp/unsafe", "$(id)", "cz\nrm -rf /", "-cz", "cz/name"] do
      assert ShellProvider.load_env(alias_name) == {:error, :not_found}
    end
  end

  test "valid_name?/1 accepts safe shell function identifiers only" do
    assert ShellProvider.valid_name?("cz_2")
    assert ShellProvider.valid_name?("ag")
    refute ShellProvider.valid_name?("cz; echo leak")
    refute ShellProvider.valid_name?(nil)
  end

  test "load_env logs and returns :not_found when zsh exits with an unexpected code" do
    name = unique_provider()

    stub_cmd(fn "zsh", ["-c", _script], _opts -> {"ANTHROPIC_API_KEY=sk-sensitive", 2} end)

    log =
      capture_log(fn ->
        assert ShellProvider.load_env(name) == {:error, :not_found}
      end)

    assert log =~ "ShellProvider exited 2 for #{name}"
    refute log =~ "sk-sensitive"
  end
end
