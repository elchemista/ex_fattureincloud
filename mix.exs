defmodule ExFattureincloud.MixProject do
  use Mix.Project

  @doc false
  @spec project() :: keyword()
  def project do
    [
      app: :ex_fattureincloud,
      version: "0.1.0",
      elixir: "~> 1.16",
      description: "An Elixir SDK for the Fatture in Cloud REST API v2, built on Req",
      source_url: "https://github.com/elchemista/ex_fattureincloud",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/elchemista/ex_fattureincloud"},
        files:
          ~w(lib priv scripts guides mix.exs .formatter.exs .credo.exs README.md LICENSE CHANGELOG.md THIRD_PARTY_NOTICES.md)
      ],
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "guides/authentication.md",
          "guides/endpoints.md",
          "guides/sdk-parity.md",
          "guides/development.md",
          "THIRD_PARTY_NOTICES.md"
        ]
      ],
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [
        summary: [threshold: 90],
        ignore_modules: [~r/^ExFattureincloud\.TestSupport\./]
      ],
      deps: deps(),
      dialyzer: [plt_local_path: "_build/dev/plts", plt_core_path: "_build/dev/plts"],
      aliases: [
        check: [
          "format --check-formatted",
          "compile --warnings-as-errors",
          "test --warnings-as-errors"
        ],
        quality: [
          "format --check-formatted",
          "compile --warnings-as-errors",
          "credo --strict",
          "dialyzer"
        ]
      ]
    ]
  end

  @doc false
  @spec cli() :: keyword()
  def cli, do: [preferred_envs: [check: :test, quality: :dev]]

  # Run "mix help compile.app" to learn about applications.
  @doc false
  @spec application() :: keyword()
  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :inets]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"},
      {:plug, "~> 1.16", only: :test},
      {:open_api_spex, "~> 3.22", only: :test},
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]
end
