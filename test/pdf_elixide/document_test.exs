defmodule PdfElixide.DocumentTest do
  use ExUnit.Case, async: true

  alias PdfElixide.Color
  alias PdfElixide.Document
  alias PdfElixide.Document.Annotation
  alias PdfElixide.Document.Char
  alias PdfElixide.Document.Metadata
  alias PdfElixide.Document.OutlineItem
  alias PdfElixide.Document.Page
  alias PdfElixide.Document.Permissions
  alias PdfElixide.Document.Span
  alias PdfElixide.Document.Table
  alias PdfElixide.Document.TextLine
  alias PdfElixide.Document.Word
  alias PdfElixide.Document.XmpMetadata
  alias PdfElixide.Error
  alias PdfElixide.Geometry.Rect

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @valid_pdf Path.join(@fixtures, "sample.pdf")
  @encrypted_pdf Path.join(@fixtures, "encrypted.pdf")
  # Encryption revision 4 (AES-128), where the password is a PDFDocEncoded byte
  # string rather than the UTF-8 @encrypted_pdf's revision 6 requires. Its user
  # password is Latin-1 "café", whose 0xE9 is not valid UTF-8 — the only fixture
  # that can prove a byte password reaches upstream unmangled.
  @latin1_pdf Path.join(@fixtures, "encrypted_latin1.pdf")
  @tagged_pdf Path.join(@fixtures, "tagged.pdf")
  @form_pdf Path.join(@fixtures, "form.pdf")
  # The only fixture carrying XFA, and it carries it behind an *indirect*
  # /AcroForm reference — the branch a check that only looked at an inline
  # dictionary would silently answer `false` for.
  @xfa_pdf Path.join(@fixtures, "xfa.pdf")
  @table_pdf Path.join(@fixtures, "table.pdf")
  @image_pdf Path.join(@fixtures, "image.pdf")
  @image_jpeg_pdf Path.join(@fixtures, "image_jpeg.pdf")
  # Purpose-built for the Markdown- and HTML-conversion options: a 24pt heading
  # over an 11pt body line, a 64x64 DeviceRGB image (upstream's converter image
  # filter drops anything under 32x32, so @image_pdf's 24x24 never surfaces),
  # and a /Widget annotation carrying /V (John Doe) in the page /Annots
  # (upstream reads widget text from /Annots only, never from @form_pdf's
  # /AcroForm).
  @markdown_pdf Path.join(@fixtures, "markdown.pdf")
  @outline_pdf Path.join(@fixtures, "outline.pdf")
  @fonts_pdf Path.join(@fixtures, "fonts.pdf")
  @metadata_pdf Path.join(@fixtures, "metadata.pdf")
  # An /Info dictionary with a different text-string encoding in every field —
  # the only fixture that can tell PDFDocEncoding from Latin-1, since
  # @metadata_pdf is pure ASCII.
  @metadata_encodings_pdf Path.join(@fixtures, "metadata_encodings.pdf")
  @annotations_pdf Path.join(@fixtures, "annotations.pdf")
  @annotation_colors_pdf Path.join(@fixtures, "annotation_colors.pdf")
  # Two real pages under a /Pages node whose /Count says three, so page 2 has
  # no page object to resolve and is the only fixture whose text extraction
  # fails for one page and succeeds for the others.
  @broken_page_pdf Path.join(@fixtures, "broken_page.pdf")
  # One OCG per /Name encoding, and pages whose Form XObjects declare inks they
  # do not — the only fixture where layer decoding and :deep are observable.
  @layers_and_inks_pdf Path.join(@fixtures, "layers_and_inks.pdf")
  # Declares its /OCProperties and /OCGs inline and invokes no XObject at all —
  # the control for both branches @layers_and_inks_pdf takes the other way.
  @extraction_pdf Path.join(@fixtures, "extraction.pdf")
  # One page per branch family of upstream's rectangle and straight-line
  # classification — the only fixture drawing a rectangle at all.
  @vector_shapes_pdf Path.join(@fixtures, "vector_shapes.pdf")
  @unreachable_page 2
  @password "secret"
  @latin1_password "caf" <> <<0xE9>>

  describe "page_count/1" do
    test "returns {:ok, 3} for the valid fixture" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, 3} = Document.page_count(doc)
    end

    test "is cached on the struct at open" do
      assert %Document{page_count: 3} = Document.open!(@valid_pdf)
      assert %Document{page_count: 3} = Document.from_binary!(File.read!(@valid_pdf))
    end

    test "arrives together with the version and the handle, from one native call" do
      # Both openers destructure a single `{ref, version, page_count}` payload, so
      # this is where that payload's shape is pinned: a change to its arity or
      # field order fails here rather than in whichever accessor noticed first.
      assert %Document{version: {1, 4}, page_count: 3} = Document.open!(@valid_pdf)

      assert %Document{version: {1, 4}, page_count: 3} =
               Document.from_binary!(File.read!(@valid_pdf))
    end

    test "an encrypted document opened with the right password caches its count" do
      # A regression floor for reading the count *after* the password is applied:
      # authentication is what makes an encrypted page tree readable. Weaker than
      # it looks — this fixture's tree resolves unauthenticated too (see the test
      # below), so no checked-in fixture can actually distinguish the orderings.
      # The `cached_fields` doc comment in document.rs is the real defence.
      assert %Document{page_count: count} = Document.open!(@encrypted_pdf, password: @password)
      assert is_integer(count)
    end

    test "falls back to the document when nothing was cached at open" do
      # The uncached state belongs to an encrypted document whose page tree needs
      # a password, which no fixture produces on demand — build it directly. The
      # fallback is what answers correctly once `authenticate/2` has run.
      %Document{} = doc = Document.open!(@valid_pdf)
      uncached = %{doc | page_count: nil}

      assert {:ok, 3} = Document.page_count(uncached)
      assert Document.page_count!(uncached) == 3

      # ...and, unlike a cached count, it needs the handle.
      :ok = Document.close(doc)
      assert {:error, %Error{reason: :closed}} = Document.page_count(uncached)
    end

    test "an encrypted document opened without a password still opens and counts" do
      doc = Document.open!(@encrypted_pdf)

      # This fixture's page tree resolves unauthenticated, so the count caches
      # like any other document; a fixture whose tree did not would cache `nil`
      # and take the fallback clause above.
      assert %Document{page_count: count} = doc
      assert is_integer(count)
      assert {:ok, ^count} = Document.page_count(doc)
      assert length(Document.pages(doc)) == count

      assert {:ok, true} = Document.authenticate(doc, @password)
      assert {:ok, ^count} = Document.page_count(doc)
    end
  end

  describe "page_count!/1" do
    test "returns the integer page count for the valid fixture" do
      doc = Document.open!(@valid_pdf)
      assert Document.page_count!(doc) == 3
    end
  end

  describe "version/1" do
    test "returns the {major, minor} tuple for the valid fixture" do
      doc = Document.open!(@valid_pdf)
      assert Document.version(doc) == {1, 4}
    end
  end

  describe "text/1" do
    test "returns {:ok, text} containing every page's text" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, text} = Document.text(doc)
      assert text =~ "Page One"
      assert text =~ "Page Two"
      assert text =~ "Page Three"
    end

    test "separates pages with a form-feed character" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, text} = Document.text(doc)
      assert text =~ "\f"
    end
  end

  describe "text/1 on_page_error" do
    test "skips a page that cannot be extracted, by default" do
      doc = Document.open!(@broken_page_pdf)

      # The skipped page keeps its slot: the separator goes in before the
      # extraction is attempted, so the result still splits into page_count
      # parts and the failure is indistinguishable from a blank page.
      assert {:ok, text} = Document.text(doc)
      assert String.split(text, "\f") == ["One", "Two", ""]
      assert Document.text(doc, on_page_error: :skip) == {:ok, text}
    end

    test ":halt fails the call, naming the page" do
      doc = Document.open!(@broken_page_pdf)

      assert {:error, %Error{reason: reason, message: message}} =
               Document.text(doc, on_page_error: :halt)

      assert message =~ "page #{@unreachable_page}: "

      # Same reason atom the equivalent per-page call reports — only the
      # message differs, by the prefix naming the page.
      assert {:error, %Error{reason: ^reason, message: per_page}} =
               Document.text(doc, @unreachable_page)

      assert message == "page #{@unreachable_page}: " <> per_page
    end

    test ":halt raises through text!/1" do
      doc = Document.open!(@broken_page_pdf)

      assert_raise Error, ~r/^page #{@unreachable_page}: /, fn ->
        Document.text!(doc, on_page_error: :halt)
      end
    end

    test "is inert on the per-page arities, which always propagate" do
      doc = Document.open!(@broken_page_pdf)
      page = Document.page!(doc, @unreachable_page)

      for opts <- [[], [on_page_error: :skip], [on_page_error: :halt]] do
        assert {:error, %Error{}} = Document.text(doc, @unreachable_page, opts)
        assert {:error, %Error{}} = Page.text(page, opts)
        assert {:ok, "One"} = Document.text(doc, 0, opts)
      end
    end

    test "rejects a value that is not :skip or :halt" do
      doc = Document.open!(@valid_pdf)

      assert_raise ArgumentError, ~r/on_page_error/, fn ->
        Document.text(doc, on_page_error: :abort)
      end
    end
  end

  describe "text!/1" do
    test "returns the combined text of the whole document" do
      doc = Document.open!(@valid_pdf)
      text = Document.text!(doc)
      assert text =~ "Page One"
      assert text =~ "Page Three"
    end
  end

  describe "text/2" do
    test "returns {:ok, text} containing the page's text for each page" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, p0} = Document.text(doc, 0)
      assert {:ok, p1} = Document.text(doc, 1)
      assert {:ok, p2} = Document.text(doc, 2)
      assert p0 =~ "Page One"
      assert p1 =~ "Page Two"
      assert p2 =~ "Page Three"
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.text(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.text(doc, -1) end
    end
  end

  describe "text!/2" do
    test "returns the text for a valid page" do
      doc = Document.open!(@valid_pdf)
      assert Document.text!(doc, 1) =~ "Page Two"
    end

    test "raises RuntimeError for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.text!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.text!(doc, :first) end
    end
  end

  describe "to_markdown/1" do
    test "returns {:ok, markdown} covering every page" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, markdown} = Document.to_markdown(doc)
      assert markdown =~ "Page One"
      assert markdown =~ "Page Two"
      assert markdown =~ "Page Three"
    end

    test "separates pages with a thematic break rather than a form feed" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, markdown} = Document.to_markdown(doc)
      assert markdown =~ "\n---\n"
      refute markdown =~ "\f"
    end

    test "detects headings by default" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, markdown} = Document.to_markdown(doc)
      assert markdown =~ "# Page One"
    end

    test "returns {:error, reason} for a closed document" do
      doc = Document.open!(@valid_pdf)
      Document.close(doc)
      assert {:error, %Error{reason: :closed}} = Document.to_markdown(doc)
    end
  end

  describe "to_markdown!/1" do
    test "returns the markdown for the whole document" do
      doc = Document.open!(@valid_pdf)
      markdown = Document.to_markdown!(doc)
      assert markdown =~ "Page One"
      assert markdown =~ "Page Three"
    end

    test "raises for a closed document" do
      doc = Document.open!(@valid_pdf)
      Document.close(doc)
      assert_raise Error, fn -> Document.to_markdown!(doc) end
    end
  end

  describe "to_markdown/2 with a page index" do
    test "returns {:ok, markdown} for the page at the given index" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, markdown} = Document.to_markdown(doc, 1)
      assert markdown =~ "Page Two"
      refute markdown =~ "Page One"
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.to_markdown(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.to_markdown(doc, -1) end
    end
  end

  describe "to_markdown/2 with options" do
    test "detect_headings: false emits plain paragraphs" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, markdown} = Document.to_markdown(doc, detect_headings: false)
      assert markdown =~ "Page One"
      refute markdown =~ "#"
    end

    test "extract_tables: false drops the markdown table" do
      doc = Document.open!(@table_pdf)
      assert {:ok, with_tables} = Document.to_markdown(doc)
      assert {:ok, without} = Document.to_markdown(doc, extract_tables: false)
      assert with_tables =~ "|---|"
      refute without =~ "|---|"
    end

    test "annotate_skipped_pages: false leaves a scanned page blank" do
      doc = Document.open!(@image_pdf)
      assert {:ok, annotated} = Document.to_markdown(doc)
      assert {:ok, bare} = Document.to_markdown(doc, annotate_skipped_pages: false)
      assert annotated =~ "OCR REQUIRED"
      assert String.trim(bare) == ""
    end

    test "detect_headings distinguishes the two font tiers" do
      doc = Document.open!(@markdown_pdf)
      assert {:ok, detected} = Document.to_markdown(doc)
      assert {:ok, plain} = Document.to_markdown(doc, detect_headings: false)
      assert detected =~ "# Markdown Fixture"
      assert plain =~ "Markdown Fixture"
      refute plain =~ "#"
    end

    test "include_images: true embeds the image as a base64 data URI" do
      doc = Document.open!(@markdown_pdf)
      assert {:ok, omitted} = Document.to_markdown(doc)
      assert {:ok, included} = Document.to_markdown(doc, include_images: true)
      refute omitted =~ "!["
      assert included =~ "![Image 1 from page 1](data:image/png;base64,"
    end

    test "max_image_pixels: 0 suppresses the image" do
      doc = Document.open!(@markdown_pdf)

      assert {:ok, markdown} =
               Document.to_markdown(doc, include_images: true, max_image_pixels: 0)

      refute markdown =~ "!["
      assert markdown =~ "Markdown Fixture"
    end

    @tag :tmp_dir
    test "embed_images: false writes the image to image_output_dir", %{tmp_dir: tmp_dir} do
      doc = Document.open!(@markdown_pdf)

      assert {:ok, markdown} =
               Document.to_markdown(doc,
                 include_images: true,
                 embed_images: false,
                 image_output_dir: tmp_dir
               )

      assert markdown =~ "![Image 1 from page 1](#{Elixir.Path.join(tmp_dir, "page1_1.png")})"
      refute markdown =~ "data:image/png;base64,"
      assert File.exists?(Elixir.Path.join(tmp_dir, "page1_1.png"))
    end

    @tag :tmp_dir
    test "embed_images: false creates a missing image_output_dir", %{tmp_dir: tmp_dir} do
      doc = Document.open!(@markdown_pdf)
      nested = Elixir.Path.join([tmp_dir, "images", "page-0"])

      assert {:ok, markdown} =
               Document.to_markdown(doc,
                 include_images: true,
                 embed_images: false,
                 image_output_dir: nested
               )

      assert markdown =~ "page1_1.png"
      assert File.exists?(Elixir.Path.join(nested, "page1_1.png"))
    end

    @tag :tmp_dir
    test "an image_output_dir that cannot be created is an :io error", %{tmp_dir: tmp_dir} do
      doc = Document.open!(@markdown_pdf)

      # A regular file cannot hold a subdirectory, so create_dir_all fails.
      blocker = Elixir.Path.join(tmp_dir, "blocker")
      File.write!(blocker, "not a directory")

      assert {:error, %Error{reason: :io}} =
               Document.to_markdown(doc,
                 include_images: true,
                 embed_images: false,
                 image_output_dir: Elixir.Path.join(blocker, "images")
               )
    end

    test "embed_images: false without an image_output_dir emits no image" do
      doc = Document.open!(@markdown_pdf)

      assert {:ok, markdown} =
               Document.to_markdown(doc, include_images: true, embed_images: false)

      refute markdown =~ "!["
      assert markdown =~ "Markdown Fixture"
    end

    test "include_form_fields: false drops the widget's value" do
      doc = Document.open!(@markdown_pdf)
      assert {:ok, included} = Document.to_markdown(doc)
      assert {:ok, omitted} = Document.to_markdown(doc, include_form_fields: false)
      assert included =~ "John Doe"
      refute omitted =~ "John Doe"
    end

    test "accepts the remaining options and returns markdown" do
      doc = Document.open!(@table_pdf)

      opts = [
        strip_running_headers_footers: true,
        expand_ligatures: true,
        bold_markers: :aggressive
      ]

      assert {:ok, markdown} = Document.to_markdown(doc, opts)
      assert is_binary(markdown)
    end

    test "accepts every reading_order value" do
      doc = Document.open!(@valid_pdf)

      for mode <- [:structure_tree, :column_aware, :top_to_bottom] do
        assert {:ok, markdown} = Document.to_markdown(doc, reading_order: mode)
        assert markdown =~ "Page One"
      end
    end

    test "raises for an option of the wrong type" do
      doc = Document.open!(@valid_pdf)

      assert_raise ArgumentError, ~r/:detect_headings/, fn ->
        Document.to_markdown(doc, detect_headings: "yes")
      end
    end

    test "raises for an unknown reading_order value" do
      doc = Document.open!(@valid_pdf)

      assert_raise ArgumentError, ~r/:reading_order/, fn ->
        Document.to_markdown(doc, reading_order: :nope)
      end
    end

    test "raises for an unknown key" do
      doc = Document.open!(@valid_pdf)

      assert_raise ArgumentError, ~r/:detect_heading/, fn ->
        Document.to_markdown(doc, detect_heading: true)
      end
    end
  end

  describe "to_markdown!/2" do
    test "returns the markdown for a valid page" do
      doc = Document.open!(@valid_pdf)
      assert Document.to_markdown!(doc, 1) =~ "Page Two"
    end

    test "returns the markdown for the whole document with options" do
      doc = Document.open!(@valid_pdf)
      markdown = Document.to_markdown!(doc, detect_headings: false)
      assert markdown =~ "Page One"
      refute markdown =~ "#"
    end

    test "raises RuntimeError for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.to_markdown!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer, non-list second argument" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.to_markdown!(doc, :first) end
    end
  end

  describe "to_markdown/3" do
    test "applies options to the given page" do
      doc = Document.open!(@table_pdf)
      assert {:ok, with_tables} = Document.to_markdown(doc, 0, [])
      assert {:ok, without} = Document.to_markdown(doc, 0, extract_tables: false)
      assert with_tables =~ "|---|"
      refute without =~ "|---|"
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.to_markdown(doc, 99, [])
    end

    test "raises FunctionClauseError for a non-list options argument" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.to_markdown(doc, 0, :opts) end
    end
  end

  describe "to_markdown!/3" do
    test "returns the markdown for a page with options applied" do
      doc = Document.open!(@valid_pdf)
      markdown = Document.to_markdown!(doc, 0, detect_headings: false)
      assert markdown =~ "Page One"
      refute markdown =~ "#"
    end

    test "raises RuntimeError for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.to_markdown!(doc, 99, []) end
    end
  end

  describe "to_html/1" do
    test "returns {:ok, html} covering every page" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, html} = Document.to_html(doc)
      assert html =~ "Page One"
      assert html =~ "Page Two"
      assert html =~ "Page Three"
    end

    test "wraps each page in a one-based page div rather than joining pages" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, html} = Document.to_html(doc)
      assert html =~ ~s(<div class="page" data-page="1">)
      assert html =~ ~s(<div class="page" data-page="3">)
      refute html =~ ~s(data-page="0")
      refute html =~ "\n---\n"
      refute html =~ "\f"
    end

    test "returns a fragment rather than a standalone document" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, html} = Document.to_html(doc)
      refute html =~ "<!DOCTYPE"
      refute html =~ "<html"
      refute html =~ "<body"
      refute html =~ "<style"
    end

    test "detects headings by default" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, html} = Document.to_html(doc)
      assert html =~ "<h1>Page One</h1>"
    end

    test "returns {:ok, empty} for an encrypted document opened without a password" do
      doc = Document.open!(@encrypted_pdf)
      assert {:ok, ""} = Document.to_html(doc)
    end

    test "returns {:error, reason} for a closed document" do
      doc = Document.open!(@valid_pdf)
      Document.close(doc)
      assert {:error, %Error{reason: :closed}} = Document.to_html(doc)
    end
  end

  describe "to_html!/1" do
    test "returns the html for the whole document" do
      doc = Document.open!(@valid_pdf)
      html = Document.to_html!(doc)
      assert html =~ "Page One"
      assert html =~ "Page Three"
    end

    test "raises for a closed document" do
      doc = Document.open!(@valid_pdf)
      Document.close(doc)
      assert_raise Error, fn -> Document.to_html!(doc) end
    end
  end

  describe "to_html/2 with a page index" do
    test "returns {:ok, html} for the page at the given index, without the page div" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, html} = Document.to_html(doc, 1)
      assert html =~ "Page Two"
      refute html =~ "Page One"
      refute html =~ ~s(class="page")
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.to_html(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.to_html(doc, -1) end
    end
  end

  describe "to_html/2 with options" do
    test "detect_headings: false emits plain paragraphs" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, html} = Document.to_html(doc, detect_headings: false)
      assert html =~ "<p>Page One</p>"
      refute html =~ "<h1"
    end

    test "extract_tables: false drops the html table" do
      doc = Document.open!(@table_pdf)
      assert {:ok, with_tables} = Document.to_html(doc)
      assert {:ok, without} = Document.to_html(doc, extract_tables: false)
      assert with_tables =~ "<table>"
      assert with_tables =~ "<td>Age</td>"
      refute without =~ "<table"
      assert without =~ "<p>Age"
    end

    test "preserve_layout: true emits absolutely positioned divs" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, html} = Document.to_html(doc, preserve_layout: true)
      assert html =~ ~s(<div style="position:absolute;)
      assert html =~ "font-size:24pt;"
      assert html =~ "Page One"
      refute html =~ "<h1"
      refute html =~ "<p>"
    end

    test "preserve_layout: true writes PDF y verbatim into CSS top, unflipped" do
      doc = Document.open!(@valid_pdf)
      page = Document.page!(doc, 0)
      assert {:ok, html} = Document.to_html(doc, 0, preserve_layout: true)

      # Upstream writes the span's PDF user-space y — measured from the bottom
      # of the page — straight into CSS `top`, which measures from the top. The
      # text sits at y=720 on a 792pt page, so a converter that flipped it
      # would emit top:72pt. Pinned because `html_opts` documents the flip as
      # the caller's job; if upstream ever fixes it, this test says so.
      assert Page.height!(page) == 792.0
      assert html =~ "top:720pt;"
      refute html =~ "top:72pt;"

      # The page wrapper is likewise unstyled, so it gives the positioned spans
      # no containing block to resolve against.
      assert {:ok, all} = Document.to_html(doc, preserve_layout: true)
      assert all =~ ~s(<div class="page" data-page="1">)
      refute all =~ ~s(<div class="page" data-page="1" style)
    end

    test "preserve_layout: true drops tables, which upstream emits only in semantic mode" do
      doc = Document.open!(@table_pdf)
      assert {:ok, html} = Document.to_html(doc, preserve_layout: true, extract_tables: true)
      refute html =~ "<table"
      assert html =~ "position:absolute;"
      assert html =~ "Age"
    end

    test "detect_headings distinguishes the two font tiers" do
      doc = Document.open!(@markdown_pdf)
      assert {:ok, detected} = Document.to_html(doc)
      assert {:ok, plain} = Document.to_html(doc, detect_headings: false)
      assert detected =~ "<h1>Markdown Fixture</h1>"
      # Without the heading split, the two tiers run into one paragraph.
      assert plain =~ "<p>Markdown Fixture Body paragraph text.</p>"
      refute plain =~ "<h1"
    end

    test "include_images: true embeds the image as a base64 data URI" do
      doc = Document.open!(@markdown_pdf)
      assert {:ok, omitted} = Document.to_html(doc)
      assert {:ok, included} = Document.to_html(doc, include_images: true)
      refute omitted =~ "<img"
      assert included =~ ~s(<div class="page-images">)
      assert included =~ ~s(<img src="data:image/png;base64,)
      assert included =~ ~s(alt="Image 1 from page 1")
    end

    test "max_image_pixels: 0 suppresses the image" do
      doc = Document.open!(@markdown_pdf)
      assert {:ok, html} = Document.to_html(doc, include_images: true, max_image_pixels: 0)
      refute html =~ "<img"
      assert html =~ "Markdown Fixture"
    end

    @tag :tmp_dir
    test "embed_images: false writes the image to image_output_dir", %{tmp_dir: tmp_dir} do
      doc = Document.open!(@markdown_pdf)

      assert {:ok, html} =
               Document.to_html(doc,
                 include_images: true,
                 embed_images: false,
                 image_output_dir: tmp_dir
               )

      assert html =~ ~s(<img src="#{Elixir.Path.join(tmp_dir, "page1_1.png")}")
      refute html =~ "data:image/png;base64,"
      assert File.exists?(Elixir.Path.join(tmp_dir, "page1_1.png"))
    end

    @tag :tmp_dir
    test "embed_images: false creates a missing image_output_dir", %{tmp_dir: tmp_dir} do
      doc = Document.open!(@markdown_pdf)
      nested = Elixir.Path.join([tmp_dir, "images", "page-0"])

      assert {:ok, html} =
               Document.to_html(doc,
                 include_images: true,
                 embed_images: false,
                 image_output_dir: nested
               )

      assert html =~ "page1_1.png"
      assert File.exists?(Elixir.Path.join(nested, "page1_1.png"))
    end

    @tag :tmp_dir
    test "an image_output_dir that cannot be created is an :io error", %{tmp_dir: tmp_dir} do
      doc = Document.open!(@markdown_pdf)

      # A regular file cannot hold a subdirectory, so create_dir_all fails.
      blocker = Elixir.Path.join(tmp_dir, "blocker")
      File.write!(blocker, "not a directory")

      assert {:error, %Error{reason: :io}} =
               Document.to_html(doc,
                 include_images: true,
                 embed_images: false,
                 image_output_dir: Elixir.Path.join(blocker, "images")
               )
    end

    test "embed_images: false without an image_output_dir emits no image" do
      doc = Document.open!(@markdown_pdf)
      assert {:ok, html} = Document.to_html(doc, include_images: true, embed_images: false)
      refute html =~ "<img"
      assert html =~ "Markdown Fixture"
    end

    @tag :tmp_dir
    test "an image_output_dir is not attribute-escaped in src", %{tmp_dir: tmp_dir} do
      doc = Document.open!(@markdown_pdf)
      # A double quote is a legal filename character, and upstream interpolates
      # the path into src="…" unescaped, so it closes the attribute. Pinned
      # because :image_output_dir documents this as a reason never to build the
      # path from untrusted input.
      quoted = Elixir.Path.join(tmp_dir, ~s(img"dir))

      assert {:ok, html} =
               Document.to_html(doc,
                 include_images: true,
                 embed_images: false,
                 image_output_dir: quoted
               )

      assert html =~ ~s(src="#{quoted}/page1_1.png")
      refute html =~ "&quot;"
      assert File.exists?(Elixir.Path.join(quoted, "page1_1.png"))
    end

    test "include_form_fields: false drops the widget's value" do
      doc = Document.open!(@markdown_pdf)
      assert {:ok, included} = Document.to_html(doc)
      assert {:ok, omitted} = Document.to_html(doc, include_form_fields: false)
      assert included =~ "John Doe"
      refute omitted =~ "John Doe"
    end

    test "accepts every reading_order value" do
      doc = Document.open!(@valid_pdf)

      for mode <- [:structure_tree, :column_aware, :top_to_bottom] do
        assert {:ok, html} = Document.to_html(doc, reading_order: mode)
        assert html =~ "Page One"
      end
    end

    test "raises for an option of the wrong type" do
      doc = Document.open!(@valid_pdf)

      assert_raise ArgumentError, ~r/:detect_headings/, fn ->
        Document.to_html(doc, detect_headings: "yes")
      end
    end

    test "raises for an unknown reading_order value" do
      doc = Document.open!(@valid_pdf)

      assert_raise ArgumentError, ~r/:reading_order/, fn ->
        Document.to_html(doc, reading_order: :nope)
      end
    end

    test "raises for a Markdown-only option rather than ignoring it" do
      doc = Document.open!(@valid_pdf)

      # These keys are valid for `to_markdown/2` but upstream never consults
      # them on the HTML path, so accepting them would silently promise an
      # effect that cannot happen.
      for opt <- [[bold_markers: :aggressive], [annotate_skipped_pages: false]] do
        assert_raise ArgumentError, fn -> Document.to_html(doc, opt) end
      end
    end
  end

  describe "to_html!/2" do
    test "returns the html for a valid page" do
      doc = Document.open!(@valid_pdf)
      assert Document.to_html!(doc, 1) =~ "Page Two"
    end

    test "returns the html for the whole document with options" do
      doc = Document.open!(@valid_pdf)
      html = Document.to_html!(doc, detect_headings: false)
      assert html =~ "Page One"
      refute html =~ "<h1"
    end

    test "raises RuntimeError for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.to_html!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer, non-list second argument" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.to_html!(doc, :first) end
    end
  end

  describe "to_html/3" do
    test "applies options to the given page" do
      doc = Document.open!(@table_pdf)
      assert {:ok, with_tables} = Document.to_html(doc, 0, [])
      assert {:ok, without} = Document.to_html(doc, 0, extract_tables: false)
      assert with_tables =~ "<table>"
      refute without =~ "<table"
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.to_html(doc, 99, [])
    end

    test "raises FunctionClauseError for a non-list options argument" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.to_html(doc, 0, :opts) end
    end
  end

  describe "to_html!/3" do
    test "returns the html for a page with options applied" do
      doc = Document.open!(@valid_pdf)
      html = Document.to_html!(doc, 0, detect_headings: false)
      assert html =~ "<p>Page One</p>"
      refute html =~ "<h1"
    end

    test "raises RuntimeError for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.to_html!(doc, 99, []) end
    end
  end

  describe "words/1" do
    test "returns {:ok, words} for every page as a flat list" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, words} = Document.words(doc)
      assert Enum.all?(words, &match?(%Word{}, &1))

      text = Enum.map_join(words, " ", & &1.text)
      assert text =~ "Page One"
      assert text =~ "Page Two"
      assert text =~ "Page Three"
    end

    test "length equals the sum of the per-page word counts" do
      doc = Document.open!(@valid_pdf)
      {:ok, all} = Document.words(doc)

      per_page_total =
        0..(Document.page_count!(doc) - 1)//1
        |> Enum.map(fn i -> length(elem(Document.words(doc, i), 1)) end)
        |> Enum.sum()

      assert length(all) == per_page_total
    end

    test "each word carries its zero-based page index" do
      doc = Document.open!(@valid_pdf)
      {:ok, words} = Document.words(doc)
      assert Enum.map(words, & &1.page) == [0, 0, 1, 1, 2, 2]
    end
  end

  describe "words!/1" do
    test "returns the flat word list of the whole document" do
      doc = Document.open!(@valid_pdf)
      words = Document.words!(doc)
      assert Enum.all?(words, &match?(%Word{}, &1))
      assert Enum.any?(words, &(&1.text == "One"))
      assert Enum.any?(words, &(&1.text == "Three"))
    end
  end

  describe "words/2" do
    test "returns {:ok, words} carrying text, bbox and font metadata" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, [%Word{} = word | _]} = Document.words(doc, 0)

      assert word.text == "Page"
      assert word.page == 0
      assert %Rect{} = word.bbox
      assert word.bbox.width > 0
      assert word.bbox.height > 0
      assert is_float(word.font_size)
      assert is_binary(word.font)
      assert is_boolean(word.bold?)
      assert is_boolean(word.italic?)
    end

    test "returns each page's words" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, w0} = Document.words(doc, 0)
      assert {:ok, w1} = Document.words(doc, 1)
      assert Enum.map(w0, & &1.text) == ["Page", "One"]
      assert Enum.map(w1, & &1.text) == ["Page", "Two"]
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.words(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.words(doc, -1) end
    end
  end

  describe "Word inspect/1" do
    test "renders the text, page, and bounding-box origin" do
      doc = Document.open!(@valid_pdf)
      [word | _] = Document.words!(doc, 0)
      assert inspect(word) == ~s(#PdfElixide.Document.Word<"Page" @ p0 72.0,720.0>)
    end
  end

  describe "words!/2" do
    test "returns the words for a valid page" do
      doc = Document.open!(@valid_pdf)
      assert [%Word{text: "Page"}, %Word{text: "One"}] = Document.words!(doc, 0)
    end

    test "raises RuntimeError for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.words!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.words!(doc, :first) end
    end
  end

  describe "text_lines/1" do
    test "returns {:ok, lines} for every page as a flat list" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, lines} = Document.text_lines(doc)
      assert Enum.all?(lines, &match?(%TextLine{}, &1))
      assert Enum.map(lines, & &1.text) == ["Page One", "Page Two", "Page Three"]
    end

    test "each line carries its zero-based page index" do
      doc = Document.open!(@valid_pdf)
      {:ok, lines} = Document.text_lines(doc)
      assert Enum.map(lines, & &1.page) == [0, 1, 2]
    end
  end

  describe "text_lines!/1" do
    test "returns the flat line list of the whole document" do
      doc = Document.open!(@valid_pdf)
      lines = Document.text_lines!(doc)
      assert Enum.all?(lines, &match?(%TextLine{}, &1))
      assert Enum.any?(lines, &(&1.text == "Page Three"))
    end
  end

  describe "text_lines/2" do
    test "returns {:ok, lines} carrying text, page, bbox and nested words" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, [%TextLine{} = line]} = Document.text_lines(doc, 0)

      assert line.text == "Page One"
      assert line.page == 0
      assert %Rect{} = line.bbox
      assert line.bbox.width > 0
      assert line.bbox.height > 0
      assert [%Word{text: "Page"}, %Word{text: "One"}] = line.words
      assert Enum.all?(line.words, &(&1.page == 0))
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.text_lines(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.text_lines(doc, -1) end
    end
  end

  describe "text_lines!/2" do
    test "returns the lines for a valid page" do
      doc = Document.open!(@valid_pdf)
      assert [%TextLine{text: "Page Two"}] = Document.text_lines!(doc, 1)
    end

    test "raises RuntimeError for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.text_lines!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.text_lines!(doc, :first) end
    end
  end

  describe "TextLine inspect/1" do
    test "renders the text, page, and word count" do
      doc = Document.open!(@valid_pdf)
      [line] = Document.text_lines!(doc, 0)
      assert inspect(line) == ~s|#PdfElixide.Document.TextLine<"Page One" @ p0 (2 words)>|
    end
  end

  describe "chars/1" do
    test "returns {:ok, chars} for every page as a flat list" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, chars} = Document.chars(doc)
      assert Enum.all?(chars, &match?(%Char{}, &1))

      text = Enum.map_join(chars, & &1.text)
      assert text =~ "Page One"
      assert text =~ "Page Two"
      assert text =~ "Page Three"
    end

    test "length equals the sum of the per-page char counts" do
      doc = Document.open!(@valid_pdf)
      {:ok, all} = Document.chars(doc)

      per_page_total =
        0..(Document.page_count!(doc) - 1)//1
        |> Enum.map(fn i -> length(elem(Document.chars(doc, i), 1)) end)
        |> Enum.sum()

      assert length(all) == per_page_total
    end

    test "each char carries its zero-based page index" do
      doc = Document.open!(@valid_pdf)
      {:ok, chars} = Document.chars(doc)
      assert chars |> Enum.map(& &1.page) |> Enum.uniq() == [0, 1, 2]
    end
  end

  describe "chars!/1" do
    test "returns the flat char list of the whole document" do
      doc = Document.open!(@valid_pdf)
      chars = Document.chars!(doc)
      assert Enum.all?(chars, &match?(%Char{}, &1))
      assert Enum.all?(chars, &(String.length(&1.text) == 1))
    end
  end

  describe "chars/2" do
    test "returns {:ok, chars} carrying text, bbox, font and typographic metadata" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, [%Char{} = char | _]} = Document.chars(doc, 0)

      assert char.text == "P"
      assert char.page == 0
      assert %Rect{} = char.bbox
      assert char.bbox.width > 0
      assert char.bbox.height > 0
      assert is_float(char.font_size)
      assert is_binary(char.font)
      assert is_integer(char.font_weight)
      assert is_boolean(char.bold?)
      assert is_boolean(char.italic?)
      assert is_boolean(char.monospace?)
      assert %Color.RGB{r: r, g: g, b: b} = char.color
      assert Enum.all?([r, g, b], &is_float/1)
      assert {origin_x, origin_y} = char.origin
      assert is_float(origin_x) and is_float(origin_y)
      assert is_float(char.rotation)
      assert char.advance_width > 0
      assert char.rendered_advance > 0
      assert char.ascent > 0
      assert char.descent < 0
      assert is_nil(char.mcid)
    end

    test "returns each page's chars in reading order" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, c0} = Document.chars(doc, 0)
      assert {:ok, c1} = Document.chars(doc, 1)
      assert Enum.map_join(c0, & &1.text) == "Page One"
      assert Enum.map_join(c1, & &1.text) == "Page Two"
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.chars(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.chars(doc, -1) end
    end
  end

  describe "chars!/2" do
    test "returns the chars for a valid page" do
      doc = Document.open!(@valid_pdf)
      assert [%Char{text: "P"} | _] = Document.chars!(doc, 1)
    end

    test "raises RuntimeError for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.chars!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.chars!(doc, :first) end
    end
  end

  describe "Char inspect/1" do
    test "renders the text, page, and baseline origin" do
      doc = Document.open!(@valid_pdf)
      [char | _] = Document.chars!(doc, 0)
      assert inspect(char) == ~s(#PdfElixide.Document.Char<"P" @ p0 72.0,720.0>)
    end
  end

  describe "spans/1" do
    test "returns {:ok, spans} for every page as a flat list" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, spans} = Document.spans(doc)
      assert Enum.all?(spans, &match?(%Span{}, &1))
      assert Enum.map(spans, & &1.text) == ["Page One", "Page Two", "Page Three"]
    end

    test "length equals the sum of the per-page span counts" do
      doc = Document.open!(@valid_pdf)
      {:ok, all} = Document.spans(doc)

      per_page_total =
        0..(Document.page_count!(doc) - 1)//1
        |> Enum.map(fn i -> length(elem(Document.spans(doc, i), 1)) end)
        |> Enum.sum()

      assert length(all) == per_page_total
    end

    test "each span carries its zero-based page index" do
      doc = Document.open!(@valid_pdf)
      {:ok, spans} = Document.spans(doc)
      assert spans |> Enum.map(& &1.page) |> Enum.uniq() == [0, 1, 2]
    end
  end

  describe "spans!/1" do
    test "returns the flat span list of the whole document" do
      doc = Document.open!(@valid_pdf)
      spans = Document.spans!(doc)
      assert Enum.all?(spans, &match?(%Span{}, &1))
      assert Enum.any?(spans, &(&1.text == "Page Three"))
    end
  end

  describe "spans/2" do
    test "returns {:ok, spans} carrying text, bbox, font and text-state metadata" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, [%Span{} = span | _]} = Document.spans(doc, 0)

      assert span.text == "Page One"
      assert span.page == 0
      assert %Rect{} = span.bbox
      assert span.bbox.width > 0
      assert span.bbox.height > 0
      assert is_float(span.font_size)
      assert is_binary(span.font)
      assert is_integer(span.font_weight)
      assert is_boolean(span.bold?)
      assert is_boolean(span.italic?)
      assert is_boolean(span.monospace?)
      assert %Color.RGB{r: r, g: g, b: b} = span.color
      assert Enum.all?([r, g, b], &is_float/1)
      assert is_float(span.rotation)
      assert is_float(span.char_spacing)
      assert is_float(span.word_spacing)
      assert span.horizontal_scaling == 100.0
      assert is_float(span.text_rise)
      assert is_nil(span.heading_level)
      assert is_nil(span.mcid)
    end

    test "returns each page's spans" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, s0} = Document.spans(doc, 0)
      assert {:ok, s1} = Document.spans(doc, 1)
      assert Enum.map(s0, & &1.text) == ["Page One"]
      assert Enum.map(s1, & &1.text) == ["Page Two"]
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.spans(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.spans(doc, -1) end
    end
  end

  describe "spans!/2" do
    test "returns the spans for a valid page" do
      doc = Document.open!(@valid_pdf)
      assert [%Span{text: "Page Two"}] = Document.spans!(doc, 1)
    end

    test "raises RuntimeError for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.spans!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.spans!(doc, :first) end
    end
  end

  describe "Span inspect/1" do
    test "renders the text, page, and bounding-box origin" do
      doc = Document.open!(@valid_pdf)
      [span | _] = Document.spans!(doc, 0)
      assert inspect(span) == ~s(#PdfElixide.Document.Span<"Page One" @ p0 72.0,720.0>)
    end
  end

  describe "paths/1" do
    test "returns {:ok, paths} for every page as a flat list of structs" do
      doc = Document.open!(@table_pdf)
      assert {:ok, paths} = Document.paths(doc)
      assert paths != []
      assert Enum.all?(paths, &match?(%Document.Path{}, &1))
    end

    test "length equals the sum of the per-page path counts" do
      doc = Document.open!(@table_pdf)
      {:ok, all} = Document.paths(doc)

      per_page_total =
        0..(Document.page_count!(doc) - 1)//1
        |> Enum.map(fn i -> length(elem(Document.paths(doc, i), 1)) end)
        |> Enum.sum()

      assert length(all) == per_page_total
    end

    test "each path carries its zero-based page index" do
      doc = Document.open!(@table_pdf)
      {:ok, paths} = Document.paths(doc)
      assert Enum.all?(paths, &(&1.page == 0))
    end
  end

  describe "paths!/1" do
    test "returns the flat path list of the whole document" do
      doc = Document.open!(@table_pdf)
      paths = Document.paths!(doc)
      assert Enum.all?(paths, &match?(%Document.Path{}, &1))
    end
  end

  describe "paths/2" do
    test "returns {:ok, paths} carrying operations, bbox, colors and stroke style" do
      doc = Document.open!(@table_pdf)
      assert {:ok, [%Document.Path{} = path | _]} = Document.paths(doc, 0)

      assert path.page == 0
      assert %Rect{} = path.bbox
      assert [{:move_to, mx, my} | _] = path.operations
      assert is_float(mx) and is_float(my)
      assert Enum.any?(path.operations, &match?({:line_to, _, _}, &1))
      assert %Color.RGB{r: r, g: g, b: b} = path.stroke_color
      assert Enum.all?([r, g, b], &is_float/1)
      assert is_nil(path.fill_color) or match?(%Color.RGB{}, path.fill_color)
      assert is_float(path.stroke_width)
      assert path.line_cap in [:butt, :round, :square]
      assert path.line_join in [:miter, :round, :bevel]
      assert is_nil(path.dash_pattern) or match?({_, _}, path.dash_pattern)
      assert is_nil(path.layer) or is_binary(path.layer)
    end

    test "returns {:ok, []} for a page with no vector graphics" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Document.paths(doc, 0)
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.paths(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.paths(doc, -1) end
    end
  end

  describe "paths!/2" do
    test "returns the paths for a valid page" do
      doc = Document.open!(@table_pdf)
      assert [%Document.Path{} | _] = Document.paths!(doc, 0)
    end

    test "raises Error for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.paths!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.paths!(doc, :first) end
    end
  end

  describe "Path inspect/1" do
    test "renders the page index and operation count" do
      doc = Document.open!(@table_pdf)
      [path | _] = Document.paths!(doc, 0)
      assert inspect(path) == "#PdfElixide.Document.Path<p0 2 ops>"
    end
  end

  describe "rects/1" do
    test "returns {:ok, rects} for every page as a flat list of structs" do
      doc = Document.open!(@vector_shapes_pdf)
      assert {:ok, rects} = Document.rects(doc)
      assert rects != []
      assert Enum.all?(rects, &match?(%Document.Path{}, &1))
    end

    test "length equals the sum of the per-page rect counts" do
      doc = Document.open!(@vector_shapes_pdf)
      {:ok, all} = Document.rects(doc)

      per_page_total =
        0..(Document.page_count!(doc) - 1)//1
        |> Enum.map(fn i -> length(elem(Document.rects(doc, i), 1)) end)
        |> Enum.sum()

      assert length(all) == per_page_total
    end

    test "each rect carries its zero-based page index" do
      doc = Document.open!(@vector_shapes_pdf)
      {:ok, rects} = Document.rects(doc)
      assert Enum.map(rects, & &1.page) == [0, 0, 0, 3, 3]
    end
  end

  describe "rects!/1" do
    test "returns the flat rect list of the whole document" do
      doc = Document.open!(@vector_shapes_pdf)
      rects = Document.rects!(doc)
      assert Enum.all?(rects, &match?(%Document.Path{}, &1))
    end
  end

  describe "rects/2" do
    test "returns {:ok, rects} carrying operations, bbox, colors and stroke style" do
      doc = Document.open!(@vector_shapes_pdf)
      assert {:ok, [%Document.Path{} = rect | _] = rects} = Document.rects(doc, 0)

      assert length(rects) == 3
      assert rect.page == 0
      assert %Rect{x: 50.0, y: 700.0, width: 100.0, height: 40.0} = rect.bbox
      assert rect.operations == [{:rectangle, 50.0, 700.0, 100.0, 40.0}]
      assert %Color.RGB{} = rect.fill_color
      assert is_float(rect.stroke_width)
      assert rect.line_cap in [:butt, :round, :square]
      assert rect.line_join in [:miter, :round, :bevel]
    end

    test "returns {:ok, []} for a page whose paths are all lines" do
      doc = Document.open!(@vector_shapes_pdf)
      assert {:ok, []} = Document.rects(doc, 1)
    end

    test "returns {:ok, []} for a page with no vector graphics" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Document.rects(doc, 0)
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.rects(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.rects(doc, -1) end
    end
  end

  describe "rects!/2" do
    test "returns the rects for a valid page" do
      doc = Document.open!(@vector_shapes_pdf)
      assert [%Document.Path{} | _] = Document.rects!(doc, 0)
    end

    test "raises Error for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.rects!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.rects!(doc, :first) end
    end
  end

  describe "lines/1" do
    test "returns {:ok, lines} for every page as a flat list of structs" do
      doc = Document.open!(@table_pdf)
      assert {:ok, lines} = Document.lines(doc)
      assert lines != []
      assert Enum.all?(lines, &match?(%Document.Path{}, &1))
    end

    test "length equals the sum of the per-page line counts" do
      doc = Document.open!(@vector_shapes_pdf)
      {:ok, all} = Document.lines(doc)

      per_page_total =
        0..(Document.page_count!(doc) - 1)//1
        |> Enum.map(fn i -> length(elem(Document.lines(doc, i), 1)) end)
        |> Enum.sum()

      assert length(all) == per_page_total
    end

    test "each line carries its zero-based page index" do
      doc = Document.open!(@vector_shapes_pdf)
      {:ok, lines} = Document.lines(doc)
      assert Enum.map(lines, & &1.page) == [1, 1]
    end
  end

  describe "lines!/1" do
    test "returns the flat line list of the whole document" do
      doc = Document.open!(@table_pdf)
      lines = Document.lines!(doc)
      assert Enum.all?(lines, &match?(%Document.Path{}, &1))
    end
  end

  describe "lines/2" do
    test "returns {:ok, lines} carrying operations, bbox and stroke style" do
      doc = Document.open!(@table_pdf)
      assert {:ok, [%Document.Path{} = line | _] = lines} = Document.lines(doc, 0)

      assert length(lines) == 3
      assert line.page == 0
      assert %Rect{} = line.bbox
      assert [{:move_to, _, _}, {:line_to, _, _}] = line.operations
      assert %Color.RGB{} = line.stroke_color
      assert is_float(line.stroke_width)
    end

    test "returns {:ok, []} for a page whose paths are all rectangles" do
      doc = Document.open!(@vector_shapes_pdf)
      assert {:ok, []} = Document.lines(doc, 0)
    end

    test "returns {:ok, []} for a page with no vector graphics" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Document.lines(doc, 0)
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.lines(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.lines(doc, -1) end
    end
  end

  describe "lines!/2" do
    test "returns the lines for a valid page" do
      doc = Document.open!(@table_pdf)
      assert [%Document.Path{} | _] = Document.lines!(doc, 0)
    end

    test "raises Error for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.lines!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.lines!(doc, :first) end
    end
  end

  describe "fonts/1" do
    test "returns {:ok, fonts} for every page as a flat list of structs" do
      doc = Document.open!(@fonts_pdf)
      assert {:ok, fonts} = Document.fonts(doc)
      assert fonts != []
      assert Enum.all?(fonts, &match?(%Document.Font{}, &1))
    end

    test "length equals the sum of the per-page font counts" do
      doc = Document.open!(@fonts_pdf)
      {:ok, all} = Document.fonts(doc)

      per_page_total =
        0..(Document.page_count!(doc) - 1)//1
        |> Enum.map(fn i -> length(elem(Document.fonts(doc, i), 1)) end)
        |> Enum.sum()

      assert length(all) == per_page_total
    end

    test "each font carries its zero-based page index" do
      doc = Document.open!(@fonts_pdf)
      {:ok, fonts} = Document.fonts(doc)
      assert Enum.all?(fonts, &(&1.page in 0..1))
      assert fonts |> Enum.map(& &1.page) |> Enum.into(MapSet.new()) == MapSet.new([0, 1])
    end
  end

  describe "fonts!/1" do
    test "returns the flat font list of the whole document" do
      doc = Document.open!(@fonts_pdf)
      fonts = Document.fonts!(doc)
      assert Enum.all?(fonts, &match?(%Document.Font{}, &1))
    end
  end

  describe "fonts/2" do
    test "returns {:ok, fonts} carrying metadata, and distinguishes embedded fonts" do
      doc = Document.open!(@fonts_pdf)
      assert {:ok, fonts} = Document.fonts(doc, 0)

      assert Enum.all?(fonts, fn font ->
               font.page == 0 and is_binary(font.resource_name) and is_binary(font.base_font) and
                 is_binary(font.subtype) and is_boolean(font.embedded?) and
                 is_boolean(font.subset?) and is_boolean(font.bold?) and is_boolean(font.italic?) and
                 (is_nil(font.weight) or is_integer(font.weight)) and is_reference(font.ref)
             end)

      # The embedded, subsetted TrueType/OpenType font.
      embedded = Enum.find(fonts, & &1.embedded?)
      assert %Document.Font{base_font: "Arial", subtype: "Type0"} = embedded
      assert embedded.subset?
      assert embedded.encoding == :identity

      # The core standard-14 font: not embedded, with a named base encoding.
      standard = Enum.find(fonts, &(not &1.embedded?))
      assert %Document.Font{base_font: "Helvetica", subtype: "Type1"} = standard
      refute standard.subset?
      assert standard.encoding == {:standard, "WinAnsiEncoding"}
    end

    test "returns {:ok, []} for a page that references no fonts" do
      doc = Document.open!(@form_pdf)
      assert {:ok, []} = Document.fonts(doc, 0)
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.fonts(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.fonts(doc, -1) end
    end
  end

  describe "fonts!/2" do
    test "returns the fonts for a valid page" do
      doc = Document.open!(@fonts_pdf)
      assert [%Document.Font{} | _] = Document.fonts!(doc, 0)
    end

    test "raises Error for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.fonts!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.fonts!(doc, :first) end
    end
  end

  describe "Font.data/1" do
    test "returns the raw embedded font-program bytes for an embedded font" do
      embedded =
        Document.open!(@fonts_pdf) |> Document.fonts!(0) |> Enum.find(& &1.embedded?)

      assert {:ok, bytes} = Document.Font.data(embedded)
      assert is_binary(bytes)
      assert byte_size(bytes) > 0
      # A valid sfnt (TrueType/OpenType) wrapper starts with a known version tag.
      assert binary_part(bytes, 0, 4) in [<<0, 1, 0, 0>>, "OTTO", "true", "ttcf"]
    end

    test "returns {:ok, nil} for a non-embedded font" do
      standard =
        Document.open!(@fonts_pdf) |> Document.fonts!(0) |> Enum.find(&(not &1.embedded?))

      assert {:ok, nil} = Document.Font.data(standard)
    end

    test "data!/1 returns the bytes directly" do
      embedded =
        Document.open!(@fonts_pdf) |> Document.fonts!(0) |> Enum.find(& &1.embedded?)

      assert is_binary(Document.Font.data!(embedded))
    end
  end

  describe "Font inspect/1" do
    test "renders the page index, base font and subtype" do
      embedded =
        Document.open!(@fonts_pdf) |> Document.fonts!(0) |> Enum.find(& &1.embedded?)

      assert inspect(embedded) == "#PdfElixide.Document.Font<p0 Arial (Type0)>"
    end
  end

  describe "images/1" do
    test "returns {:ok, images} for every page as a flat list of structs" do
      doc = Document.open!(@image_pdf)
      assert {:ok, images} = Document.images(doc)
      assert images != []
      assert Enum.all?(images, &match?(%Document.Image{}, &1))
    end

    test "length equals the sum of the per-page image counts" do
      doc = Document.open!(@image_pdf)
      {:ok, all} = Document.images(doc)

      per_page_total =
        0..(Document.page_count!(doc) - 1)//1
        |> Enum.map(fn i -> length(elem(Document.images(doc, i), 1)) end)
        |> Enum.sum()

      assert length(all) == per_page_total
    end

    test "each image carries its zero-based page index" do
      doc = Document.open!(@image_pdf)
      {:ok, images} = Document.images(doc)
      assert Enum.all?(images, &(&1.page == 0))
    end
  end

  describe "images!/1" do
    test "returns the flat image list of the whole document" do
      doc = Document.open!(@image_pdf)
      images = Document.images!(doc)
      assert Enum.all?(images, &match?(%Document.Image{}, &1))
    end
  end

  describe "images/2" do
    test "returns {:ok, images} carrying a handle, source format, dimensions and metadata" do
      doc = Document.open!(@image_pdf)
      assert {:ok, [%Document.Image{} = image | _]} = Document.images(doc, 0)

      assert image.page == 0
      assert image.format in [:jpeg, :raw]
      assert is_reference(image.ref)
      assert image.width > 0
      assert image.height > 0
      assert is_nil(image.bbox) or match?(%Rect{}, image.bbox)
      assert is_atom(image.color_space)
      assert is_integer(image.bits_per_component)
      assert is_integer(image.rotation_degrees)
    end

    test "reports :jpeg source format for a JPEG-stored image" do
      doc = Document.open!(@image_jpeg_pdf)
      assert {:ok, [%Document.Image{format: :jpeg} | _]} = Document.images(doc, 0)
    end

    test "returns {:ok, []} for a page with no images" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Document.images(doc, 0)
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.images(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.images(doc, -1) end
    end
  end

  describe "images!/2" do
    test "returns the images for a valid page" do
      doc = Document.open!(@image_pdf)
      assert [%Document.Image{} | _] = Document.images!(doc, 0)
    end

    test "raises Error for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.images!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.images!(doc, :first) end
    end
  end

  describe "Image.to_binary/2" do
    test "defaults to PNG bytes" do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)

      assert {:ok, <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>} =
               Document.Image.to_binary(image)
    end

    test "encodes JPEG bytes when format: :jpeg" do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)
      assert {:ok, <<255, 216, 255, _::binary>>} = Document.Image.to_binary(image, format: :jpeg)
    end

    test "passes the original bytes through for a JPEG-stored image" do
      [image | _] = Document.open!(@image_jpeg_pdf) |> Document.images!(0)
      assert image.format == :jpeg
      assert {:ok, <<255, 216, 255, _::binary>>} = Document.Image.to_binary(image, format: :jpeg)

      # Byte-identical to the stored blob: the NIF hands back a borrow of it
      # rather than re-encoding or cloning.
      assert {:ok, {:jpeg, stored}} = Document.Image.data(image)
      assert {:ok, ^stored} = Document.Image.to_binary(image, format: :jpeg)
    end

    test "raises ArgumentError for an unsupported format" do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)
      assert_raise ArgumentError, fn -> Document.Image.to_binary(image, format: :gif) end
    end

    test "to_binary!/2 returns the bytes directly" do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)
      assert <<137, 80, 78, 71, _::binary>> = Document.Image.to_binary!(image)
    end
  end

  describe "Image.data/1" do
    test "returns the original JPEG blob for a JPEG-stored image" do
      [image | _] = Document.open!(@image_jpeg_pdf) |> Document.images!(0)
      assert image.format == :jpeg
      assert {:ok, {:jpeg, <<255, 216, 255, _::binary>>}} = Document.Image.data(image)
    end

    test "returns raw pixels with their layout for a raw-stored image" do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)
      assert image.format == :raw
      assert {:ok, {:raw, pixels, pixel_format}} = Document.Image.data(image)
      assert pixel_format in [:rgb, :grayscale, :cmyk]
      assert is_binary(pixels)
      # DeviceRGB fixture: one byte per component, three components per pixel.
      assert pixel_format == :rgb
      assert byte_size(pixels) == image.width * image.height * 3
    end

    test "data!/1 returns the raw data directly" do
      [image | _] = Document.open!(@image_jpeg_pdf) |> Document.images!(0)
      assert {:jpeg, <<255, 216, 255, _::binary>>} = Document.Image.data!(image)
    end
  end

  describe "Image.save/3" do
    @describetag :tmp_dir

    test "infers PNG from a .png path", %{tmp_dir: tmp_dir} do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)
      path = Path.join(tmp_dir, "out.png")
      assert :ok = Document.Image.save(image, path)
      assert <<137, 80, 78, 71, _::binary>> = File.read!(path)
    end

    test "infers JPEG from a .jpg path", %{tmp_dir: tmp_dir} do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)
      path = Path.join(tmp_dir, "out.jpg")
      assert :ok = Document.Image.save(image, path)
      assert <<255, 216, 255, _::binary>> = File.read!(path)
    end

    test "the :format option overrides the extension", %{tmp_dir: tmp_dir} do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)
      path = Path.join(tmp_dir, "thumb.bin")
      assert :ok = Document.Image.save(image, path, format: :jpeg)
      assert <<255, 216, 255, _::binary>> = File.read!(path)
    end

    test "raises ArgumentError for an unknown extension with no :format", %{tmp_dir: tmp_dir} do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)
      path = Path.join(tmp_dir, "out.bmp")
      assert_raise ArgumentError, fn -> Document.Image.save(image, path) end
    end

    test "save!/3 returns :ok", %{tmp_dir: tmp_dir} do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)
      path = Path.join(tmp_dir, "bang.png")
      assert :ok = Document.Image.save!(image, path)
      assert File.exists?(path)
    end
  end

  describe "Image inspect/1" do
    test "renders the page index, dimensions and source format" do
      doc = Document.open!(@image_pdf)
      [image | _] = Document.images!(doc, 0)

      assert inspect(image) ==
               "#PdfElixide.Document.Image<p0 #{image.width}x#{image.height} #{image.format}>"
    end
  end

  describe "tables/2" do
    test "returns {:ok, tables} carrying geometry, grid shape and rows" do
      doc = Document.open!(@table_pdf)
      assert {:ok, [%Table{} = table]} = Document.tables(doc, 0)

      assert table.page == 0
      assert table.col_count == 4
      assert length(table.rows) == 5
      assert table.real_grid?
      assert is_boolean(table.has_header?)
      assert %Rect{} = table.bbox
      assert table.bbox.width > 0
      assert table.bbox.height > 0
    end

    test "keeps each row's cells aligned with their values" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      grid = Enum.map(table.rows, fn row -> Enum.map(row.cells, & &1.text) end)

      assert ["Age", "0.042", "0.011", "0.001"] in grid
      assert ["Diabetes", "0.694", "0.233", "0.003"] in grid
    end

    test "cells carry their geometry, spans and grid placement" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)
      [%Table.Row{} = row | _] = table.rows
      [%Table.Cell{} = cell | _] = row.cells

      assert cell.text == "Age"
      assert cell.colspan == 1
      assert cell.rowspan == 1
      assert is_boolean(cell.header?)
      assert cell.mcids == []
      assert %Rect{} = cell.bbox
      assert [%Span{text: "Age", page: 0}] = cell.spans
    end

    test "returns {:ok, []} for a page with no table" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Document.tables(doc, 0)
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@table_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.tables(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@table_pdf)
      assert_raise FunctionClauseError, fn -> Document.tables(doc, -1) end
    end
  end

  describe "tables/1" do
    test "returns {:ok, tables} for every page as a flat list" do
      doc = Document.open!(@table_pdf)
      assert {:ok, [%Table{page: 0}]} = Document.tables(doc)
    end

    test "length equals the sum of the per-page table counts" do
      doc = Document.open!(@table_pdf)
      {:ok, all} = Document.tables(doc)

      per_page_total =
        0..(Document.page_count!(doc) - 1)//1
        |> Enum.map(fn i -> length(elem(Document.tables(doc, i), 1)) end)
        |> Enum.sum()

      assert length(all) == per_page_total
    end

    test "returns an empty list for a document with no tables" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Document.tables(doc)
    end
  end

  describe "tables!/1" do
    test "returns the flat table list of the whole document" do
      doc = Document.open!(@table_pdf)
      assert [%Table{col_count: 4}] = Document.tables!(doc)
    end
  end

  describe "tables!/2" do
    test "returns the tables for a valid page" do
      doc = Document.open!(@table_pdf)
      assert [%Table{page: 0}] = Document.tables!(doc, 0)
    end

    test "raises RuntimeError for an out-of-range page index" do
      doc = Document.open!(@table_pdf)
      assert_raise Error, fn -> Document.tables!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@table_pdf)
      assert_raise FunctionClauseError, fn -> Document.tables!(doc, :first) end
    end
  end

  describe "Table.cell/3" do
    test "returns the cell at a zero-based row and column" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert %Table.Cell{text: "Age"} = Table.cell(table, 0, 0)
      assert %Table.Cell{text: "0.001"} = Table.cell(table, 0, 3)
      assert %Table.Cell{text: "Sex"} = Table.cell(table, 1, 0)
      assert %Table.Cell{text: "0.003"} = Table.cell(table, 4, 3)
    end

    test "returns nil for an out-of-range row or column" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert Table.cell(table, 99, 0) == nil
      assert Table.cell(table, 0, 99) == nil
      assert Table.cell(table, 5, 4) == nil
    end

    test "raises FunctionClauseError for a negative row or column" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert_raise FunctionClauseError, fn -> Table.cell(table, -1, 0) end
      assert_raise FunctionClauseError, fn -> Table.cell(table, 0, -1) end
      assert_raise FunctionClauseError, fn -> Table.cell(table, :first, 0) end
    end

    test "indexes by position, ignoring colspan" do
      table = spanning_table()

      assert %Table.Cell{text: "A", colspan: 2} = Table.cell(table, 0, 0)
      assert %Table.Cell{text: "B"} = Table.cell(table, 0, 1)
      assert Table.cell(table, 0, 2) == nil
      assert table.col_count == 3
    end
  end

  describe "Table.cell_text/3" do
    test "returns the text of the cell at a zero-based row and column" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert Table.cell_text(table, 0, 0) == "Age"
      assert Table.cell_text(table, 0, 3) == "0.001"
      assert Table.cell_text(table, 4, 0) == "Diabetes"
    end

    test "returns nil for an out-of-range row or column" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert Table.cell_text(table, 99, 0) == nil
      assert Table.cell_text(table, 0, 99) == nil
    end

    test "stops at the last stored cell of a row that merged columns" do
      table = spanning_table()

      assert Enum.map(0..3, &Table.cell_text(table, 0, &1)) == ["A", "B", nil, nil]
    end
  end

  describe "Table.row/2 and Table.row_count/1" do
    test "returns the row at a zero-based index" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert %Table.Row{} = row = Table.row(table, 0)
      assert length(row.cells) == 4
      assert Table.row(table, 0) == hd(table.rows)
    end

    test "returns nil for an out-of-range index and raises for a negative one" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert Table.row(table, 99) == nil
      assert_raise FunctionClauseError, fn -> Table.row(table, -1) end
    end

    test "row_count/1 counts the rows" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert Table.row_count(table) == 5
      assert Table.row_count(%{table | rows: []}) == 0
    end
  end

  describe "Table.Row.cell/2 and Table.Row.cell_text/2" do
    test "index by position within a single row" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)
      row = Table.row(table, 0)

      assert %Table.Cell{text: "Age"} = Table.Row.cell(row, 0)
      assert Table.Row.cell_text(row, 1) == "0.042"
      assert Table.Row.cell(row, 99) == nil
      assert Table.Row.cell_text(row, 99) == nil
      assert_raise FunctionClauseError, fn -> Table.Row.cell(row, -1) end
    end
  end

  describe "Table Enumerable" do
    test "enumerates the rows of a table and the cells of a row" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert Enum.count(table) == 5
      assert Enum.map(table, &Enum.count/1) == [4, 4, 4, 4, 4]

      grid = Enum.map(table, fn row -> Enum.map(row, & &1.text) end)
      assert ["Age", "0.042", "0.011", "0.001"] in grid
      assert ["Diabetes", "0.694", "0.233", "0.003"] in grid
    end

    test "supports slicing and membership" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert %Table.Row{} = Enum.at(table, 1)
      assert Enum.take(table, 2) == Enum.take(table.rows, 2)
      assert Enum.slice(table, 1..2) == Enum.slice(table.rows, 1..2)
      assert Enum.member?(table, Table.row(table, 0))
      refute Enum.member?(table, :not_a_row)

      row = Table.row(table, 0)
      assert Enum.slice(row, 1..2) == Enum.slice(row.cells, 1..2)
      assert Enum.member?(row, Table.Row.cell(row, 0))
    end

    test "agrees with the accessors, including on a row that merged columns" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert Enum.map(table, & &1) == Enum.map(0..4, &Table.row(table, &1))
      row = Table.row(table, 0)
      assert Enum.map(row, & &1) == Enum.map(0..3, &Table.cell(table, 0, &1))

      spanning = spanning_table()
      assert Enum.map(spanning, fn row -> Enum.map(row, & &1.text) end) == [["A", "B"]]
      assert Enum.to_list(Table.row(spanning, 0)) == Enum.map(0..1, &Table.cell(spanning, 0, &1))
    end
  end

  describe "Table inspect/1" do
    test "renders the page and grid shape" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)
      assert inspect(table) == "#PdfElixide.Document.Table<p0 5x4>"
    end

    test "marks a table with an explicit header section" do
      table = %Table{
        page: 2,
        bbox: nil,
        col_count: 3,
        has_header?: true,
        real_grid?: true,
        rows: [],
        ref: nil
      }

      assert inspect(table) == "#PdfElixide.Document.Table<p2 0x3 (header)>"
    end

    test "renders the cell count of a row and the text of a cell" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)
      [row | _] = table.rows
      [cell | _] = row.cells

      assert inspect(row) == "#PdfElixide.Document.Table.Row<4 cells>"
      assert inspect(cell) == ~s(#PdfElixide.Document.Table.Cell<"Age">)
    end
  end

  describe "Table.to_markdown/2" do
    test "renders the table as a Markdown table" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)
      assert {:ok, markdown} = Table.to_markdown(table)

      assert markdown =~ "| Age | 0.042 | 0.011 | 0.001 |"
      assert markdown =~ "|---|---|---|---|"
      assert markdown =~ "| Diabetes | 0.694 | 0.233 | 0.003 |"
      assert String.ends_with?(markdown, "\n")
    end

    test "emits the same block the whole-page conversion emits" do
      # The table goes back to upstream's own converter with the config the
      # document path builds, so rendering one table in isolation must not drift
      # from rendering it as part of its page. This is the assertion that
      # catches such a drift.
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert Document.to_markdown!(doc, 0) =~ String.trim(Table.to_markdown!(table))
    end

    test "renders the first row as a header even without a header section" do
      # Markdown requires a header row, so upstream emits the separator after
      # row 0 whatever :has_header? says — this fixture's is false.
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      refute table.has_header?
      assert [_header, separator | _] = String.split(Table.to_markdown!(table), "\n")
      assert separator == "|---|---|---|---|"
    end

    test "accepts :bold_markers" do
      # Both settings render; they diverge only for a bold span whose text is
      # entirely whitespace, which no fixture table contains.
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert {:ok, conservative} = Table.to_markdown(table, bold_markers: :conservative)
      assert {:ok, aggressive} = Table.to_markdown(table, bold_markers: :aggressive)
      assert conservative == Table.to_markdown!(table)
      assert aggressive =~ "| Age |"
    end

    test "raises for an unknown option" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert_raise ArgumentError, ~r/:detect_headings/, fn ->
        Table.to_markdown(table, detect_headings: false)
      end
    end

    test "raises for a wrongly typed option" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert_raise ArgumentError, ~r/:bold_markers/, fn ->
        Table.to_markdown(table, bold_markers: :nope)
      end
    end

    test "returns {:error, reason} for a closed table" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)
      :ok = Table.close(table)

      assert {:error, %Error{reason: :closed}} = Table.to_markdown(table)
    end

    test "raises for a table that never came from extraction" do
      assert_raise FunctionClauseError, fn -> Table.to_markdown(spanning_table()) end
    end

    test "raises for non-list options" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert_raise FunctionClauseError, fn -> Table.to_markdown(table, :conservative) end
    end
  end

  describe "Table.to_markdown!/2" do
    test "returns the Markdown directly" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert Table.to_markdown!(table) =~ "|---|---|---|---|"
      assert Table.to_markdown!(table, bold_markers: :aggressive) =~ "| Age |"
    end

    test "raises for a closed table" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)
      :ok = Table.close(table)

      assert_raise Error, fn -> Table.to_markdown!(table) end
    end
  end

  describe "Table.to_html/1" do
    test "renders the table as an HTML fragment" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)
      assert {:ok, html} = Table.to_html(table)

      assert String.starts_with?(html, "<table>")
      assert String.ends_with?(html, "</table>\n")
      assert html =~ "<tbody>"
      assert html =~ "<tr><td>Age</td><td>0.042</td><td>0.011</td><td>0.001</td></tr>"
      # No header section was detected, so upstream emits no <thead>/<th> —
      # unlike the Markdown renderer, which promotes the first row regardless.
      refute table.has_header?
      refute html =~ "<thead>"
      refute html =~ "<th>"
    end

    test "emits the same fragment the whole-page conversion emits" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert Document.to_html!(doc, 0) =~ String.trim(Table.to_html!(table))
    end

    test "returns {:error, reason} for a closed table" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)
      :ok = Table.close(table)

      assert {:error, %Error{reason: :closed}} = Table.to_html(table)
    end

    test "raises for a table that never came from extraction" do
      assert_raise FunctionClauseError, fn -> Table.to_html(spanning_table()) end
    end
  end

  describe "Table.to_html!/1" do
    test "returns the HTML directly" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert Table.to_html!(table) =~ "<td>Diabetes</td>"
    end

    test "raises for a closed table" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)
      :ok = Table.close(table)

      assert_raise Error, fn -> Table.to_html!(table) end
    end
  end

  describe "Table.to_text/1" do
    test "renders the grid as space-padded plain text" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)
      assert {:ok, text} = Table.to_text(table)

      lines = String.split(text, "\n", trim: true)
      assert length(lines) == Table.row_count(table)
      assert hd(lines) == "Age       0.042  0.011  0.001"
      assert List.last(lines) == "Diabetes  0.694  0.233  0.003"
    end

    test "returns {:error, reason} for a closed table" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)
      :ok = Table.close(table)

      assert {:error, %Error{reason: :closed}} = Table.to_text(table)
    end

    test "raises for a table that never came from extraction" do
      assert_raise FunctionClauseError, fn -> Table.to_text(spanning_table()) end
    end
  end

  describe "Table.to_text!/1" do
    test "returns the text directly" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert Table.to_text!(table) =~ "Smoker    0.512"
    end

    test "raises for a closed table" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)
      :ok = Table.close(table)

      assert_raise Error, fn -> Table.to_text!(table) end
    end
  end

  describe "Table.close/1 and Table.closed?/1" do
    test "releases the table and reports the state" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      refute Table.closed?(table)
      assert Table.close(table) == :ok
      assert Table.closed?(table)
    end

    test "is idempotent" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      assert Table.close(table) == :ok
      assert Table.close(table) == :ok
      assert Table.closed?(table)
    end

    test "leaves the struct's own rows and cells readable" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)
      :ok = Table.close(table)

      assert Table.cell_text(table, 0, 0) == "Age"
      assert Enum.map(table, fn row -> length(row.cells) end) == [4, 4, 4, 4, 4]
    end
  end

  describe "pages/1" do
    test "returns a lazy handle for every page" do
      doc = Document.open!(@valid_pdf)

      assert [%Page{doc: ^doc, index: 0}, %Page{doc: ^doc, index: 1}, %Page{doc: ^doc, index: 2}] =
               Document.pages(doc)
    end
  end

  describe "Enumerable" do
    test "Enum.count/1 returns the page count" do
      doc = Document.open!(@valid_pdf)
      assert Enum.count(doc) == 3
    end

    test "Enum.at/2 returns the page at a zero-based index" do
      doc = Document.open!(@valid_pdf)
      assert %Page{doc: ^doc, index: 0} = Enum.at(doc, 0)
    end

    test "Enum.at/2 supports negative indexing" do
      doc = Document.open!(@valid_pdf)
      assert %Page{doc: ^doc, index: 2} = Enum.at(doc, -1)
    end

    test "Enum.at/2 returns nil for an out-of-range index" do
      doc = Document.open!(@valid_pdf)
      assert Enum.at(doc, 99) == nil
    end

    test "Enum.to_list/1 matches pages/1" do
      doc = Document.open!(@valid_pdf)
      assert Enum.to_list(doc) == Document.pages(doc)
    end

    test "is iterable page by page" do
      doc = Document.open!(@valid_pdf)
      assert Enum.map(doc, & &1.index) == [0, 1, 2]
    end

    test "Enum.slice/2 returns the requested pages" do
      doc = Document.open!(@valid_pdf)
      assert [%Page{index: 1}, %Page{index: 2}] = Enum.slice(doc, 1..2)
    end

    test "membership is true for an in-range page of the same document" do
      doc = Document.open!(@valid_pdf)
      assert Enum.member?(doc, %Page{doc: doc, index: 2})
    end

    test "membership is false for an out-of-range page or a foreign page" do
      doc = Document.open!(@valid_pdf)
      other = Document.open!(@valid_pdf)
      refute Enum.member?(doc, %Page{doc: doc, index: 99})
      refute Enum.member?(doc, %Page{doc: other, index: 0})
      refute Enum.member?(doc, :not_a_page)
    end
  end

  describe "page/2" do
    test "returns {:ok, page} for a valid index" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, %Page{doc: ^doc, index: 1}} = Document.page(doc, 1)
    end

    test "returns {:error, reason} for an out-of-range index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.page(doc, 99)
    end

    test "reports the same message the NIF does for the same index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range, message: message}} = Document.page(doc, 99)

      # `text/2` reaches `ensure_page_in_range` in the NIF; `page/2` answers from the
      # cached count and formats its own. Both must word it identically.
      assert {:error, %Error{reason: :out_of_range, message: ^message}} = Document.text(doc, 99)

      # Guards the degenerate fix where both sides drift to the same generic string.
      assert message =~ "99"
    end

    test "raises FunctionClauseError for negative index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.page(doc, -1) end
    end
  end

  describe "page!/2" do
    test "returns the page for a valid index" do
      doc = Document.open!(@valid_pdf)
      assert %Page{doc: ^doc, index: 1} = Document.page!(doc, 1)
    end

    test "raises RuntimeError for an out-of-range index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.page!(doc, 99) end
    end
  end

  describe "encrypted?/1" do
    test "returns false for an unencrypted PDF" do
      doc = Document.open!(@valid_pdf)
      refute Document.encrypted?(doc)
    end

    test "returns true for an encrypted PDF" do
      doc = Document.open!(@encrypted_pdf)
      assert Document.encrypted?(doc)
    end
  end

  describe "has_structure_tree?/1" do
    test "returns false for the untagged sample fixture" do
      doc = Document.open!(@valid_pdf)
      refute Document.has_structure_tree?(doc)
    end

    test "returns true for a tagged PDF" do
      doc = Document.open!(@tagged_pdf)
      assert Document.has_structure_tree?(doc)
    end
  end

  describe "has_structure_tree/1" do
    test "returns {:ok, false} for the untagged sample fixture" do
      doc = Document.open!(@valid_pdf)
      assert Document.has_structure_tree(doc) == {:ok, false}
    end

    test "returns {:ok, true} for a tagged PDF" do
      doc = Document.open!(@tagged_pdf)
      assert Document.has_structure_tree(doc) == {:ok, true}
    end

    # The point of the strict variant: the tolerant one collapses every failure
    # into `false`, so a caller who needs to tell "untagged" from "unreadable"
    # has this. No fixture reaches the error branch through the document itself
    # — an encrypted document's catalog still parses — so the closed handle is
    # what pins that the error survives to Elixir at all.
    test "reports a failure the predicate would have swallowed" do
      doc = Document.open!(@tagged_pdf)
      :ok = Document.close(doc)

      assert {:error, %Error{reason: :closed}} = Document.has_structure_tree(doc)
    end
  end

  describe "has_xfa?/1" do
    test "returns false for a plain PDF" do
      doc = Document.open!(@valid_pdf)
      refute Document.has_xfa?(doc)
    end

    test "returns false for a non-XFA AcroForm PDF" do
      doc = Document.open!(@form_pdf)
      refute Document.has_xfa?(doc)
    end

    test "returns true for an XFA PDF reached through an indirect /AcroForm" do
      doc = Document.open!(@xfa_pdf)
      assert Document.has_xfa?(doc)
    end
  end

  describe "has_xfa/1" do
    test "returns {:ok, false} for a plain PDF" do
      doc = Document.open!(@valid_pdf)
      assert Document.has_xfa(doc) == {:ok, false}
    end

    test "returns {:ok, false} for a non-XFA AcroForm PDF" do
      doc = Document.open!(@form_pdf)
      assert Document.has_xfa(doc) == {:ok, false}
    end

    test "returns {:ok, true} for an XFA PDF reached through an indirect /AcroForm" do
      doc = Document.open!(@xfa_pdf)
      assert Document.has_xfa(doc) == {:ok, true}
    end

    test "reports a failure the predicate would have swallowed" do
      doc = Document.open!(@form_pdf)
      :ok = Document.close(doc)

      assert {:error, %Error{reason: :closed}} = Document.has_xfa(doc)
    end
  end

  describe "authenticate/2" do
    test "returns {:ok, true} for an unencrypted PDF" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, true} = Document.authenticate(doc, "anything")
    end

    test "returns {:ok, true} with the correct password" do
      doc = Document.open!(@encrypted_pdf)
      assert {:ok, true} = Document.authenticate(doc, @password)
    end

    test "returns {:ok, false} with the wrong password" do
      doc = Document.open!(@encrypted_pdf)
      assert {:ok, false} = Document.authenticate(doc, "wrong")
    end

    test "raises FunctionClauseError for a non-binary password" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.authenticate(doc, :secret) end
    end
  end

  describe "authenticate!/2" do
    test "returns true with the correct password" do
      doc = Document.open!(@encrypted_pdf)
      assert Document.authenticate!(doc, @password) == true
    end

    test "returns false (does not raise) with the wrong password" do
      doc = Document.open!(@encrypted_pdf)
      assert Document.authenticate!(doc, "wrong") == false
    end
  end

  describe "open/2 with password option" do
    test "opens an encrypted PDF with the correct password" do
      assert {:ok, %Document{}} = Document.open(@encrypted_pdf, password: @password)
    end

    test "returns {:error, _} with the wrong password" do
      assert {:error, %Error{reason: :wrong_password}} =
               Document.open(@encrypted_pdf, password: "wrong")
    end

    test "password: nil is a no-op (unencrypted PDF opens normally)" do
      assert {:ok, %Document{}} = Document.open(@valid_pdf, password: nil)
    end

    test "extracts text after open-with-password" do
      doc = Document.open!(@encrypted_pdf, password: @password)
      assert Document.text!(doc, 0) =~ "Page One"
    end
  end

  describe "from_binary/2 with password option" do
    test "opens an encrypted PDF binary with the correct password" do
      bytes = File.read!(@encrypted_pdf)
      assert {:ok, %Document{}} = Document.from_binary(bytes, password: @password)
    end

    test "returns {:error, _} with the wrong password" do
      bytes = File.read!(@encrypted_pdf)

      assert {:error, %Error{reason: :wrong_password}} =
               Document.from_binary(bytes, password: "wrong")
    end
  end

  # `open/2`'s `:password` and `authenticate/2` reach the same upstream call,
  # which hashes raw bytes and never validates UTF-8, so they must accept and
  # reject exactly the same values. The open option used to decode as a Rust
  # `String`, which rejected a non-UTF-8 password as a `NifMap` field-decode
  # failure — `%Error{reason: :other}` — while `authenticate/2` accepted it.
  describe "non-UTF-8 passwords" do
    test "open/2 accepts a PDFDocEncoded password that is not valid UTF-8" do
      refute String.valid?(@latin1_password)
      assert {:ok, %Document{}} = Document.open(@latin1_pdf, password: @latin1_password)
    end

    test "from_binary/2 accepts the same bytes" do
      bytes = File.read!(@latin1_pdf)
      assert {:ok, %Document{}} = Document.from_binary(bytes, password: @latin1_password)
    end

    test "the UTF-8 spelling of the same password is rejected" do
      assert {:error, %Error{reason: :wrong_password}} =
               Document.open(@latin1_pdf, password: "café")
    end

    test "open/2 and authenticate/2 accept the same bytes" do
      doc = Document.open!(@latin1_pdf, password: @latin1_password)
      assert {:ok, true} = Document.authenticate(doc, @latin1_password)
    end

    test "open/2 and authenticate/2 reject the same bytes" do
      assert {:error, %Error{reason: :wrong_password}} =
               Document.open(@encrypted_pdf, password: <<0xFF, 0xFE>>)

      doc = Document.open!(@encrypted_pdf)
      assert {:ok, false} = Document.authenticate(doc, <<0xFF, 0xFE>>)
    end

    test "extracts text after open-with-a-byte-password" do
      doc = Document.open!(@latin1_pdf, password: @latin1_password)
      assert Document.text!(doc, 0) =~ "Page One"
    end
  end

  describe "open!/2 and from_binary!/2 bang variants" do
    test "open! raises with the wrong-password message" do
      assert_raise Error, "Authentication failed: wrong password", fn ->
        Document.open!(@encrypted_pdf, password: "wrong")
      end
    end

    test "from_binary! raises with the wrong-password message" do
      bytes = File.read!(@encrypted_pdf)

      assert_raise Error, "Authentication failed: wrong password", fn ->
        Document.from_binary!(bytes, password: "wrong")
      end
    end
  end

  describe "structured error reasons" do
    test "wrong password carries reason :wrong_password" do
      assert {:error, %Error{reason: :wrong_password, message: message}} =
               Document.open(@encrypted_pdf, password: "wrong")

      assert is_binary(message)
    end

    test "invalid PDF bytes carry reason :invalid_pdf" do
      assert {:error, %Error{reason: :invalid_pdf}} = Document.from_binary("not a pdf")
    end

    test "an out-of-range page index carries reason :out_of_range" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.text(doc, 99)
    end

    test "bang variants raise PdfElixide.Error with the reason preserved" do
      doc = Document.open!(@valid_pdf)

      error =
        assert_raise Error, fn -> Document.text!(doc, 99) end

      assert error.reason == :out_of_range
    end
  end

  describe "outline/1" do
    test "returns the top-level outline items as a tree of structs" do
      doc = Document.open!(@outline_pdf)
      assert {:ok, [%OutlineItem{} = ch1, %OutlineItem{} = ch2]} = Document.outline(doc)

      assert ch1.title == "Chapter 1"
      assert ch1.dest == {:page, 0}

      assert ch2.title == "Chapter 2"
      assert ch2.dest == {:page, 2}
      assert ch2.children == []
    end

    test "nests child items under their parent, resolving destinations to pages" do
      doc = Document.open!(@outline_pdf)
      {:ok, [ch1, _ch2]} = Document.outline(doc)

      assert [%OutlineItem{} = section] = ch1.children
      assert section.title == "Section 1.1"
      assert section.dest == {:page, 1}
      assert section.children == []
    end

    test "returns {:ok, []} for a document with no outline" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Document.outline(doc)
    end
  end

  describe "outline!/1" do
    test "returns the outline items directly" do
      doc = Document.open!(@outline_pdf)

      assert [%OutlineItem{title: "Chapter 1"}, %OutlineItem{title: "Chapter 2"}] =
               Document.outline!(doc)
    end

    test "returns [] for a document with no outline" do
      doc = Document.open!(@valid_pdf)
      assert [] = Document.outline!(doc)
    end
  end

  describe "OutlineItem inspect/1" do
    test "renders the title and child count" do
      doc = Document.open!(@outline_pdf)
      [ch1, _ch2] = Document.outline!(doc)
      assert inspect(ch1) == "#PdfElixide.Document.OutlineItem<\"Chapter 1\" 1 child>"
    end
  end

  describe "annotations/1" do
    test "returns every page's annotations as a flat list of structs" do
      doc = Document.open!(@annotations_pdf)
      assert {:ok, annotations} = Document.annotations(doc)
      assert annotations != []
      assert Enum.all?(annotations, &match?(%Annotation{}, &1))
    end

    test "length equals the sum of the per-page annotation counts" do
      doc = Document.open!(@annotations_pdf)
      {:ok, all} = Document.annotations(doc)

      per_page_total =
        0..(Document.page_count!(doc) - 1)//1
        |> Enum.map(fn i -> length(elem(Document.annotations(doc, i), 1)) end)
        |> Enum.sum()

      assert length(all) == per_page_total
    end

    test "each annotation carries its zero-based page index" do
      doc = Document.open!(@annotations_pdf)
      {:ok, annotations} = Document.annotations(doc)
      assert Enum.all?(annotations, &(&1.page == 0))
    end
  end

  describe "annotations!/1" do
    test "returns the flat annotation list of the whole document" do
      doc = Document.open!(@annotations_pdf)
      annotations = Document.annotations!(doc)
      assert Enum.all?(annotations, &match?(%Annotation{}, &1))
    end
  end

  describe "annotations/2" do
    test "decodes a text (sticky note) annotation with its metadata" do
      doc = Document.open!(@annotations_pdf)
      {:ok, annotations} = Document.annotations(doc, 0)

      text = Enum.find(annotations, &(&1.subtype == :text))
      assert %Annotation{type: "Annot", raw_subtype: "Text"} = text
      assert text.contents == "Hello note"
      assert text.author == "Alice"
      assert text.creation_date == "D:20240101000000Z"
      assert text.modification_date == "D:20240102000000Z"
      assert text.color == %Color.RGB{r: 1.0, g: 0.0, b: 0.0}
      assert %Rect{x: 100.0, y: 700.0, width: 20.0, height: 20.0} = text.rect

      # /F 4 decodes to only the PRINT bit, mirroring Permissions' :raw field.
      assert text.flags.print
      refute text.flags.hidden
      assert text.flags.raw == 4
    end

    test "decodes a link annotation's URI action" do
      doc = Document.open!(@annotations_pdf)
      {:ok, annotations} = Document.annotations(doc, 0)

      link = Enum.find(annotations, &(&1.subtype == :link))
      assert link.action == {:uri, "https://example.com"}
      assert link.destination == nil
      assert link.border == [0.0, 0.0, 1.0]
    end

    test "decodes a highlight annotation's quad points, color, and opacity" do
      doc = Document.open!(@annotations_pdf)
      {:ok, annotations} = Document.annotations(doc, 0)

      highlight = Enum.find(annotations, &(&1.subtype == :highlight))
      assert highlight.quad_points == [[100.0, 620.0, 300.0, 620.0, 100.0, 600.0, 300.0, 600.0]]
      assert highlight.color == %Color.RGB{r: 1.0, g: 1.0, b: 0.0}
      assert highlight.opacity == 0.5
    end

    test "returns {:ok, []} for a page with no annotations" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Document.annotations(doc, 0)
    end

    test "decodes a one-component color as Gray and a four-component /IC as CMYK" do
      annotation = annotation_with_contents("Gray border, CMYK interior")

      assert annotation.color == %Color.Gray{gray: 0.5}
      assert annotation.interior_color == %Color.CMYK{c: 0.0, m: 1.0, y: 1.0, k: 0.0}
    end

    test "decodes a four-component color as CMYK" do
      annotation = annotation_with_contents("CMYK border")

      assert annotation.color == %Color.CMYK{c: 0.0, m: 1.0, y: 1.0, k: 0.0}
      assert annotation.interior_color == nil
    end

    test "preserves a color of unidentifiable arity verbatim" do
      annotation = annotation_with_contents("Unidentifiable colourspace")

      assert annotation.color == %Color.Unknown{components: [0.25, 0.75]}
    end

    # Upstream pdf_oxide collapses an empty /C array to "no entry"
    # (parse_number_array in its src/annotations.rs), so an explicitly empty
    # color is indistinguishable from an absent one. This pins that behavior; if
    # upstream changes, this test is the tripwire.
    test "surfaces an empty color array as nil" do
      annotation = annotation_with_contents("Explicitly not painted")

      assert annotation.color == nil
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.annotations(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.annotations(doc, -1) end
    end
  end

  describe "annotations!/2" do
    test "returns the annotations for a valid page" do
      doc = Document.open!(@annotations_pdf)
      assert [%Annotation{} | _] = Document.annotations!(doc, 0)
    end

    test "raises Error for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.annotations!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.annotations!(doc, :first) end
    end
  end

  describe "Annotation inspect/1" do
    test "renders the page index and subtype" do
      doc = Document.open!(@annotations_pdf)
      [text | _] = Document.annotations!(doc, 0)
      assert inspect(text) == "#PdfElixide.Document.Annotation<p0 :text>"
    end
  end

  describe "metadata/1" do
    test "reads the Info dictionary fields" do
      doc = Document.open!(@metadata_pdf)

      assert {:ok, %Metadata{} = meta} = Document.metadata(doc)
      assert meta.title == "Test Title"
      assert meta.author == "Jane Doe"
      assert meta.subject == "Testing"
      assert meta.keywords == "alpha, beta"
      assert meta.creator == "pdf_elixide test"
      assert meta.producer == "pdf_elixide"
      assert meta.creation_date == "D:20240115120000Z"
      assert meta.mod_date == nil
      assert meta.trapped == "True"
    end

    test "decodes every text-string encoding an Info field can carry" do
      doc = Document.open!(@metadata_encodings_pdf)

      assert {:ok, %Metadata{} = meta} = Document.metadata(doc)

      # UTF-16 both ways, selected by the BOM; the title carries a surrogate pair.
      assert meta.title == "Título 🙂"
      assert meta.author == "Jané Doe"

      # PDFDocEncoding, not Latin-1: 0x85/0x90/0x92 are glyphs, not C1 controls…
      assert meta.subject == "PDFDoc: – ’ ™"
      # …while 0xA0-0xFF is Latin-1 as before.
      assert meta.keywords == "café, naïve"

      # /Creator and /Producer go through the same decoder as every other field
      # rather than upstream's `document_creator/document_producer`, so raw
      # UTF-8 and PDF 2.0's EF BB BF BOM both work. The BOM is stripped rather
      # than surviving as a leading U+FEFF, which `String.trim/1` would keep.
      assert meta.creator == "Créateur"
      assert meta.producer == "pdf_elixide ✓"

      assert meta.creation_date == "D:20240115120000Z"
      # A whitespace-only value is nil, same as an absent one…
      assert meta.mod_date == nil
      # …and a name still falls back to its text.
      assert meta.trapped == "Unknown"
    end

    test "returns an all-nil struct for a document with no Info dictionary" do
      doc = Document.open!(@valid_pdf)

      assert {:ok, %Metadata{} = meta} = Document.metadata(doc)

      assert meta ==
               %Metadata{
                 title: nil,
                 author: nil,
                 subject: nil,
                 keywords: nil,
                 creator: nil,
                 producer: nil,
                 creation_date: nil,
                 mod_date: nil,
                 trapped: nil
               }
    end
  end

  describe "metadata!/1" do
    test "returns the struct directly" do
      doc = Document.open!(@metadata_pdf)
      assert %Metadata{title: "Test Title"} = Document.metadata!(doc)
    end
  end

  describe "xmp_metadata/1" do
    test "parses the XMP packet into a struct" do
      doc = Document.open!(@metadata_pdf)

      assert {:ok, %XmpMetadata{} = xmp} = Document.xmp_metadata(doc)
      assert xmp.title == "Test Title"
      assert xmp.creators == ["Jane Doe"]
      assert xmp.subjects == ["alpha", "beta"]
      assert xmp.creator_tool == "pdf_elixide test"
      assert xmp.create_date == "2024-01-15T12:00:00Z"
      assert xmp.producer == "pdf_elixide"
      assert is_binary(xmp.raw_xml)
    end

    test "returns {:ok, nil} for a document with no XMP packet" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, nil} = Document.xmp_metadata(doc)
    end
  end

  describe "xmp_metadata!/1" do
    test "returns the struct directly" do
      doc = Document.open!(@metadata_pdf)
      assert %XmpMetadata{title: "Test Title"} = Document.xmp_metadata!(doc)
    end

    test "returns nil for a document with no XMP packet" do
      doc = Document.open!(@valid_pdf)
      assert Document.xmp_metadata!(doc) == nil
    end
  end

  describe "permissions/1" do
    test "returns decoded flags for an encrypted document" do
      doc = Document.open!(@encrypted_pdf, password: @password)

      assert {:ok, %Permissions{} = perms} = Document.permissions(doc)
      assert is_boolean(perms.print_low_res)
      assert is_boolean(perms.copy)
      assert is_integer(perms.raw)
    end

    test "returns {:ok, nil} for an unencrypted document" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, nil} = Document.permissions(doc)
    end
  end

  describe "permissions!/1" do
    test "returns the struct directly for an encrypted document" do
      doc = Document.open!(@encrypted_pdf, password: @password)
      assert %Permissions{} = Document.permissions!(doc)
    end

    test "returns nil for an unencrypted document" do
      doc = Document.open!(@valid_pdf)
      assert Document.permissions!(doc) == nil
    end
  end

  describe "page_labels/1" do
    test "returns the declared labels, one per page" do
      doc = Document.open!(@metadata_pdf)
      assert {:ok, ["i", "ii", "1"]} = Document.page_labels(doc)
    end

    test "falls back to decimal page numbers when no labels are declared" do
      doc = Document.open!(@valid_pdf)

      assert {:ok, labels} = Document.page_labels(doc)
      assert labels == ["1", "2", "3"]
      assert length(labels) == Document.page_count!(doc)
    end
  end

  describe "page_labels!/1" do
    test "returns the list directly" do
      doc = Document.open!(@metadata_pdf)
      assert Document.page_labels!(doc) == ["i", "ii", "1"]
    end
  end

  describe "layers/1" do
    test "returns every declared name, in order, undeduplicated" do
      doc = Document.open!(@layers_and_inks_pdf)

      # Asserted as a literal so all of it fails loudly: the /OCGs order is
      # deliberately not alphabetical, "Ascii String" is declared twice, the
      # UTF-16BE and PDFDocEncoded names are the two upstream's own accessor
      # drops, the U+FEFF on "Cache" is a PDF 2.0 BOM left deliberately
      # unstripped so the name still matches the filter, and the entry with no
      # /Name and the one that cannot be resolved are both skipped.
      assert {:ok, names} = Document.layers(doc)

      assert names == [
               "Calque réservé",
               "NameToken",
               "Ascii String",
               "Ü-Layer",
               "﻿Cache",
               "Ascii String"
             ]
    end

    test "reads an /OCProperties and /OCGs given directly rather than by reference" do
      doc = Document.open!(@extraction_pdf)
      assert {:ok, ["Watermark"]} = Document.layers(doc)
    end

    test "returns an empty list for a document with no optional content" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Document.layers(doc)
    end

    test "every name it returns is one :exclude_layers acts on" do
      doc = Document.open!(@layers_and_inks_pdf)

      assert Document.text!(doc, 0) =~ "Layered line"
      refute Document.text!(doc, 0, exclude_layers: Document.layers!(doc)) =~ "Layered line"
    end
  end

  describe "layers!/1" do
    test "returns the list directly" do
      doc = Document.open!(@extraction_pdf)
      assert Document.layers!(doc) == ["Watermark"]
    end
  end

  describe "inks/2,3" do
    test "returns the inks the page itself declares" do
      doc = Document.open!(@layers_and_inks_pdf)
      assert {:ok, ["PageInk"]} = Document.inks(doc, 0)
    end

    test "deep: true adds the inks of the Form XObjects the page invokes" do
      doc = Document.open!(@layers_and_inks_pdf)

      # NestedInk is declared two forms down, so this also pins that the walk
      # recurses rather than reading only the page's direct `Do`s.
      assert {:ok, shallow} = Document.inks(doc, 0)
      assert {:ok, deep} = Document.inks(doc, 0, deep: true)
      assert deep == ["FormInk", "NestedInk", "PageInk"]
      assert shallow -- deep == []
    end

    test "unpacks a DeviceN and drops /All, /None and declared process colorants" do
      doc = Document.open!(@layers_and_inks_pdf)

      # The /ColorSpace dictionary itself is indirect here, and /Cyan is named
      # by the DeviceN attributes as a process component.
      assert {:ok, ["SpotA", "SpotB"]} = Document.inks(doc, 1)
    end

    test "deep: true adds nothing to a page that invokes no XObject" do
      doc = Document.open!(@layers_and_inks_pdf)
      assert Document.inks!(doc, 1, deep: true) == Document.inks!(doc, 1)

      extraction = Document.open!(@extraction_pdf)
      assert Document.inks!(extraction, 2) == ["SpotRed"]
      assert Document.inks!(extraction, 2, deep: true) == ["SpotRed"]
    end

    test "returns an empty list for a page with no colour spaces" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Document.inks(doc, 0)
      assert {:ok, []} = Document.inks(doc, 0, deep: true)
    end

    test "returns :out_of_range for a page past the end" do
      doc = Document.open!(@valid_pdf)

      assert {:error, %Error{reason: :out_of_range}} = Document.inks(doc, 99)
      assert {:error, %Error{reason: :out_of_range}} = Document.inks(doc, 99, deep: true)
    end

    test "raises for a negative index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.inks(doc, -1) end
    end
  end

  describe "inks!/2,3" do
    test "returns the list directly" do
      doc = Document.open!(@layers_and_inks_pdf)

      assert Document.inks!(doc, 0) == ["PageInk"]
      assert Document.inks!(doc, 0, deep: true) == ["FormInk", "NestedInk", "PageInk"]
    end

    test "raises for a page past the end" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.inks!(doc, 99) end
    end
  end

  describe "close/1 and closed?/1" do
    test "closed?/1 flips once the document is closed" do
      doc = Document.open!(@valid_pdf)
      refute Document.closed?(doc)

      assert :ok = Document.close(doc)
      assert Document.closed?(doc)
    end

    test "close/1 is idempotent" do
      doc = Document.open!(@valid_pdf)

      assert :ok = Document.close(doc)
      assert :ok = Document.close(doc)
      assert Document.closed?(doc)
    end

    test "reading a closed document returns a :closed error" do
      doc = Document.open!(@valid_pdf)
      :ok = Document.close(doc)

      assert {:error, %Error{reason: :closed, message: "Document is closed"}} =
               Document.text(doc, 0)

      assert {:error, %Error{reason: :closed}} = Document.metadata(doc)
      assert {:error, %Error{reason: :closed}} = PdfElixide.Form.fields(doc)

      # Not page_count/1: it is cached on the struct at open, so it answers
      # without the handle. Pinned in "struct-backed accessors keep working".
      assert {:ok, 3} = Document.page_count(doc)
    end

    test "bang variants raise on a closed document" do
      doc = Document.open!(@valid_pdf)
      :ok = Document.close(doc)

      error = assert_raise Error, fn -> Document.metadata!(doc) end
      assert error.reason == :closed

      assert_raise Error, "Document is closed", fn -> Document.text!(doc, 0) end
    end

    # `has_structure_tree?/1` and `has_xfa?/1` answer `false` for a document
    # whose feature cannot be read, but `:closed` is a failure of the *handle*,
    # not of the document, so it still raises — the line the tolerant predicates
    # draw, and the reason their strict variants are the only way to see an
    # upstream error.
    test "predicates raise on a closed document" do
      doc = Document.open!(@valid_pdf)
      :ok = Document.close(doc)

      error = assert_raise Error, fn -> Document.encrypted?(doc) end
      assert error.reason == :closed

      assert_raise Error, fn -> Document.has_structure_tree?(doc) end
      assert_raise Error, fn -> Document.has_xfa?(doc) end
    end

    test "struct-backed accessors keep working after close" do
      doc = Document.open!(@valid_pdf)
      :ok = Document.close(doc)

      assert Document.version(doc) == {1, 4}
      assert Document.source_path(doc) == @valid_pdf
      assert Document.page_count(doc) == {:ok, 3}
      assert Document.page_count!(doc) == 3
      assert inspect(doc) == "#PdfElixide.Document<sample.pdf v1.4>"
    end

    test "page handles from a closed document report :closed" do
      doc = Document.open!(@valid_pdf)
      page = Document.page!(doc, 0)
      :ok = Document.close(doc)

      assert {:error, %Error{reason: :closed}} = Page.text(page)
      assert {:error, %Error{reason: :closed}} = Page.width(page)
    end

    test "enumerating a closed document still yields its page handles" do
      doc = Document.open!(@valid_pdf)
      :ok = Document.close(doc)

      # The count is cached, so enumeration needs no handle. Reading through the
      # handles it yields does, and reports :closed (test above).
      assert Enum.count(doc) == 3
      assert Enum.map(doc, & &1.index) == [0, 1, 2]
      assert Document.pages(doc) == Enum.to_list(doc)
    end
  end

  describe "close/1 and closed?/1 on extracted handles" do
    test "closes an image handle" do
      image = Document.open!(@image_pdf) |> Document.images!() |> hd()
      refute Document.Image.closed?(image)

      assert :ok = Document.Image.close(image)
      assert :ok = Document.Image.close(image)
      assert Document.Image.closed?(image)

      assert {:error, %Error{reason: :closed, message: "Image is closed"}} =
               Document.Image.data(image)

      assert {:error, %Error{reason: :closed}} = Document.Image.to_binary(image)
      assert_raise Error, fn -> Document.Image.to_binary!(image) end
    end

    test "closes a font handle" do
      font =
        Document.open!(@fonts_pdf) |> Document.fonts!(0) |> Enum.find(& &1.embedded?)

      refute Document.Font.closed?(font)

      assert :ok = Document.Font.close(font)
      assert Document.Font.closed?(font)

      assert {:error, %Error{reason: :closed, message: "Font is closed"}} =
               Document.Font.data(font)

      assert_raise Error, fn -> Document.Font.data!(font) end
    end

    test "an extracted image outlives the document it came from" do
      doc = Document.open!(@image_pdf)
      image = doc |> Document.images!() |> hd()

      :ok = Document.close(doc)

      refute Document.Image.closed?(image)
      assert {:ok, {:raw, _bytes, _format}} = Document.Image.data(image)
    end

    test "an extracted font outlives the document it came from" do
      doc = Document.open!(@fonts_pdf)
      font = doc |> Document.fonts!(0) |> Enum.find(& &1.embedded?)

      :ok = Document.close(doc)

      refute Document.Font.closed?(font)
      assert {:ok, bytes} = Document.Font.data(font)
      assert is_binary(bytes)
    end

    test "closing an image leaves its document usable" do
      doc = Document.open!(@image_pdf)
      image = doc |> Document.images!() |> hd()

      :ok = Document.Image.close(image)

      refute Document.closed?(doc)
      assert {:ok, [_ | _]} = Document.images(doc)
    end
  end

  # The annotation_colors.pdf fixture carries one annotation per color arity,
  # each identified by its /Contents string.
  defp annotation_with_contents(contents) do
    doc = Document.open!(@annotation_colors_pdf)
    annotations = Document.annotations!(doc)

    Enum.find(annotations, &(&1.contents == contents)) ||
      flunk("no annotation with contents #{inspect(contents)} in the fixture")
  end

  # No fixture detects a table with a colspan, so build one by hand: a single
  # row of three grid columns whose first cell spans the first two.
  defp spanning_table do
    cells = [
      %Table.Cell{
        text: "A",
        bbox: nil,
        colspan: 2,
        rowspan: 1,
        header?: false,
        mcids: [],
        spans: []
      },
      %Table.Cell{
        text: "B",
        bbox: nil,
        colspan: 1,
        rowspan: 1,
        header?: false,
        mcids: [],
        spans: []
      }
    ]

    # `:ref` is nil because the table never came from extraction: the accessors
    # under test are plain data, while rendering needs the native handle and
    # refuses a struct built by hand.
    %Table{
      page: 0,
      bbox: nil,
      col_count: 3,
      has_header?: false,
      real_grid?: true,
      rows: [%Table.Row{header?: false, cells: cells}],
      ref: nil
    }
  end
end
