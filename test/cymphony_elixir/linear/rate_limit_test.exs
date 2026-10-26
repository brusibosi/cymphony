defmodule CymphonyElixir.Linear.RateLimitTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.Linear.{Client, RateLimit}

  @now 1_798_459_200_000
  @after_10 @now + 10_000
  @after_30 @now + 30_000
  @ok %{"data" => %{"viewer" => %{"id" => "user-1"}}}

  setup do
    key = "lin_fake_#{System.unique_integer([:positive])}"
    {:ok, clock} = Agent.start_link(fn -> @now end)
    {:ok, calls} = Agent.start_link(fn -> [] end)
    now_fun = fn -> Agent.get(clock, & &1) end
    config = config("launch", key)

    opts =
      Client.graphql_opts_for_config(config)
      |> Keyword.put(:rate_limit_now_fun, now_fun)
      |> Keyword.put(:request_fun, fn payload, _headers ->
        Agent.update(calls, &[{now_fun.(), payload} | &1])
        {:ok, %{status: 200, body: @ok}}
      end)

    {:ok, key: key, config: config, clock: clock, calls: calls, opts: opts}
  end

  test "one 429 stops ninety requests across two projects until the exact deadline", ctx do
    limited = fn _, _ -> {:ok, %{status: 429, body: %{}, headers: %{"retry-after" => ["30"]}}} end

    capture_log(fn ->
      assert {:error, {:linear_api_status, 429}} =
               Client.graphql("q", %{}, Keyword.put(ctx.opts, :request_fun, limited))
    end)

    proof = config("proof", ctx.key)
    proof_opts = Keyword.merge(ctx.opts, Client.graphql_opts_for_config(proof) |> Keyword.delete(:request_fun))

    results =
      1..90
      |> Task.async_stream(fn n ->
        Client.graphql("q", %{project: rem(n, 2)}, if(rem(n, 2) == 0, do: ctx.opts, else: proof_opts))
      end)
      |> Enum.to_list()

    assert Enum.uniq(results) == [{:ok, {:error, {:linear_rate_limited, @after_30}}}]
    assert Agent.get(ctx.calls, & &1) == []
    assert RateLimit.remaining(proof, rate_limit_now_fun: fn -> @now + 29_999 end) == 1
    Agent.update(ctx.clock, fn _ -> @after_30 end)
    assert RateLimit.remaining(ctx.config, rate_limit_now_fun: fn -> @after_30 end) == 0
    assert {:ok, @ok} = Client.graphql("q", %{}, ctx.opts)
    assert [{@after_30, _}] = Agent.get(ctx.calls, & &1)
  end

  test "explicit GraphQL rate codes create a shared hold, including partial data", ctx do
    for code <- ["RATE_LIMITED", "RATELIMITED", " ratelimited "] do
      key = ctx.key <> code
      opts = Client.graphql_opts_for_api_key(key) |> Keyword.merge(Keyword.drop(ctx.opts, [:graphql_headers_fun]))
      body = %{"data" => %{"viewer" => nil}, "errors" => [%{"extensions" => %{"code" => code}}]}

      assert {:error, {:linear_rate_limited, @after_10}} =
               Client.graphql("q", %{}, Keyword.put(opts, :request_fun, fn _, _ -> {:ok, %{status: 200, body: body}} end))

      assert {:error, {:linear_rate_limited, @after_10}} = Client.graphql("q", %{}, opts)
    end

    assert Agent.get(ctx.calls, & &1) == []
  end

  test "rate hold survives the request worker exiting and independent scopes proceed", ctx do
    Task.async(fn ->
      capture_log(fn ->
        Client.graphql("q", %{}, Keyword.put(ctx.opts, :request_fun, fn _, _ -> {:ok, %{status: 429, body: %{}}} end))
      end)
    end)
    |> Task.await()

    assert RateLimit.remaining(ctx.config, rate_limit_now_fun: fn -> @now end) == 10_000
    other_key_opts = Keyword.put(ctx.opts, :graphql_headers_fun, fn -> {:ok, [{"authorization", ctx.key <> "other"}]} end)
    assert {:ok, @ok} = Client.graphql("q", %{}, other_key_opts)
    assert {:ok, @ok} = Client.graphql("q", %{}, Keyword.put(ctx.opts, :endpoint, "https://other.example/graphql"))
    assert length(Agent.get(ctx.calls, & &1)) == 2
  end

  test "Retry-After accepts case-insensitive header lists, numeric seconds and HTTP dates", ctx do
    for {headers, wait} <- [
          {[{"Retry-After", "12"}], 12_000},
          {%{"RETRY-AFTER" => ["1.5"]}, 1_500},
          {[{"retry-after", ["Mon, 28 Dec 2026 12:00:20 GMT"]}], 20_000}
        ] do
      key = ctx.key <> Integer.to_string(wait)
      opts = Keyword.put(ctx.opts, :graphql_headers_fun, fn -> {:ok, [{"Authorization", key}]} end)

      capture_log(fn ->
        assert {:error, {:linear_api_status, 429}} =
                 Client.graphql("q", %{}, Keyword.put(opts, :request_fun, fn _, _ -> {:ok, %{status: 429, body: %{}, headers: headers}} end))
      end)

      assert RateLimit.remaining(config("proof", key), rate_limit_now_fun: fn -> @now end) == wait
    end
  end

  test "missing, invalid, zero, negative and stale Retry-After use the documented fallback", ctx do
    for value <- [nil, "bad", "0", "-1", "Mon, 28 Dec 2026 12:00:00 GMT"] do
      key = ctx.key <> inspect(value)
      opts = ctx.opts |> Keyword.put(:graphql_headers_fun, fn -> {:ok, [{"Authorization", key}]} end) |> Keyword.put(:rate_limit_fallback_ms, 7_000)

      capture_log(fn ->
        Client.graphql("q", %{}, Keyword.put(opts, :request_fun, fn _, _ -> {:ok, %{status: 429, body: %{}, headers: %{"retry-after" => [value]}}} end))
      end)

      assert RateLimit.remaining(config("launch", key), rate_limit_now_fun: fn -> @now end) == 7_000
    end
  end

  test "concurrent in-flight responses only extend the deadline", ctx do
    parent = self()

    tasks =
      for seconds <- [90, 1, 30, 2] do
        Task.async(fn ->
          capture_log(fn ->
            Client.graphql(
              "q",
              %{},
              Keyword.put(ctx.opts, :request_fun, fn _, _ ->
                send(parent, {:in_flight, self()})

                receive do
                  :reply -> {:ok, %{status: 429, body: %{}, headers: %{"retry-after" => [Integer.to_string(seconds)]}}}
                end
              end)
            )
          end)
        end)
      end

    pids =
      for _ <- tasks do
        assert_receive {:in_flight, pid}
        pid
      end

    Enum.each(pids, &send(&1, :reply))
    Enum.each(tasks, &Task.await/1)
    assert RateLimit.remaining(ctx.config, rate_limit_now_fun: fn -> @now end) == 90_000
    assert Agent.get(ctx.calls, & &1) == []
  end

  test "scope storage and error logs do not expose authorization", ctx do
    secret = "Bearer " <> ctx.key
    opts = Keyword.put(ctx.opts, :graphql_headers_fun, fn -> {:ok, [{"AUTHORIZATION", secret}]} end)

    log =
      capture_log(fn ->
        Client.graphql("q", %{}, Keyword.put(opts, :request_fun, fn _, _ -> {:ok, %{status: 429, body: %{"message" => "rejected " <> secret}}} end))
      end)

    refute log =~ ctx.key
    refute inspect(:persistent_term.get()) =~ ctx.key
  end

  test "log truncation cannot expose a credential prefix", ctx do
    body = String.duplicate(".", 991) <> ctx.key

    log =
      capture_log(fn ->
        Client.graphql("q", %{}, Keyword.put(ctx.opts, :request_fun, fn _, _ -> {:ok, %{status: 400, body: body}} end))
      end)

    refute log =~ "lin_fake_"
  end

  test "normal responses, non-rate GraphQL errors and transport/HTTP error shapes remain compatible", ctx do
    for body <- [@ok, %{"errors" => [%{"extensions" => %{"code" => "AUTHENTICATION_ERROR"}}]}, %{"errors" => [%{"message" => "rate limit prose is not a structured refusal"}]}, %{"errors" => [nil]}] do
      assert {:ok, ^body} = Client.graphql("q", %{}, Keyword.put(ctx.opts, :request_fun, fn _, _ -> {:ok, %{status: 200, body: body}} end))
    end

    capture_log(fn ->
      assert {:error, {:linear_api_status, 500}} = Client.graphql("q", %{}, Keyword.put(ctx.opts, :request_fun, fn _, _ -> {:ok, %{status: 500, body: %{}}} end))
      assert {:error, {:linear_api_request, :nxdomain}} = Client.graphql("q", %{}, Keyword.put(ctx.opts, :request_fun, fn _, _ -> {:error, :nxdomain} end))
    end)

    assert RateLimit.remaining(ctx.config, rate_limit_now_fun: fn -> @now end) == 0
  end

  test "native clock and safe fallback handle malformed retry headers", ctx do
    for {headers, suffix} <- [{nil, "nil"}, {[:invalid, {"retry-after", nil}], "invalid"}] do
      key = ctx.key <> suffix
      config = config("launch", key)

      opts =
        Client.graphql_opts_for_config(config)
        |> Keyword.put(:rate_limit_fallback_ms, 0)
        |> Keyword.put(:request_fun, fn _, _ ->
          {:ok, %{status: 200, body: %{"errors" => [%{"extensions" => %{"type" => "RATELIMITED"}}]}, headers: headers}}
        end)

      before_ms = System.system_time(:millisecond)
      assert {:error, {:linear_rate_limited, until_ms}} = Client.graphql("q", %{}, opts)
      assert until_ms >= before_ms + 10_000
      assert until_ms <= System.system_time(:millisecond) + 10_000
      assert RateLimit.remaining(config) in 1..10_000
    end

    assert RateLimit.remaining(nil) == 0
  end

  test "config-bound fallback honors the configured native backoff cap", ctx do
    config = %{ctx.config | agent: %{ctx.config.agent | max_retry_backoff_ms: 1_500}}
    opts = Keyword.merge(ctx.opts, Client.graphql_opts_for_config(config) |> Keyword.delete(:request_fun))

    capture_log(fn ->
      Client.graphql("q", %{}, Keyword.put(opts, :request_fun, fn _, _ -> {:ok, %{status: 429, body: %{}}} end))
    end)

    assert RateLimit.remaining(config, rate_limit_now_fun: fn -> @now end) == 1_500
  end

  test "state type distinguishes completed and canceled while legacy fixtures keep nil" do
    assert %{state: "Done", state_type: "completed"} = Client.normalize_issue_for_test(%{"state" => %{"name" => "Done", "type" => "completed"}})
    assert %{state: "Canceled", state_type: "canceled"} = Client.normalize_issue_for_test(%{"state" => %{"name" => "Canceled", "type" => "canceled"}})
    assert %{state_type: nil} = Client.normalize_issue_for_test(%{"state" => %{"name" => "Done"}})
  end

  test "config-bound by-ID refresh excludes an issue moved out of its project", ctx do
    previous = Application.get_env(:cymphony_elixir, :linear_graphql_opts)

    on_exit(fn ->
      if previous do
        Application.put_env(:cymphony_elixir, :linear_graphql_opts, previous)
      else
        Application.delete_env(:cymphony_elixir, :linear_graphql_opts)
      end
    end)

    Application.put_env(:cymphony_elixir, :linear_graphql_opts,
      request_fun: fn payload, _headers ->
        assert payload["query"] =~ "project: {slugId: {eq: $projectSlug}}"
        assert Regex.match?(Regex.compile!("state\\s*\\{\\s*name\\s*type"), payload["query"])
        assert payload["variables"].ids == ["moved"]
        assert payload["variables"].projectSlug == "launch"
        {:ok, %{status: 200, body: %{"data" => %{"issues" => %{"nodes" => []}}}}}
      end
    )

    config = %{ctx.config | tracker: %{ctx.config.tracker | endpoint: "http://127.0.0.1:1/graphql"}}
    assert {:ok, []} = Client.fetch_issue_states_by_ids(["moved"], config)
  end

  test "config-bound by-ID refresh refuses an absent project before requesting", ctx do
    config = %{ctx.config | tracker: %{ctx.config.tracker | project_slug: nil}}
    assert {:error, :missing_linear_project_slug} = Client.fetch_issue_states_by_ids(["moved"], config)
    assert {:ok, []} = Client.fetch_issue_states_by_ids([], config)
  end

  defp config(project, key) do
    %Schema{tracker: %Schema.Tracker{kind: "linear", endpoint: "https://api.linear.app/graphql", api_key: key, project_slug: project}}
  end
end
