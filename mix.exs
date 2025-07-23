defmodule Middleware.MixProject do
  use Mix.Project

  def project do
    [
      app: :middleware,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :httpoison],
      mod: {Middleware.Application, []}
    ]
  end

  defp deps do
    [
      # Phoenix for HTTP server
      {:phoenix, "~> 1.7.0"},
      {:phoenix_html, "~> 3.3"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:plug_cowboy, "~> 2.5"},

      # Redis client
      {:redix, "~> 1.2"},

      # HTTP client for Rails API
      {:httpoison, "~> 2.0"},

      # JSON handling
      {:jason, "~> 1.4"},

      # UUID generation
      {:uuid, "~> 1.1"},

      # Rate limiting
      {:ex_rated, "~> 2.0"}

      # Removemos ex_unit e config pois são built-in
    ]
  end
end
