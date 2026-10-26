defmodule CymphonyElixir.Linear.RateLimit do
  @moduledoc """
  Node-wide Linear cooldowns, shared by endpoint and authorization, across projects.

  Deadlines are Unix milliseconds. `remaining/2` and the client accept
  `:rate_limit_now_fun` for a controlled clock. A missing or invalid Retry-After
  uses `:rate_limit_fallback_ms` (10 seconds, the native initial failure backoff).
  Config-bound clients cap that fallback at `agent.max_retry_backoff_ms`.

  Persistent terms survive request-worker exit without another service. Reads
  are cheap; only rate-limit responses update the small map, under a node-local
  lock, and expired scopes are pruned on those writes. Only SHA256 scope digests
  and deadlines are retained. Already admitted requests may finish in flight.
  """

  @storage_key {__MODULE__, :cooldowns}
  @default_fallback_ms 10_000

  @spec remaining(term()) :: non_neg_integer()
  def remaining(config), do: remaining(config, [])

  @spec remaining(term(), keyword()) :: non_neg_integer()
  def remaining(%{tracker: %{endpoint: endpoint, api_key: key}}, opts) when is_binary(key) do
    max(0, deadline(endpoint, [{"authorization", key}]) - now(opts))
  end

  def remaining(_config, _opts), do: 0

  @doc "Return a shared hold before the caller starts a request."
  @spec check(String.t(), term(), keyword()) :: :ok | {:error, {:linear_rate_limited, integer()}}
  def check(endpoint, headers, opts) do
    until_ms = deadline(endpoint, headers)
    if until_ms > now(opts), do: {:error, {:linear_rate_limited, until_ms}}, else: :ok
  end

  @doc "Record an HTTP or explicit GraphQL rate-limit response, extending any current hold."
  @spec observe(String.t(), term(), map(), keyword()) :: :ok | {:error, {:linear_rate_limited, integer()}}
  def observe(endpoint, headers, response, opts) do
    if limited?(response) do
      now_ms = now(opts)
      retry_after = header_values(Map.get(response, :headers, []), "retry-after")
      delay_ms = retry_delay(retry_after, now_ms) || fallback(opts)
      scope = scope(endpoint, headers)

      until_ms = :global.trans({@storage_key, self()}, fn -> extend_deadline(scope, now_ms, delay_ms) end, [node()])

      {:error, {:linear_rate_limited, until_ms}}
    else
      :ok
    end
  end

  defp extend_deadline(scope, now_ms, delay_ms) do
    cooldowns = :persistent_term.get(@storage_key, %{})
    until_ms = max(Map.get(cooldowns, scope, 0), now_ms + delay_ms)

    updated =
      cooldowns
      |> Map.reject(fn {_scope, deadline} -> deadline <= now_ms end)
      |> Map.put(scope, until_ms)

    if updated != cooldowns, do: :persistent_term.put(@storage_key, updated)
    until_ms
  end

  @doc false
  @spec redact(String.t(), term()) :: String.t()
  def redact(text, headers) do
    headers
    |> header_values("authorization")
    |> Enum.flat_map(&String.split(&1, " ", parts: 2))
    |> Enum.reject(&(&1 == "" or String.downcase(&1) == "bearer"))
    |> Enum.reduce(text, &String.replace(&2, &1, "[REDACTED]"))
  end

  defp deadline(endpoint, headers) do
    @storage_key
    |> :persistent_term.get(%{})
    |> Map.get(scope(endpoint, headers), 0)
  end

  defp scope(endpoint, headers) do
    :crypto.hash(:sha256, :erlang.term_to_binary({endpoint, header_values(headers, "authorization")}))
  end

  defp now(opts), do: Keyword.get(opts, :rate_limit_now_fun, fn -> System.system_time(:millisecond) end).()

  defp fallback(opts) do
    case Keyword.get(opts, :rate_limit_fallback_ms, @default_fallback_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_fallback_ms
    end
  end

  defp limited?(%{status: 429}), do: true

  defp limited?(%{body: %{"errors" => errors}}) when is_list(errors) do
    Enum.any?(errors, fn
      %{"extensions" => extensions} when is_map(extensions) ->
        Enum.any?([extensions["code"], extensions["type"]], fn
          code when is_binary(code) -> String.upcase(String.trim(code)) in ["RATE_LIMITED", "RATELIMITED"]
          _ -> false
        end)

      _ ->
        false
    end)
  end

  defp limited?(_response), do: false

  defp header_values(headers, wanted) when is_list(headers) or is_map(headers) do
    Enum.flat_map(headers, fn
      {name, values} ->
        if String.downcase(to_string(name)) == wanted, do: Enum.filter(List.wrap(values), &is_binary/1), else: []

      _ ->
        []
    end)
  end

  defp header_values(_headers, _wanted), do: []

  defp retry_delay([value | _], now_ms) do
    value = String.trim(value)

    case Float.parse(value) do
      {seconds, ""} when seconds > 0 ->
        ceil(seconds * 1_000)

      _ ->
        date_retry_delay(value, now_ms)
    end
  end

  defp retry_delay(_values, _now_ms), do: nil

  defp date_retry_delay(value, now_ms) do
    case Req.Utils.parse_http_date(value) do
      {:ok, date} ->
        delay = DateTime.to_unix(date, :millisecond) - now_ms
        if delay > 0, do: delay

      _ ->
        nil
    end
  end
end
