defmodule PdfElixide.MixProject do
  use Mix.Project

  @version "0.20.0"
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
      extras: [
        "README.md": [title: "Overview"],
        "guides/text-extraction.md": [],
        "guides/concurrency.md": [],
        "guides/forms.md": [],
        "guides/editing.md": [],
        "guides/merging-and-splitting.md": [],
        "guides/redaction.md": [],
        "guides/signatures.md": [],
        "guides/encryption.md": [],
        "guides/rendering.md": [],
        "guides/office.md": [],
        # `filename:` because ExDoc reserves `search.html` for its own search
        # page and refuses an extra that would generate it.
        "guides/search.md": [filename: "text-search"],
        "CHANGELOG.md": []
      ],
      groups_for_modules: groups_for_modules()
    ]
  end

  defp groups_for_modules do
    [
      Documents: [
        PdfElixide,
        PdfElixide.Document,
        PdfElixide.Document.Page,
        PdfElixide.Office,
        PdfElixide.Error,
        PdfElixide.Warning,
        PdfElixide.Logging
      ],
      "Document metadata": [
        PdfElixide.Document.Metadata,
        PdfElixide.Document.XmpMetadata,
        PdfElixide.Document.Permissions,
        PdfElixide.Document.OutlineItem,
        PdfElixide.Document.PageLabelRange,
        PdfElixide.Document.EmbeddedFile
      ],
      "Extracted content": [
        PdfElixide.Document.Char,
        PdfElixide.Document.Word,
        PdfElixide.Document.TextLine,
        PdfElixide.Document.Span,
        PdfElixide.Document.StructuredPage,
        PdfElixide.Document.StructuredPage.Region,
        PdfElixide.Document.SearchMatch,
        PdfElixide.Document.Table,
        PdfElixide.Document.Table.Row,
        PdfElixide.Document.Table.Cell,
        PdfElixide.Document.Path,
        PdfElixide.Document.Image,
        PdfElixide.Document.Font,
        PdfElixide.Document.Annotation,
        PdfElixide.Document.Annotation.Flags
      ],
      Rendering: [
        PdfElixide.Document.RenderedPage,
        PdfElixide.Document.SeparationPlate
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
        PdfElixide.Form.Field,
        PdfElixide.Form.Field.Flags,
        PdfElixide.Form.Field.Text,
        PdfElixide.Form.Field.Text.Flags,
        PdfElixide.Form.Field.Button,
        PdfElixide.Form.Field.Button.Flags,
        PdfElixide.Form.Field.Choice,
        PdfElixide.Form.Field.Choice.Flags,
        PdfElixide.Form.Field.Unknown,
        PdfElixide.RedactionReport,
        PdfElixide.SanitizeReport
      ],
      Signatures: [
        PdfElixide.Signature,
        PdfElixide.Signature.Certificate,
        PdfElixide.Signature.Timestamp,
        PdfElixide.Signature.DSS,
        PdfElixide.Signature.DSS.VRI
      ]
    ]
  end

  defp dialyzer do
    [
      plt_core_path: "plts",
      plt_local_path: "plts",
      list_unused_filters: true,
      flags: [:error_handling, :extra_return, :missing_return, :unknown]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:rustler_precompiled, "~> 0.7"},
      {:rustler, ">= 0.0.0", optional: true, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.5", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.0", only: [:dev], runtime: false},
      {:git_hooks, "~> 0.8.0", only: [:dev], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end
end
