defmodule PdfElixide.MixProject do
  use Mix.Project

  @version "0.8.0"
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
      dialyzer: dialyzer(),
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
      extras: ["README.md": [title: "Overview"], "CHANGELOG.md": []]
    ]
  end

  # Both PLTs live in one gitignored directory, so CI caches a single path and
  # `rm -rf plts` is a complete reset. `files/0` is a whitelist, so nothing here
  # ever ships to Hex.
  #
  # The `overspecs`/`underspecs` family is deliberately absent: every NIF result
  # reaches Elixir as `term()` through `PdfElixide.Native.Wrap.call/1`, so those
  # flags would report a warning for nearly every public function whose spec is
  # more precise than the wrapper can prove — which is the whole design.
  defp dialyzer do
    [
      plt_core_path: "plts",
      plt_local_path: "plts",
      list_unused_filters: true,
      flags: [:error_handling, :extra_return, :missing_return, :unknown]
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
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.5", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.0", only: [:dev], runtime: false},
      {:git_hooks, "~> 0.8.0", only: [:dev], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
