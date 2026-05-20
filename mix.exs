defmodule PdfElixide.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source "https://github.com/r8/pdf_elixide"

  def project do
    [
      app: :pdf_elixide,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  defp description do
    """
    Elixir bindings for pdf_oxide, a high-performance PDF library written in Rust.
    """
  end

  defp package do
    [
      maintainers: ["Sergey Storchay"],
      licenses: ["MIT"],
      links: links(),
      files: files()
    ]
  end

  defp links do
    %{
      "Source" => @source,
      "PDF Oxide" => "https://oxide.fyi"
    }
  end

  defp files do
    [
      "lib",
      "native/pdf_elixide_nif/src",
      "native/pdf_elixide_nif/Cargo.toml",
      "Cargo.toml",
      "Cargo.lock",
      ".cargo/config.toml",
      "mix.exs",
      "README.md",
      "LICENSE",
      "CHANGELOG.md",
      "checksum-*.exs"
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
      {:rustler_precompiled, "~> 0.7"},
      {:rustler, ">= 0.0.0", optional: true, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.5", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.0", only: [:dev], runtime: false},
      {:git_hooks, "~> 0.8.0", only: [:dev], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
