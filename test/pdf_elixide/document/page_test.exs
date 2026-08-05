defmodule PdfElixide.Document.PageTest do
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Document.Annotation
  alias PdfElixide.Document.Char
  alias PdfElixide.Document.Page
  alias PdfElixide.Document.SearchMatch
  alias PdfElixide.Document.Span
  alias PdfElixide.Document.Table
  alias PdfElixide.Document.TextLine
  alias PdfElixide.Document.Word
  alias PdfElixide.Error
  alias PdfElixide.Geometry.Rect

  @fixtures Path.join([__DIR__, "..", "..", "fixtures"])
  @valid_pdf Path.join(@fixtures, "sample.pdf")
  @table_pdf Path.join(@fixtures, "table.pdf")
  @image_pdf Path.join(@fixtures, "image.pdf")
  @fonts_pdf Path.join(@fixtures, "fonts.pdf")
  @form_pdf Path.join(@fixtures, "form.pdf")
  @metadata_pdf Path.join(@fixtures, "metadata.pdf")
  @annotations_pdf Path.join(@fixtures, "annotations.pdf")
  @rotation_pdf Path.join(@fixtures, "rotation.pdf")
  @media_box_pdf Path.join(@fixtures, "media_box.pdf")
  @text_layer_pdf Path.join(@fixtures, "text_layer.pdf")
  @broken_page_pdf Path.join(@fixtures, "broken_page.pdf")
  # Page 0 declares one ink itself and reaches two more through a nested chain
  # of Form XObjects, so it is the only fixture where :deep changes the answer.
  @layers_and_inks_pdf Path.join(@fixtures, "layers_and_inks.pdf")
  # Page 0 draws only rectangles and page 1 only straight lines, so each of the
  # two classifiers has a page that is entirely its own.
  @vector_shapes_pdf Path.join(@fixtures, "vector_shapes.pdf")

  describe "inspect/1" do
    test "renders the page index" do
      doc = Document.open!(@valid_pdf)
      assert inspect(Document.page!(doc, 2)) == "#PdfElixide.Document.Page<2>"
    end
  end

  describe "media_box/1" do
    test "returns the box of a page at the origin" do
      doc = Document.open!(@valid_pdf)

      assert {:ok, %Rect{x: +0.0, y: +0.0, width: 612.0, height: 792.0}} =
               Page.media_box(Document.page!(doc, 0))
    end

    # Also the guard against upstream reinterpreting `get_page_media_box`'s
    # tuple: it returns raw corners `(llx, lly, urx, ury)`, and this page's box
    # is `[10 20 622 812]`, so a switch to x/y/width/height semantics would
    # report a width of 622 rather than 612.
    test "reports a non-zero origin and measures between the corners" do
      doc = Document.open!(@media_box_pdf)

      assert {:ok, %Rect{x: 10.0, y: 20.0, width: 612.0, height: 792.0}} =
               Page.media_box(Document.page!(doc, 0))
    end

    test "normalizes a box whose corners are written in reverse" do
      # `[612 792 0 0]`. Upstream hands the corners back in file order; the
      # binding normalizes, because `%Rect{}` promises non-negative dimensions
      # and `width/1`/`height/1` are these fields.
      doc = Document.open!(@media_box_pdf)

      assert {:ok, %Rect{x: +0.0, y: +0.0, width: 612.0, height: 792.0}} =
               Page.media_box(Document.page!(doc, 1))
    end

    test "inherits the box from an ancestor /Pages node" do
      # This page carries no /MediaBox; the intermediate /Pages above it has
      # `[0 0 300 500]`. Which ancestor wins when two of them declare one is
      # upstream's, and unstable — see `inherited_boxes.pdf` in
      # `upstream_drift_test.exs`.
      doc = Document.open!(@media_box_pdf)
      assert {:ok, %Rect{width: 300.0, height: 500.0}} = Page.media_box(Document.page!(doc, 2))
    end

    test "resolves an indirect /MediaBox reference" do
      doc = Document.open!(@media_box_pdf)
      assert {:ok, %Rect{width: 300.0, height: 400.0}} = Page.media_box(Document.page!(doc, 3))
    end

    test "resolves an indirect reference in each element of the array" do
      # An unresolved element reads as 0.0 upstream, collapsing the page to a
      # zero-area box that clips every extraction — silent, hence the pin.
      doc = Document.open!(@media_box_pdf)
      assert {:ok, %Rect{width: 300.0, height: 400.0}} = Page.media_box(Document.page!(doc, 4))
    end

    test "reports a page with no /MediaBox above it as :invalid_pdf" do
      # No default page size is substituted: a caller could not tell an assumed
      # Letter box from a real one.
      doc = Document.open!(@media_box_pdf)
      assert {:error, %Error{reason: :invalid_pdf}} = Page.media_box(Document.page!(doc, 5))
    end

    test "leaves extracted coordinates in the same space as the box" do
      # The box starts at (10, 20) and the text is drawn at (82, 740). Nothing
      # rebases a bbox on the box origin — the fact `media_box/1` makes visible,
      # and the reason `PdfElixide.Document`'s "Page boxes and the coordinate
      # origin" section tells callers to subtract it themselves.
      doc = Document.open!(@media_box_pdf)
      page = Document.page!(doc, 0)

      assert %Rect{x: 10.0, y: 20.0} = Page.media_box!(page)
      assert [%Char{bbox: %Rect{x: x, y: y}} | _] = Page.chars!(page)
      assert_in_delta x, 82.0, 0.5
      assert_in_delta y, 740.0, 0.5
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Page.media_box(%Page{doc: doc, index: 99})
    end

    test "returns {:error, reason} for a closed document" do
      doc = Document.open!(@valid_pdf)
      page = Document.page!(doc, 0)
      :ok = Document.close(doc)

      assert {:error, %Error{reason: :closed}} = Page.media_box(page)
    end
  end

  describe "media_box!/1" do
    test "returns the rect directly" do
      doc = Document.open!(@valid_pdf)

      assert Page.media_box!(Document.page!(doc, 0)) ==
               %Rect{x: 0.0, y: 0.0, width: 612.0, height: 792.0}
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Page.media_box!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "width/1" do
    test "returns the page width in points" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, 612.0} = Page.width(Document.page!(doc, 0))
    end

    test "measures between the corners of a box with a non-zero origin" do
      # `[10 20 622 812]` — 612 wide, not 622.
      doc = Document.open!(@media_box_pdf)
      assert {:ok, 612.0} = Page.width(Document.page!(doc, 0))
    end

    test "is never negative for a box whose corners are reversed" do
      # This returned -612.0 while width/1 had its own NIF subtracting the raw
      # corners; it is the rect's `:width` now, so it cannot disagree with
      # `media_box/1` about the sign or anything else.
      doc = Document.open!(@media_box_pdf)
      assert {:ok, 612.0} = Page.width(Document.page!(doc, 1))
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert {:error, _reason} = Page.width(%Page{doc: doc, index: 99})
    end
  end

  describe "width!/1" do
    test "returns the width directly" do
      doc = Document.open!(@valid_pdf)
      assert Page.width!(Document.page!(doc, 0)) == 612.0
    end
  end

  describe "height/1" do
    test "returns the page height in points" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, 792.0} = Page.height(Document.page!(doc, 0))
    end

    test "is never negative for a box whose corners are reversed" do
      doc = Document.open!(@media_box_pdf)
      assert {:ok, 792.0} = Page.height(Document.page!(doc, 1))
    end
  end

  describe "height!/1" do
    test "returns the height directly" do
      doc = Document.open!(@valid_pdf)
      assert Page.height!(Document.page!(doc, 0)) == 792.0
    end
  end

  describe "rotation/1" do
    test "returns 0 for a page with no /Rotate anywhere above it" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, 0} = Page.rotation(Document.page!(doc, 0))
    end

    test "reads a /Rotate on the page itself" do
      doc = Document.open!(@rotation_pdf)
      assert {:ok, 90} = Page.rotation(Document.page!(doc, 0))
    end

    test "inherits a /Rotate from an ancestor /Pages node" do
      # Page 1 carries no /Rotate; the intermediate /Pages node holding it does
      # (ISO 32000-1 §7.7.3.4).
      doc = Document.open!(@rotation_pdf)
      assert {:ok, 180} = Page.rotation(Document.page!(doc, 1))
    end

    test "wraps a negative /Rotate into 0..270" do
      doc = Document.open!(@rotation_pdf)
      assert {:ok, 270} = Page.rotation(Document.page!(doc, 2))
    end

    test "reports a /Rotate that is not a multiple of 90 as 0, not the nearest one" do
      # /Rotate 45 is invalid per §7.7.3.3. Upstream returns 0 rather than
      # flooring to 90, and a caller matching on 0/90/180/270 depends on that.
      doc = Document.open!(@rotation_pdf)
      assert {:ok, 0} = Page.rotation(Document.page!(doc, 3))
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Page.rotation(%Page{doc: doc, index: 99})
    end

    test "returns {:error, reason} for a closed document" do
      doc = Document.open!(@rotation_pdf)
      page = Document.page!(doc, 0)
      Document.close(doc)
      assert {:error, %Error{reason: :closed}} = Page.rotation(page)
    end
  end

  describe "rotation!/1" do
    test "returns the rotation directly" do
      doc = Document.open!(@rotation_pdf)
      assert Enum.map(doc, &Page.rotation!/1) == [90, 180, 270, 0]
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@valid_pdf)

      assert_raise Error, fn -> Page.rotation!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "has_text_layer/1" do
    # One test per branch of upstream's two-stage probe. `text_layer.pdf` is the
    # only fixture that can answer `false` at all: every other one declares a
    # font, either on the page or on an ancestor /Pages node.
    test "answers true for a page with fonts and a text object" do
      doc = Document.open!(@text_layer_pdf)
      assert {:ok, true} = Page.has_text_layer(Document.page!(doc, 0))
    end

    test "answers false for an image-only page, though its stream contains Do" do
      # The sharpest case, and the one OCR routing turns on. Page 1 draws its
      # image with `/Im1 Do`, so the content-stream byte scan would say "may
      # contain text" — but the resource check settles it first: no /Font, and
      # the sole XObject is an image rather than a form.
      doc = Document.open!(@text_layer_pdf)
      assert {:ok, false} = Page.has_text_layer(Document.page!(doc, 1))
    end

    test "answers false for a page declaring fonts it never uses" do
      # Page 2 passes the resource check on the strength of its /Font entry and
      # is then rejected by the content scan: the stream fills a rectangle and
      # contains neither BT nor Do. Nothing but this page reaches that stage.
      doc = Document.open!(@text_layer_pdf)
      assert {:ok, false} = Page.has_text_layer(Document.page!(doc, 2))
    end

    test "answers true for a page whose text lives in a form XObject" do
      # Page 3 has no /Font of its own; the form XObject arm of the resource
      # check is what keeps it alive, and `Do` is what carries the content scan.
      doc = Document.open!(@text_layer_pdf)
      assert {:ok, true} = Page.has_text_layer(Document.page!(doc, 3))
    end

    test "answers false for a page with no /Resources at all" do
      doc = Document.open!(@text_layer_pdf)
      assert {:ok, false} = Page.has_text_layer(Document.page!(doc, 4))
    end

    test "agrees with what text/1 can actually extract" do
      # The whole point of the predicate: `text/1` returns "" for a page with no
      # text layer *and* for a blank one, so an empty string is not a signal.
      doc = Document.open!(@text_layer_pdf)

      layers = Enum.map(doc, &Page.has_text_layer?/1)
      extracted = Enum.map(doc, fn page -> page |> Page.text!() |> String.trim() != "" end)

      assert layers == [true, false, false, true, false]
      assert layers == extracted
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@valid_pdf)

      assert {:error, %Error{reason: :out_of_range}} =
               Page.has_text_layer(%Page{doc: doc, index: 99})
    end

    test "returns {:error, reason} for a page that does not resolve" do
      # `broken_page.pdf`'s /Count claims three pages where the tree holds two,
      # so index 2 clears the bounds check and then fails to resolve. The only
      # way to reach this error branch through the *document* rather than the
      # handle — upstream swallows every other failure inside the probe.
      doc = Document.open!(@broken_page_pdf)

      assert {:error, %Error{reason: :invalid_pdf}} =
               Page.has_text_layer(%Page{doc: doc, index: 2})
    end

    test "returns {:error, reason} for a closed document" do
      doc = Document.open!(@text_layer_pdf)
      page = Document.page!(doc, 0)
      Document.close(doc)
      assert {:error, %Error{reason: :closed}} = Page.has_text_layer(page)
    end
  end

  describe "has_text_layer?/1" do
    test "returns the boolean directly" do
      doc = Document.open!(@text_layer_pdf)
      assert Enum.map(doc, &Page.has_text_layer?/1) == [true, false, false, true, false]
    end

    # Unlike `Document.has_structure_tree?/1` and `Document.has_xfa?/1`, this
    # predicate degrades nothing — every error raises, not just a failure of the
    # handle. Each of the three reachable shapes is asserted separately, because
    # that difference is the whole of its contract.
    test "raises for an out-of-range page" do
      doc = Document.open!(@valid_pdf)

      error = assert_raise Error, fn -> Page.has_text_layer?(%Page{doc: doc, index: 99}) end
      assert error.reason == :out_of_range
    end

    test "raises for a page that does not resolve" do
      doc = Document.open!(@broken_page_pdf)

      error = assert_raise Error, fn -> Page.has_text_layer?(%Page{doc: doc, index: 2}) end
      assert error.reason == :invalid_pdf
    end

    test "raises for a closed document" do
      doc = Document.open!(@text_layer_pdf)
      page = Document.page!(doc, 0)
      Document.close(doc)

      error = assert_raise Error, fn -> Page.has_text_layer?(page) end
      assert error.reason == :closed
    end
  end

  describe "text/1" do
    test "returns {:ok, text} for the page's content" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, text} = Page.text(Document.page!(doc, 1))
      assert text =~ "Page Two"
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert {:error, _reason} = Page.text(%Page{doc: doc, index: 99})
    end
  end

  describe "text!/1" do
    test "returns the text directly" do
      doc = Document.open!(@valid_pdf)
      assert Page.text!(Document.page!(doc, 0)) =~ "Page One"
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Page.text!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "to_markdown/1" do
    test "delegates to Document.to_markdown/3 for the page" do
      doc = Document.open!(@valid_pdf)
      page = Document.page!(doc, 1)
      assert Page.to_markdown(page) == Document.to_markdown(doc, 1, [])
      assert {:ok, markdown} = Page.to_markdown(page)
      assert markdown =~ "# Page Two"
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert {:error, _reason} = Page.to_markdown(%Page{doc: doc, index: 99})
    end
  end

  describe "to_markdown/2" do
    test "passes options through to Document.to_markdown/3" do
      doc = Document.open!(@table_pdf)
      page = Document.page!(doc, 0)
      assert {:ok, with_tables} = Page.to_markdown(page)
      assert {:ok, without} = Page.to_markdown(page, extract_tables: false)
      assert with_tables =~ "|---|"
      refute without =~ "|---|"
    end
  end

  describe "to_markdown!/1" do
    test "returns the markdown directly" do
      doc = Document.open!(@valid_pdf)
      assert Page.to_markdown!(Document.page!(doc, 0)) =~ "Page One"
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Page.to_markdown!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "to_markdown!/2" do
    test "returns the markdown with options applied" do
      doc = Document.open!(@valid_pdf)
      markdown = Page.to_markdown!(Document.page!(doc, 0), detect_headings: false)
      assert markdown =~ "Page One"
      refute markdown =~ "#"
    end
  end

  describe "to_html/1" do
    test "delegates to Document.to_html/3 for the page" do
      doc = Document.open!(@valid_pdf)
      page = Document.page!(doc, 1)
      assert Page.to_html(page) == Document.to_html(doc, 1, [])
      assert {:ok, html} = Page.to_html(page)
      assert html =~ "<h1>Page Two</h1>"
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert {:error, _reason} = Page.to_html(%Page{doc: doc, index: 99})
    end
  end

  describe "to_html/2" do
    test "passes options through to Document.to_html/3" do
      doc = Document.open!(@table_pdf)
      page = Document.page!(doc, 0)
      assert {:ok, with_tables} = Page.to_html(page)
      assert {:ok, without} = Page.to_html(page, extract_tables: false)
      assert with_tables =~ "<table>"
      refute without =~ "<table"
    end
  end

  describe "to_html!/1" do
    test "returns the html directly" do
      doc = Document.open!(@valid_pdf)
      assert Page.to_html!(Document.page!(doc, 0)) =~ "Page One"
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Page.to_html!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "to_html!/2" do
    test "returns the html with options applied" do
      doc = Document.open!(@valid_pdf)
      html = Page.to_html!(Document.page!(doc, 0), detect_headings: false)
      assert html =~ "<p>Page One</p>"
      refute html =~ "<h1"
    end
  end

  describe "words/1" do
    test "delegates to Document.words/2 for the page" do
      doc = Document.open!(@valid_pdf)
      page = Document.page!(doc, 1)
      assert Page.words(page) == Document.words(doc, 1)
      assert {:ok, [%Word{text: "Page", page: 1}, %Word{text: "Two", page: 1}]} = Page.words(page)
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert {:error, _reason} = Page.words(%Page{doc: doc, index: 99})
    end
  end

  describe "words!/1" do
    test "returns the words directly" do
      doc = Document.open!(@valid_pdf)
      assert [%Word{text: "Page"}, %Word{text: "One"}] = Page.words!(Document.page!(doc, 0))
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Page.words!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "chars/1" do
    test "delegates to Document.chars/2 for the page" do
      doc = Document.open!(@valid_pdf)
      page = Document.page!(doc, 1)
      assert Page.chars(page) == Document.chars(doc, 1)
      assert {:ok, chars} = Page.chars(page)
      assert Enum.map_join(chars, & &1.text) == "Page Two"
      assert Enum.all?(chars, &(&1.page == 1))
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert {:error, _reason} = Page.chars(%Page{doc: doc, index: 99})
    end
  end

  describe "chars!/1" do
    test "returns the chars directly" do
      doc = Document.open!(@valid_pdf)
      assert [%Char{text: "P", page: 0} | _] = Page.chars!(Document.page!(doc, 0))
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Page.chars!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "spans/1" do
    test "delegates to Document.spans/2 for the page" do
      doc = Document.open!(@valid_pdf)
      page = Document.page!(doc, 1)
      assert Page.spans(page) == Document.spans(doc, 1)
      assert {:ok, [%Span{text: "Page Two", page: 1}]} = Page.spans(page)
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert {:error, _reason} = Page.spans(%Page{doc: doc, index: 99})
    end
  end

  describe "spans!/1" do
    test "returns the spans directly" do
      doc = Document.open!(@valid_pdf)
      assert [%Span{text: "Page One", page: 0}] = Page.spans!(Document.page!(doc, 0))
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Page.spans!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "paths/1" do
    test "delegates to Document.paths/2 for the page" do
      doc = Document.open!(@table_pdf)
      page = Document.page!(doc, 0)
      assert Page.paths(page) == Document.paths(doc, 0)
      assert {:ok, [%Document.Path{page: 0} | _]} = Page.paths(page)
    end

    test "returns {:ok, []} for a page with no vector graphics" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Page.paths(Document.page!(doc, 0))
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@table_pdf)
      assert {:error, _reason} = Page.paths(%Page{doc: doc, index: 99})
    end
  end

  describe "paths!/1" do
    test "returns the paths directly" do
      doc = Document.open!(@table_pdf)
      assert [%Document.Path{page: 0} | _] = Page.paths!(Document.page!(doc, 0))
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@table_pdf)
      assert_raise Error, fn -> Page.paths!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "rects/1" do
    test "delegates to Document.rects/2 for the page" do
      doc = Document.open!(@vector_shapes_pdf)
      page = Document.page!(doc, 0)
      assert Page.rects(page) == Document.rects(doc, 0)
      assert {:ok, [%Document.Path{page: 0} | _]} = Page.rects(page)
    end

    test "returns {:ok, []} for a page drawing only straight lines" do
      doc = Document.open!(@vector_shapes_pdf)
      assert {:ok, []} = Page.rects(Document.page!(doc, 1))
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@vector_shapes_pdf)
      assert {:error, _reason} = Page.rects(%Page{doc: doc, index: 99})
    end
  end

  describe "rects!/1" do
    test "returns the rects directly" do
      doc = Document.open!(@vector_shapes_pdf)
      assert [%Document.Path{page: 0} | _] = Page.rects!(Document.page!(doc, 0))
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@vector_shapes_pdf)
      assert_raise Error, fn -> Page.rects!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "lines/1" do
    test "delegates to Document.lines/2 for the page" do
      doc = Document.open!(@table_pdf)
      page = Document.page!(doc, 0)
      assert Page.lines(page) == Document.lines(doc, 0)
      assert {:ok, [%Document.Path{page: 0} | _]} = Page.lines(page)
    end

    test "returns {:ok, []} for a page drawing only rectangles" do
      doc = Document.open!(@vector_shapes_pdf)
      assert {:ok, []} = Page.lines(Document.page!(doc, 0))
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@table_pdf)
      assert {:error, _reason} = Page.lines(%Page{doc: doc, index: 99})
    end
  end

  describe "lines!/1" do
    test "returns the lines directly" do
      doc = Document.open!(@table_pdf)
      assert [%Document.Path{page: 0} | _] = Page.lines!(Document.page!(doc, 0))
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@table_pdf)
      assert_raise Error, fn -> Page.lines!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "search/2,3" do
    test "delegates to Document.search/4 for the page" do
      doc = Document.open!(@valid_pdf)
      page = Document.page!(doc, 1)
      assert Page.search(page, "Page") == Document.search(doc, "Page", 1)
      assert {:ok, [%SearchMatch{page: 1}]} = Page.search(page, "Page")
    end

    test "passes options through" do
      doc = Document.open!(@valid_pdf)
      page = Document.page!(doc, 1)
      assert {:ok, [%SearchMatch{}]} = Page.search(page, "page", case_insensitive: true)
      assert {:ok, []} = Page.search(page, "page")
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert {:error, _reason} = Page.search(%Page{doc: doc, index: 99}, "Page")
    end
  end

  describe "search!/2,3" do
    test "returns the matches directly" do
      doc = Document.open!(@valid_pdf)
      assert [%SearchMatch{page: 2}] = Page.search!(Document.page!(doc, 2), "Page")
      assert [%SearchMatch{page: 2}] = Page.search!(Document.page!(doc, 2), "Page", [])
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Page.search!(%Page{doc: doc, index: 99}, "Page") end
    end
  end

  describe "images/1" do
    test "delegates to Document.images/2 for the page" do
      doc = Document.open!(@image_pdf)
      page = Document.page!(doc, 0)
      # Each extraction yields fresh image handles, so compare stable metadata
      # rather than the structs (whose :ref differ) directly.
      {:ok, via_page} = Page.images(page)
      {:ok, via_doc} = Document.images(doc, 0)
      assert Enum.map(via_page, & &1.page) == Enum.map(via_doc, & &1.page)
      assert length(via_page) == length(via_doc)
      assert {:ok, [%Document.Image{page: 0} | _]} = Page.images(page)
    end

    test "returns {:ok, []} for a page with no images" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Page.images(Document.page!(doc, 0))
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@image_pdf)
      assert {:error, _reason} = Page.images(%Page{doc: doc, index: 99})
    end
  end

  describe "images!/1" do
    test "returns the images directly" do
      doc = Document.open!(@image_pdf)
      assert [%Document.Image{page: 0} | _] = Page.images!(Document.page!(doc, 0))
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@image_pdf)
      assert_raise Error, fn -> Page.images!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "fonts/1" do
    test "delegates to Document.fonts/2 for the page" do
      doc = Document.open!(@fonts_pdf)
      page = Document.page!(doc, 0)
      # Each extraction yields fresh font handles, so compare stable metadata
      # rather than the structs (whose :ref differ) directly.
      {:ok, via_page} = Page.fonts(page)
      {:ok, via_doc} = Document.fonts(doc, 0)
      assert Enum.map(via_page, & &1.base_font) == Enum.map(via_doc, & &1.base_font)
      assert length(via_page) == length(via_doc)
      assert {:ok, [%Document.Font{page: 0} | _]} = Page.fonts(page)
    end

    test "returns {:ok, []} for a page that references no fonts" do
      doc = Document.open!(@form_pdf)
      assert {:ok, []} = Page.fonts(Document.page!(doc, 0))
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@fonts_pdf)
      assert {:error, _reason} = Page.fonts(%Page{doc: doc, index: 99})
    end
  end

  describe "fonts!/1" do
    test "returns the fonts directly" do
      doc = Document.open!(@fonts_pdf)
      assert [%Document.Font{page: 0} | _] = Page.fonts!(Document.page!(doc, 0))
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@fonts_pdf)
      assert_raise Error, fn -> Page.fonts!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "inks/2" do
    test "delegates to Document.inks/3 for the page, at both :deep settings" do
      doc = Document.open!(@layers_and_inks_pdf)
      page = Document.page!(doc, 0)

      assert Page.inks(page) == Document.inks(doc, 0)
      assert Page.inks(page, deep: true) == Document.inks(doc, 0, deep: true)
      assert {:ok, ["PageInk"]} = Page.inks(page)
      assert {:ok, ["FormInk", "NestedInk", "PageInk"]} = Page.inks(page, deep: true)
    end

    test "returns {:ok, []} for a page that declares no colour spaces" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Page.inks(Document.page!(doc, 0))
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert {:error, _reason} = Page.inks(%Page{doc: doc, index: 99})
    end
  end

  describe "inks!/2" do
    test "returns the inks directly" do
      doc = Document.open!(@layers_and_inks_pdf)
      page = Document.page!(doc, 0)

      assert Page.inks!(page) == ["PageInk"]
      assert Page.inks!(page, deep: true) == ["FormInk", "NestedInk", "PageInk"]
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Page.inks!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "annotations/1" do
    test "delegates to Document.annotations/2 for the page" do
      doc = Document.open!(@annotations_pdf)
      page = Document.page!(doc, 0)
      {:ok, via_page} = Page.annotations(page)
      {:ok, via_doc} = Document.annotations(doc, 0)
      assert Enum.map(via_page, & &1.subtype) == Enum.map(via_doc, & &1.subtype)
      assert {:ok, [%Annotation{page: 0} | _]} = Page.annotations(page)
    end

    test "returns {:ok, []} for a page with no annotations" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Page.annotations(Document.page!(doc, 0))
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@annotations_pdf)
      assert {:error, _reason} = Page.annotations(%Page{doc: doc, index: 99})
    end
  end

  describe "annotations!/1" do
    test "returns the annotations directly" do
      doc = Document.open!(@annotations_pdf)
      assert [%Annotation{page: 0} | _] = Page.annotations!(Document.page!(doc, 0))
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@annotations_pdf)
      assert_raise Error, fn -> Page.annotations!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "tables/1" do
    test "delegates to Document.tables/2 for the page" do
      doc = Document.open!(@table_pdf)
      page = Document.page!(doc, 0)
      # Each extraction yields fresh table handles, so compare stable data
      # rather than the structs (whose :ref differ) directly.
      {:ok, via_page} = Page.tables(page)
      {:ok, via_doc} = Document.tables(doc, 0)
      assert Enum.map(via_page, & &1.rows) == Enum.map(via_doc, & &1.rows)
      assert Enum.map(via_page, & &1.page) == Enum.map(via_doc, & &1.page)
      assert {:ok, [%Table{page: 0, col_count: 4}]} = Page.tables(page)
    end

    test "returns {:ok, []} for a page with no table" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Page.tables(Document.page!(doc, 0))
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@table_pdf)
      assert {:error, _reason} = Page.tables(%Page{doc: doc, index: 99})
    end
  end

  describe "tables!/1" do
    test "returns the tables directly" do
      doc = Document.open!(@table_pdf)
      assert [%Table{page: 0}] = Page.tables!(Document.page!(doc, 0))
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@table_pdf)
      assert_raise Error, fn -> Page.tables!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "text_lines/1" do
    test "delegates to Document.text_lines/2 for the page" do
      doc = Document.open!(@valid_pdf)
      page = Document.page!(doc, 1)
      assert Page.text_lines(page) == Document.text_lines(doc, 1)
      assert {:ok, [%TextLine{text: "Page Two", page: 1}]} = Page.text_lines(page)
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert {:error, _reason} = Page.text_lines(%Page{doc: doc, index: 99})
    end
  end

  describe "text_lines!/1" do
    test "returns the lines directly" do
      doc = Document.open!(@valid_pdf)
      assert [%TextLine{text: "Page One", page: 0}] = Page.text_lines!(Document.page!(doc, 0))
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Page.text_lines!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "label/1" do
    test "returns the page's declared label" do
      doc = Document.open!(@metadata_pdf)
      assert {:ok, "i"} = Page.label(Document.page!(doc, 0))
      assert {:ok, "ii"} = Page.label(Document.page!(doc, 1))
      assert {:ok, "1"} = Page.label(Document.page!(doc, 2))
    end

    test "falls back to the decimal page number when no labels are declared" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, "3"} = Page.label(Document.page!(doc, 2))
    end

    test "agrees with Document.page_labels/1" do
      doc = Document.open!(@metadata_pdf)
      labels = Document.page_labels!(doc)

      for {label, index} <- Enum.with_index(labels) do
        assert Page.label(%Page{doc: doc, index: index}) == {:ok, label}
      end
    end

    test "returns :out_of_range for a page past the end" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Page.label(%Page{doc: doc, index: 99})
    end
  end

  describe "label!/1" do
    test "returns the label directly" do
      doc = Document.open!(@metadata_pdf)
      assert Page.label!(Document.page!(doc, 0)) == "i"
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Page.label!(%Page{doc: doc, index: 99}) end
    end
  end
end
