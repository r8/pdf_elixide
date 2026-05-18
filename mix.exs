defmodule PdfElixide.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source "https://github.com/r8/pdf_elixide"

  def project do
    [
      app: :pdf_elixide,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  defp description do
    """
    Rustler-based Elixir bindings for pdf_oxide, a Rust PDF toolkit.
    """
  end

  defp package do
    [
      maintainers: ["Sergey Storchay"],
      licenses: ["MIT"],
      links: %{"Source" => @source}
    ]
  end

  defp docs do
    [
      source_url: @source,
      source_ref: "v#{@version}",
      main: "readme",
      extras: ["README.md"]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:rustler, "~> 0.37.3", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.5", only: [:dev, :test]},
      {:git_ops, "~> 2.0", only: [:dev], runtime: false},
      {:git_hooks, "~> 0.8.0", only: [:dev], runtime: false}
    ]
  end
end
