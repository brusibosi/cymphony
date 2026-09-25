defmodule CymphonyElixir.Cymphony.ShellProvider do
  @moduledoc false

  @default_env_prefixes ~w(ANTHROPIC_ API_TIMEOUT CLAUDE_CODE_)
  @safe_function_name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name), do: Regex.match?(@safe_function_name, name)
  def valid_name?(_name), do: false

  @spec load_env(String.t(), [String.t()]) :: {:ok, map()} | {:error, :not_found}
  def load_env(provider_name, prefixes \\ @default_env_prefixes) when is_binary(provider_name) do
    if valid_name?(provider_name) do
      case cached({provider_name, prefixes}) do
        {:ok, _} = result -> result
        :miss -> fetch_and_cache(provider_name, prefixes)
      end
    else
      {:error, :not_found}
    end
  end

  @spec known_providers() :: [String.t()]
  def known_providers do
    script = """
    claude() { :; }
    codex() { :; }
    agy() { :; }
    antigravity() { :; }
    for f in "$HOME/.cld" "$HOME/.zshrc" "$HOME/.bashrc"; do
      [ -f "$f" ] && source "$f" 2>/dev/null || true
    done
    for name in $(functions | grep "^[a-z][a-z0-9]* ()" | sed 's/ ()//' | sort -u); do
      if [[ "$name" == c* ]] && [[ "$name" != claude ]] && [[ "$name" != codex ]] && [[ "$name" != agy ]] && [[ "$name" != antigravity ]] && [[ "$name" != _* ]]; then
        echo "$name"
      fi
    done
    """

    case run_zsh(script) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  @doc false
  @spec parse_env_output(String.t(), [String.t()]) :: map()
  def parse_env_output(output, prefixes) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(fn line ->
      String.contains?(line, "=") and Enum.any?(prefixes, &String.starts_with?(line, &1))
    end)
    |> Enum.into(%{}, fn line ->
      [k | rest] = String.split(line, "=", parts: 2)
      {k, Enum.join(rest, "=")}
    end)
  end

  defp fetch_and_cache(provider_name, prefixes) do
    script = """
    claude() { :; }
    codex() { :; }
    agy() { :; }
    antigravity() { :; }
    for f in "$HOME/.cld" "$HOME/.zshrc" "$HOME/.bashrc"; do
      [ -f "$f" ] && source "$f" 2>/dev/null || true
    done
    type #{provider_name} >/dev/null 2>&1 || exit 1
    _unset 2>/dev/null || true
    #{provider_name}
    env
    """

    case run_zsh(script) do
      {output, 0} ->
        env_map = parse_env_output(output, prefixes)
        put_cached({provider_name, prefixes}, env_map)
        {:ok, env_map}

      {_output, 1} ->
        {:error, :not_found}

      {_output, code} ->
        require Logger
        Logger.warning("ShellProvider exited #{code} for #{provider_name}")
        {:error, :not_found}
    end
  end

  defp cached(key) do
    case :persistent_term.get({__MODULE__, key}, :miss) do
      :miss -> :miss
      env_map -> {:ok, env_map}
    end
  end

  defp put_cached(key, env_map) do
    :persistent_term.put({__MODULE__, key}, env_map)
  end

  defp run_zsh(script) do
    cmd = Application.get_env(:cymphony_elixir, :shell_provider_cmd, &System.cmd/3)
    cmd.("zsh", ["-c", script], stderr_to_stdout: true)
  end
end
