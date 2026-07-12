defmodule Vigil.MixProject do
  use Mix.Project

  @app :vigil
  @version "0.1.0"
  @source_url "https://github.com/carvalhosauro/vigil"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: [:boundary] ++ Mix.compilers(),
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        check: :test,
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ],
      name: "Vigil",
      description: "Declarative daemon for monitoring financial assets.",
      source_url: @source_url,
      docs: docs(),
      package: package(),
      releases: releases(),
      escript: escript()
    ]
  end

  defp escript do
    [main_module: Vigil.CLI.Main, app: nil]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Vigil.Application, []}
    ]
  end

  defp deps do
    [
      # Runtime — adapters only. The core (Vigil.Core.*) stays dependency-free.
      {:yaml_elixir, "~> 2.11"},
      {:file_system, "~> 1.0"},
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.4"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.0", only: :test},

      # Architecture / quality / docs (not shipped in the release)
      {:boundary, "~> 0.10", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "cmd lefthook install"],
      # One command, every gate. Mirrors CI.
      check: [
        "format --check-formatted",
        "deps.unlock --check-unused",
        "compile --warnings-as-errors",
        "credo --strict",
        "deps.audit",
        "dialyzer",
        "coveralls"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      plt_file: {:no_warn, "priv/plts/vigil.plt"},
      ignore_warnings: ".dialyzer_ignore.exs",
      flags: [:error_handling, :extra_return, :missing_return, :unknown]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "ROADMAP.md", "CHANGELOG.md"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp releases do
    [
      vigil: [
        include_executables_for: [:unix],
        include_erts: true,
        steps: [:assemble, :tar]
      ]
    ]
  end
end
