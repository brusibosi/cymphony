defmodule CymphonyElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :cymphony_elixir,
      version: "2.8.2",
      elixir: "~> 1.19",
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        summary: [
          threshold: 100
        ],
        ignore_modules: [
          CymphonyElixir.BurritoCLI,
          CymphonyElixir.Cymphony.UrlFile,
          CymphonyElixir.Linear.Adapter,
          CymphonyElixir.Config,
          CymphonyElixir.CompletionStore,
          CymphonyElixir.Linear.Client,
          CymphonyElixir.SpecsCheck,
          CymphonyElixir.Orchestrator,
          CymphonyElixir.Orchestrator.State,
          CymphonyElixir.AgentRunner,
          CymphonyElixir.CLI,
          CymphonyElixir.Agent.Runner,
          CymphonyElixir.HttpServer,
          CymphonyElixir.Mcp.LinearGraphqlServer,
          # Stdio/EOF is exercised in real subprocesses, like the Mix task.
          CymphonyElixir.Mcp.Stdio,
          CymphonyElixir.StatusDashboard,
          CymphonyElixir.LogFile,
          CymphonyElixir.Workspace,
          CymphonyElixirWeb.DashboardLive,
          CymphonyElixirWeb.Endpoint,
          CymphonyElixirWeb.ErrorHTML,
          CymphonyElixirWeb.ErrorJSON,
          CymphonyElixirWeb.Layouts,
          CymphonyElixirWeb.ObservabilityApiController,
          CymphonyElixirWeb.Presenter,
          CymphonyElixirWeb.StaticAssetController,
          CymphonyElixirWeb.StaticAssets,
          CymphonyElixirWeb.Router,
          CymphonyElixirWeb.Router.Helpers,
          Mix.Tasks.Cymphony.Mcp.LinearGraphql
        ]
      ],
      test_ignore_filters: [
        "test/support/snapshot_support.exs",
        "test/support/test_support.exs"
      ],
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      escript: escript(),
      releases: releases(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: application_mod(),
      extra_applications: [:logger]
    ]
  end

  defp application_mod do
    if System.get_env("BURRITO_BUILD") == "1" do
      {CymphonyElixir.BurritoCLI, []}
    else
      {CymphonyElixir.Application, []}
    end
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.8"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix, "~> 1.8.0"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1.0"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:solid, "~> 1.2"},
      {:ecto, "~> 3.13"},
      {:exqlite, "~> 0.27"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:burrito, "~> 1.2"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      build: ["escript.build"],
      lint: ["specs.check", "credo --strict"],
      release: [
        fn _ -> System.put_env("BURRITO_BUILD", "1") end,
        "release"
      ]
    ]
  end

  defp escript do
    [
      app: nil,
      main_module: CymphonyElixir.CLI,
      name: "cymphony",
      path: "bin/cymphony"
    ]
  end

  defp releases do
    [
      cymphony: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux: [os: :linux, cpu: :x86_64],
            macos_intel: [os: :darwin, cpu: :x86_64],
            macos_arm: [os: :darwin, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end
end
