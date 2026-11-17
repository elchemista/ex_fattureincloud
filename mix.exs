defmodule ExFattureincloud.MixProject do
  use Mix.Project

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
          ~w(lib priv scripts guides mix.exs .formatter.exs README.md LICENSE CHANGELOG.md THIRD_PARTY_NOTICES.md)
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
      deps: deps(),
      aliases: [
        check: [
          "format --check-formatted",
          "compile --warnings-as-errors",
          "test --warnings-as-errors"
        ]
      ]
    ]
  end

  def cli, do: [preferred_envs: [check: :test]]

  # Run "mix help compile.app" to learn about applications.
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
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
