defmodule PdfElixide.MixProject do
  use Mix.Project

  @version "0.11.0"
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
      # `test/support` holds helpers required from `test_helper.exs`, not test
      # files. Elixir 1.19 warns about any file under `test/` that matches
      # neither filter; older versions load nothing but `*_test.exs` and ignore
      # this key.
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      deps: deps()
    ]
  end

  defp description do
    """
    Elixir bindings for pdf_oxide, a high-performance PDF library written in Rust.
    Extract text, tables, images, forms, annotations, and metadata, or convert PDFs to Markdown and HTML.
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
      # Guides live in `guides/` and are deliberately absent from `files/0`:
      # `mix hex.publish` builds ExDoc from the working tree and uploads the
      # generated HTML as its own docs tarball, so a guide never travels in the
      # package source. Nothing else reads this list, which is why CI runs
      # `mix docs --warnings-as-errors` — ExDoc warns on a path that is missing
      # here or on disk, and on a moduledoc link to a renamed guide.
      extras: [
        "README.md": [title: "Overview"],
        "guides/concurrency.md": [],
        "CHANGELOG.md": []
      ],
      groups_for_modules: groups_for_modules()
    ]
  end

  # Explicit module lists rather than prefix regexes: a regex would silently
  # absorb a new module whose name happens to match, and the point of writing
  # the inventory by hand is that `test/pdf_elixide/doc_groups_test.exs` can
  # then fail when it disagrees with `lib/`. That test is load-bearing — it
  # asserts every module with a real `@moduledoc` appears here exactly once, so
  # nothing falls into ExDoc's trailing ungrouped bucket unnoticed.
  #
  # Groups render in declaration order, so this is reading order, not
  # alphabetical. `PdfElixide.Error` sits under Documents because the
  # `PdfElixide` moduledoc sends readers to its "Errors versus exceptions"
  # section from the same page; `PdfElixide.Form` reads from a document *or* an
  # editor, but the mutating half is what a reader comes looking for.
  #
  # `PdfElixide.Document.Path` is spelled out, as everywhere else — see the
  # comments in `lib/pdf_elixide/document.ex` on never aliasing it bare.
  defp groups_for_modules do
    [
      Documents: [
        PdfElixide,
        PdfElixide.Document,
        PdfElixide.Document.Page,
        PdfElixide.Error
      ],
      "Document metadata": [
        PdfElixide.Document.Metadata,
        PdfElixide.Document.XmpMetadata,
        PdfElixide.Document.Permissions,
        PdfElixide.Document.OutlineItem
      ],
      "Extracted content": [
        PdfElixide.Document.Char,
        PdfElixide.Document.Word,
        PdfElixide.Document.TextLine,
        PdfElixide.Document.Span,
        PdfElixide.Document.Table,
        PdfElixide.Document.Table.Row,
        PdfElixide.Document.Table.Cell,
        PdfElixide.Document.Path,
        PdfElixide.Document.Image,
        PdfElixide.Document.Font,
        PdfElixide.Document.Annotation,
        PdfElixide.Document.Annotation.Flags
      ],
      "Geometry and color": [
        PdfElixide.Geometry.Rect,
        PdfElixide.Color,
        PdfElixide.Color.RGB,
        PdfElixide.Color.CMYK,
        PdfElixide.Color.Gray,
        PdfElixide.Color.Unknown
      ],
      "Editing and forms": [
        PdfElixide.Editor,
        PdfElixide.Form,
        PdfElixide.Form.Field
      ]
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
      # `:test` as well as `:dev` so CI can run `mix docs` in the environment it
      # has already compiled. In `:dev` it would force-build the NIF a second
      # time, for a whole cargo build bought only to read docs chunks.
      {:ex_doc, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end
end
