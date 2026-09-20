defmodule PdfElixide.RenderingTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias PdfElixide.Color
  alias PdfElixide.Document
  alias PdfElixide.Document.Page
  alias PdfElixide.Document.RenderedPage
  alias PdfElixide.Document.SeparationPlate
  alias PdfElixide.Error
  alias PdfElixide.Geometry.Rect

  @fixtures_dir Path.join([__DIR__, "..", "fixtures"])

  @sample_pdf Path.join(@fixtures_dir, "sample.pdf")
  @rotation_pdf Path.join(@fixtures_dir, "rotation.pdf")
  @media_box_pdf Path.join(@fixtures_dir, "media_box.pdf")
  @layers_pdf Path.join(@fixtures_dir, "layers_and_inks.pdf")
  @render_layers_pdf Path.join(@fixtures_dir, "render_layers.pdf")
  @spot_inks_pdf Path.join(@fixtures_dir, "spot_inks_and_intent.pdf")
  @inherited_boxes_pdf Path.join(@fixtures_dir, "inherited_boxes.pdf")
  @crop_box_pdf Path.join(@fixtures_dir, "crop_box.pdf")
  @cropped_content_pdf Path.join(@fixtures_dir, "cropped_content.pdf")

  @png_signature <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
  @jpeg_signature <<0xFF, 0xD8>>

  defp sample(context) do
    doc = Document.open!(@sample_pdf)
    on_exit(fn -> Document.close(doc) end)

    Map.put(context, :doc, doc)
  end

  defp pixel(%RenderedPage{format: :rgba8} = rendered, col, row) do
    <<r, g, b, a>> = binary_part(rendered.data, (row * rendered.width + col) * 4, 4)
    {r, g, b, a}
  end

  describe "render/3" do
    setup :sample

    test "defaults to a 150 DPI PNG", %{doc: doc} do
      rendered = Document.render!(doc, 0)

      assert %RenderedPage{format: :png} = rendered
      assert binary_part(rendered.data, 0, 8) == @png_signature
      assert {rendered.width, rendered.height} == {1275, 1650}
    end

    test "at 72 DPI the pixel size is the page size in points", %{doc: doc} do
      box = doc |> Document.page!(0) |> Page.media_box!()
      rendered = Document.render!(doc, 0, dpi: 72)

      assert {rendered.width, rendered.height} == {trunc(box.width), trunc(box.height)}
    end

    test "emits a JPEG when asked for one", %{doc: doc} do
      rendered = Document.render!(doc, 0, format: :jpeg, dpi: 72, jpeg_quality: 60)

      assert rendered.format == :jpeg
      assert binary_part(rendered.data, 0, 2) == @jpeg_signature
    end

    test ":jpeg_quality changes the compression on every JPEG path", %{doc: doc} do
      # A region over the page's text, so the crop has something to compress.
      region = %Rect{x: 0.0, y: 600.0, width: 400.0, height: 190.0}

      for opts <- [[dpi: 72], [fit: {200, 200}], [dpi: 72, region: region]] do
        size = fn quality ->
          opts
          |> Keyword.merge(format: :jpeg, jpeg_quality: quality)
          |> then(&Document.render!(doc, 0, &1))
          |> Map.fetch!(:data)
          |> byte_size()
        end

        assert size.(10) < size.(100), "jpeg_quality was ignored for #{inspect(opts)}"
      end
    end

    test ":rgba8 is four tightly packed bytes per pixel", %{doc: doc} do
      rendered = Document.render!(doc, 0, format: :rgba8, dpi: 72)

      assert rendered.format == :rgba8
      assert byte_size(rendered.data) == rendered.width * rendered.height * 4
    end

    test "background: nil leaves uncovered pixels transparent", %{doc: doc} do
      opaque = Document.render!(doc, 0, format: :rgba8, dpi: 20)
      transparent = Document.render!(doc, 0, format: :rgba8, dpi: 20, background: nil)

      assert {255, 255, 255, 255} = pixel(opaque, 0, 0)
      assert {_, _, _, 0} = pixel(transparent, 0, 0)
    end

    test "a background colour is painted under the page", %{doc: doc} do
      blue = %Color.RGB{r: 0.0, g: 0.0, b: 1.0}
      rendered = Document.render!(doc, 0, format: :rgba8, dpi: 20, background: blue)

      assert {0, 0, 255, 255} = pixel(rendered, 0, 0)
    end

    test ":fit scales into the box and preserves the aspect ratio", %{doc: doc} do
      rendered = Document.render!(doc, 0, fit: {240, 320})

      assert rendered.width <= 240 and rendered.height <= 320
      assert rendered.width == 240
      assert_in_delta rendered.width / rendered.height, 612 / 792, 0.01
    end

    test ":region crops to the requested rectangle", %{doc: doc} do
      region = %Rect{x: 0.0, y: 0.0, width: 100.0, height: 80.0}
      rendered = Document.render!(doc, 0, region: region, dpi: 72)

      assert {rendered.width, rendered.height} == {100, 80}
    end

    test ":region is clipped to the page rather than slid onto it" do
      doc = Document.open!(@render_layers_pdf)
      on_exit(fn -> Document.close(doc) end)

      # Half the region lies outside this 200 pt page.
      clipped =
        Document.render!(doc, 0,
          dpi: 72,
          region: %Rect{x: -50.0, y: 0.0, width: 100.0, height: 80.0}
        )

      assert {clipped.width, clipped.height} == {50, 80}
    end

    test ":region with nothing on the page is out of range" do
      doc = Document.open!(@render_layers_pdf)
      on_exit(fn -> Document.close(doc) end)

      assert {:error, %Error{reason: :out_of_range}} =
               Document.render(doc, 0,
                 region: %Rect{x: 250.0, y: 0.0, width: 100.0, height: 80.0}
               )

      assert {:error, %Error{reason: :out_of_range}} =
               Document.render(doc, 0, region: %Rect{x: 10.0, y: 10.0, width: 0.0, height: 80.0})
    end

    test ":region is measured from the page's own origin" do
      doc = Document.open!(@media_box_pdf)
      on_exit(fn -> Document.close(doc) end)

      box = doc |> Document.page!(0) |> Page.media_box!()
      assert {box.x, box.y} == {10.0, 20.0}

      rendered = Document.render!(doc, 0, dpi: 72, region: box)

      assert {rendered.width, rendered.height} == {trunc(box.width), trunc(box.height)}
    end

    test ":region needs a readable /MediaBox where a plain render does not" do
      doc = Document.open!(@media_box_pdf)
      on_exit(fn -> Document.close(doc) end)

      boxless = doc.page_count - 1
      assert {:error, %Error{reason: :invalid_pdf}} = Page.media_box(Document.page!(doc, boxless))

      assert {:ok, _} = Document.render(doc, boxless, dpi: 20)

      assert {:error, %Error{reason: :invalid_pdf}} =
               Document.render(doc, boxless,
                 dpi: 20,
                 region: %Rect{x: 0.0, y: 0.0, width: 50.0, height: 50.0}
               )
    end

    test ":region follows a turned page into the raster's frame" do
      doc = Document.open!(@rotation_pdf)
      on_exit(fn -> Document.close(doc) end)

      box = doc |> Document.page!(0) |> Page.media_box!()
      assert doc |> Document.page!(0) |> Page.rotation!() == 90

      whole = Document.render!(doc, 0, dpi: 72, region: box)
      assert {whole.width, whole.height} == {trunc(box.height), trunc(box.width)}

      part =
        Document.render!(doc, 0,
          dpi: 72,
          region: %Rect{x: 0.0, y: 0.0, width: 100.0, height: 80.0}
        )

      assert {part.width, part.height} == {80, 100}
    end

    test "a quarter-turn page renders with its axes swapped" do
      doc = Document.open!(@rotation_pdf)
      on_exit(fn -> Document.close(doc) end)

      box = doc |> Document.page!(0) |> Page.media_box!()
      assert doc |> Document.page!(0) |> Page.rotation!() == 90

      rendered = Document.render!(doc, 0, dpi: 72)
      assert {rendered.width, rendered.height} == {trunc(box.height), trunc(box.width)}

      upright = Document.render!(doc, 3, dpi: 72)
      assert {upright.width, upright.height} == {trunc(box.width), trunc(box.height)}
    end

    test "reports an out-of-range page index", %{doc: doc} do
      assert {:error, %Error{reason: :out_of_range}} = Document.render(doc, 99)
    end

    test "reports a closed handle" do
      doc = Document.open!(@sample_pdf)
      Document.close(doc)

      assert {:error, %Error{reason: :closed}} = Document.render(doc, 0)
    end
  end

  describe "render/3 size limit" do
    setup :sample

    test "refuses a render too large to allocate", %{doc: doc} do
      assert {:error, %Error{reason: :unsupported, message: message}} =
               Document.render(doc, 0, dpi: 20_000)

      assert message =~ "170000x220000"
      assert message =~ "pixel limit"
    end

    test "a high but ordinary resolution is allowed", %{doc: doc} do
      rendered = Document.render!(doc, 0, dpi: 600)

      assert {rendered.width, rendered.height} == {5100, 6600}
    end

    test ":max_output_pixels renders the page smaller instead of refusing it", %{doc: doc} do
      rendered = Document.render!(doc, 0, dpi: 600, max_output_pixels: 4_000_000)

      assert {rendered.width, rendered.height} == {1759, 2276}
      assert byte_size(rendered.data) > 0
    end

    test ":max_output_pixels lets a constrained host ask for a page we would refuse",
         %{doc: doc} do
      assert {:error, %Error{reason: :unsupported}} = Document.render(doc, 0, dpi: 20_000)

      rendered = Document.render!(doc, 0, dpi: 20_000, max_output_pixels: 4_000_000)

      assert {rendered.width, rendered.height} == {1759, 2276}
    end

    test ":region refuses a budget that would shrink the page it crops", %{doc: doc} do
      region = %Rect{x: 0.0, y: 0.0, width: 100.0, height: 100.0}

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Document.render(doc, 0, dpi: 600, region: region, max_output_pixels: 4_000_000)

      assert message =~ ":max_output_pixels"

      cropped = Document.render!(doc, 0, dpi: 72, region: region, max_output_pixels: 4_000_000)
      assert {cropped.width, cropped.height} == {100, 100}
    end

    test "the ink planes a press-profiled page needs count against the limit" do
      doc = Document.open!(@spot_inks_pdf)
      on_exit(fn -> Document.close(doc) end)

      # Page 0 has eight spot inks and a CMYK output intent; page 1 has no spot inks.
      assert {:error, %Error{reason: :unsupported, message: message}} =
               Document.render(doc, 0, dpi: 600)

      assert message =~ "10 full-page buffers"

      assert %RenderedPage{} = Document.render!(doc, 1, dpi: 600)
      assert %RenderedPage{} = Document.render!(doc, 0, dpi: 150)
    end
  end

  describe "render/3 on a page with a crop box" do
    test "renders the crop box reduced to the medium" do
      doc = Document.open!(@crop_box_pdf)
      on_exit(fn -> Document.close(doc) end)

      # Page 0 is /MediaBox [0 0 612 792] with /CropBox [10 20 210 320].
      rendered = Document.render!(doc, 0, dpi: 72)

      assert {rendered.width, rendered.height} == {200, 300}
    end

    test "the size limit measures that box and not the medium" do
      doc = Document.open!(@crop_box_pdf)
      on_exit(fn -> Document.close(doc) end)

      # 200 x 300 pt at 600 DPI is 1667 x 2500 = 4.2 Mpx, inside the budget;
      # the 612 x 792 medium would be 33.7 Mpx and refused.
      rendered = Document.render!(doc, 0, dpi: 600, max_output_pixels: 5_000_000)

      assert {rendered.width, rendered.height} == {1667, 2500}
    end

    test ":region crops the area it names, in the page's own frame" do
      doc = Document.open!(@cropped_content_pdf)
      on_exit(fn -> Document.close(doc) end)

      # The visible area is 50,40 .. 150,140; its left half is filled.
      left =
        Document.render!(doc, 0,
          dpi: 72,
          region: %Rect{x: 50.0, y: 40.0, width: 50.0, height: 100.0}
        )

      assert {left.width, left.height} == {50, 100}
    end

    test ":region reports a rect that is on the medium but outside the crop box" do
      doc = Document.open!(@cropped_content_pdf)
      on_exit(fn -> Document.close(doc) end)

      region = %Rect{x: 0.0, y: 0.0, width: 40.0, height: 30.0}

      assert {:error, %Error{reason: :out_of_range}} =
               Document.render(doc, 0, dpi: 72, region: region)
    end

    test ":fit scales by the medium, so a cropped page stops short of the box" do
      doc = Document.open!(@cropped_content_pdf)
      on_exit(fn -> Document.close(doc) end)

      rendered = Document.render!(doc, 0, fit: {400, 400})

      assert {rendered.width, rendered.height} == {200, 200}
    end
  end

  describe "render/3 rejected options" do
    setup :sample

    test "an unknown key names itself", %{doc: doc} do
      assert_raise ArgumentError, ~r/no_such_option/, fn ->
        Document.render(doc, 0, no_such_option: true)
      end
    end

    test ":dpi must be a positive integer", %{doc: doc} do
      assert_raise ArgumentError, ~r/:dpi/, fn -> Document.render(doc, 0, dpi: 0) end
      assert_raise ArgumentError, ~r/:dpi/, fn -> Document.render(doc, 0, dpi: -10) end
      assert_raise ArgumentError, ~r/:dpi/, fn -> Document.render(doc, 0, dpi: 1.5) end
    end

    test ":jpeg_quality is range-checked rather than clamped", %{doc: doc} do
      assert_raise ArgumentError, ~r/:jpeg_quality/, fn ->
        Document.render(doc, 0, jpeg_quality: 0)
      end

      assert_raise ArgumentError, ~r/:jpeg_quality/, fn ->
        Document.render(doc, 0, jpeg_quality: 101)
      end
    end

    test "an integer component is as good as a float", %{doc: doc} do
      rendered =
        Document.render!(doc, 0,
          format: :rgba8,
          dpi: 20,
          background: %Color.RGB{r: 0, g: 0, b: 1}
        )

      assert {0, 0, 255, 255} = pixel(rendered, 0, 0)
    end

    test ":background is range-checked rather than replaced with white", %{doc: doc} do
      out_of_range = %Color.RGB{r: 2.0, g: 0.0, b: 0.0}

      assert_raise ArgumentError, ~r/:background/, fn ->
        Document.render(doc, 0, background: out_of_range)
      end

      assert_raise ArgumentError, ~r/:background/, fn ->
        Document.render(doc, 0, background: "white")
      end
    end

    test ":fit must be a pair of positive integers", %{doc: doc} do
      assert_raise ArgumentError, ~r/:fit/, fn -> Document.render(doc, 0, fit: {0, 100}) end
      assert_raise ArgumentError, ~r/:fit/, fn -> Document.render(doc, 0, fit: {100, -1}) end
      assert_raise ArgumentError, ~r/:fit/, fn -> Document.render(doc, 0, fit: 100) end
    end

    test ":fit and :region cannot be combined", %{doc: doc} do
      region = %Rect{x: 0.0, y: 0.0, width: 10.0, height: 10.0}

      assert_raise ArgumentError, ~r/:fit and :region/, fn ->
        Document.render(doc, 0, fit: {10, 10}, region: region)
      end
    end

    test ":fit and :dpi cannot be combined", %{doc: doc} do
      assert_raise ArgumentError, ~r/:dpi has no effect with :fit/, fn ->
        Document.render(doc, 0, fit: {10, 10}, dpi: 72)
      end
    end

    test ":region cannot be combined with the :rgba8 format", %{doc: doc} do
      region = %Rect{x: 0.0, y: 0.0, width: 10.0, height: 10.0}

      assert_raise ArgumentError, ~r/:region cannot be given with format: :rgba8/, fn ->
        Document.render(doc, 0, region: region, format: :rgba8)
      end
    end

    test "an explicit nil for either is not a combination", %{doc: doc} do
      assert %RenderedPage{} = Document.render!(doc, 0, dpi: 20, fit: nil, region: nil)

      assert_raise ArgumentError, ~r/:dpi must be a positive integer/, fn ->
        Document.render(doc, 0, fit: {32, 32}, dpi: nil)
      end
    end
  end

  describe "layers" do
    setup do
      doc = Document.open!(@render_layers_pdf)
      on_exit(fn -> Document.close(doc) end)

      # The fixture's two filled rectangles, sampled at 72 DPI on a 200pt page:
      # one inside each layer's marked-content scope.
      {:ok, doc: doc, shown: {50, 30}, hidden: {50, 140}}
    end

    test "a group the document marks off by default is not painted", %{doc: doc} = ctx do
      rendered = Document.render!(doc, 0, dpi: 72, format: :rgba8)
      {shown_col, shown_row} = ctx.shown
      {hidden_col, hidden_row} = ctx.hidden

      assert {0, 0, 0, 255} = pixel(rendered, shown_col, shown_row)
      assert {255, 255, 255, 255} = pixel(rendered, hidden_col, hidden_row)
    end

    test ":exclude_layers suppresses a group that is on by default", %{doc: doc} = ctx do
      rendered =
        Document.render!(doc, 0, dpi: 72, format: :rgba8, exclude_layers: ["Shown Layer"])

      {shown_col, shown_row} = ctx.shown
      assert {255, 255, 255, 255} = pixel(rendered, shown_col, shown_row)
    end

    test "a name matching no group changes nothing", %{doc: doc} do
      base = Document.render!(doc, 0, dpi: 72)
      unknown = Document.render!(doc, 0, dpi: 72, exclude_layers: ["no such layer"])

      assert base.data == unknown.data
    end

    test "every name layers/1 reports is one :exclude_layers matches" do
      doc = Document.open!(@layers_pdf)
      on_exit(fn -> Document.close(doc) end)

      base = Document.render!(doc, 0, dpi: 36)
      # Page 0 paints inside the UTF-16BE-named group.
      filtered = Document.render!(doc, 0, dpi: 36, exclude_layers: ["Ü-Layer"])

      assert "Ü-Layer" in Document.layers!(doc)
      refute base.data == filtered.data
    end
  end

  describe "separations/3" do
    setup do
      doc = Document.open!(@layers_pdf)
      on_exit(fn -> Document.close(doc) end)

      {:ok, doc: doc}
    end

    test "yields the process inks plus every ink reachable from the page", %{doc: doc} do
      plates = Document.separations!(doc, 0, dpi: 36)
      names = Enum.map(plates, & &1.ink)

      assert Enum.take(names, 4) == ["Cyan", "Magenta", "Yellow", "Black"]
      assert Enum.drop(names, 4) == Document.inks!(doc, 0, deep: true)
    end

    test "a plate is one byte of coverage per pixel", %{doc: doc} do
      [plate | _] = Document.separations!(doc, 0, dpi: 36)

      assert %SeparationPlate{} = plate
      assert byte_size(plate.data) == plate.width * plate.height
    end

    test "an ink the page paints has coverage and one it declares only does not", %{doc: doc} do
      plates = Document.separations!(doc, 0, dpi: 36)

      coverage =
        Map.new(plates, fn plate -> {plate.ink, Enum.max(:binary.bin_to_list(plate.data))} end)

      # The fixture's page 0 paints with all three spot inks, one of them through
      # a nested Form XObject, and uses no process colour at all.
      assert coverage["PageInk"] > 0
      assert coverage["NestedInk"] > 0
      assert coverage["Black"] == 0
    end

    test "separation/4 renders one named plate", %{doc: doc} do
      one = Document.separation!(doc, 0, "PageInk", dpi: 36)
      [same] = doc |> Document.separations!(0, dpi: 36) |> Enum.filter(&(&1.ink == "PageInk"))

      assert one.ink == "PageInk"
      assert {one.width, one.height} == {same.width, same.height}
      assert one.data == same.data
    end

    test "an ink the page never paints still yields an all-zero plate", %{doc: doc} do
      plate = Document.separation!(doc, 0, "PANTONE 448 C", dpi: 36)

      assert plate.ink == "PANTONE 448 C"
      assert byte_size(plate.data) == plate.width * plate.height
      assert Enum.max(:binary.bin_to_list(plate.data)) == 0
    end

    test "reports an out-of-range page index", %{doc: doc} do
      assert {:error, %Error{reason: :out_of_range}} = Document.separations(doc, 99)
      assert {:error, %Error{reason: :out_of_range}} = Document.separation(doc, 99, "Cyan")
    end

    test ":dpi is validated the same way as for a render", %{doc: doc} do
      assert_raise ArgumentError, ~r/:dpi/, fn -> Document.separations(doc, 0, dpi: 0) end

      assert_raise ArgumentError, ~r/no_such_option/, fn ->
        Document.separations(doc, 0, no_such_option: 1)
      end
    end
  end

  describe "separations/3 and separation/4 size limit" do
    setup do
      doc = Document.open!(@spot_inks_pdf)
      on_exit(fn -> Document.close(doc) end)

      {:ok, doc: doc}
    end

    # Page 0 declares eight spot inks in addition to the four process inks.
    test "the whole plate set is budgeted together", %{doc: doc} do
      assert {:error, %Error{reason: :unsupported, message: message}} =
               Document.separations(doc, 0, dpi: 600)

      assert message =~ "12 full-page buffers"
    end

    # A single plate fits the cap; the full sidecar must trigger this refusal.
    test "one named plate is budgeted by the whole set too", %{doc: doc} do
      assert {:error, %Error{reason: :unsupported, message: message}} =
               Document.separation(doc, 0, "Cyan", dpi: 600)

      assert message =~ "12 full-page buffers"
    end

    test "the same page fits once there is room for its plates", %{doc: doc} do
      assert length(Document.separations!(doc, 0, dpi: 150)) == 12
    end

    test "a page declaring no spot inks fits at that resolution", %{doc: doc} do
      assert length(Document.separations!(doc, 1, dpi: 300)) == 4
    end

    test "a plate over the limit this call cannot raise is refused", %{doc: doc} do
      assert {:error, %Error{reason: :unsupported, message: message}} =
               Document.separations(doc, 1, dpi: 600)

      assert message =~ "cannot raise"

      assert {:error, %Error{reason: :unsupported}} =
               Document.separation(doc, 1, "Cyan", dpi: 600)
    end
  end

  describe "rasterize/2" do
    setup :sample

    test "returns a PDF of the same length with no text left in it", %{doc: doc} do
      flat = Document.rasterize!(doc, dpi: 36)
      rasterized = Document.from_binary!(flat)
      on_exit(fn -> Document.close(rasterized) end)

      assert Document.page_count!(rasterized) == doc.page_count

      assert String.trim(Document.text!(doc, 0)) != ""
      assert String.trim(Document.text!(rasterized, 0)) == ""
    end

    test "re-pages to US Letter inside a one-inch margin, whatever the source" do
      small = Document.open!(@render_layers_pdf)
      on_exit(fn -> Document.close(small) end)

      source_box = small |> Document.page!(0) |> Page.media_box!()
      assert {source_box.width, source_box.height} == {200.0, 200.0}

      flat = small |> Document.rasterize!(dpi: 72) |> Document.from_binary!()
      on_exit(fn -> Document.close(flat) end)

      box = flat |> Document.page!(0) |> Page.media_box!()
      assert {box.width, box.height} == {612.0, 792.0}

      [image] = Document.images!(flat, 0)
      assert image.bbox.x == 72.0
      assert image.bbox.width == 612.0 - 2 * 72.0
    end

    test "bakes page rotation into the pixels and resets /Rotate" do
      turned = Document.open!(@rotation_pdf)
      on_exit(fn -> Document.close(turned) end)

      assert turned |> Document.page!(0) |> Page.rotation!() == 90

      flat = turned |> Document.rasterize!(dpi: 36) |> Document.from_binary!()
      on_exit(fn -> Document.close(flat) end)

      assert flat |> Document.page!(0) |> Page.rotation!() == 0
    end

    test ":dpi is validated", %{doc: doc} do
      assert_raise ArgumentError, ~r/:dpi/, fn -> Document.rasterize(doc, dpi: 0) end
    end

    test "the size limit measures the pages the renderer will see" do
      doc = Document.open!(@inherited_boxes_pdf)
      on_exit(fn -> Document.close(doc) end)

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Document.rasterize(doc, dpi: 4000)

      # Page 0 inherits a 260 x 460 crop box rather than the 612 x 792 fallback.
      assert message =~ "14445x25556"
    end

    test "a page over the limit this call cannot raise is refused", %{doc: doc} do
      assert {:error, %Error{reason: :unsupported, message: message}} =
               Document.rasterize(doc, dpi: 600)

      assert message =~ "cannot raise"
    end

    test "reports a closed handle" do
      doc = Document.open!(@sample_pdf)
      Document.close(doc)

      assert {:error, %Error{reason: :closed}} = Document.rasterize(doc)
    end
  end

  describe "Page delegation" do
    setup :sample

    test "render/2 matches the document-level call", %{doc: doc} do
      page = Document.page!(doc, 1)

      assert Page.render!(page, dpi: 36).data == Document.render!(doc, 1, dpi: 36).data
    end

    test "separations/2 and separation/3 match the document-level calls" do
      doc = Document.open!(@layers_pdf)
      on_exit(fn -> Document.close(doc) end)

      page = Document.page!(doc, 0)

      assert Enum.map(Page.separations!(page, dpi: 36), & &1.ink) ==
               Enum.map(Document.separations!(doc, 0, dpi: 36), & &1.ink)

      assert Page.separation!(page, "PageInk", dpi: 36).data ==
               Document.separation!(doc, 0, "PageInk", dpi: 36).data
    end
  end

  describe "structs" do
    setup :sample

    test "a rendered page inspects without its blob", %{doc: doc} do
      # 18 DPI gives an exact binary scale for stable dimensions.
      rendered = Document.render!(doc, 0, dpi: 18)

      assert inspect(rendered) == "#PdfElixide.Document.RenderedPage<153x198 png>"
    end

    test "a plate inspects with its ink name" do
      doc = Document.open!(@layers_pdf)
      on_exit(fn -> Document.close(doc) end)

      plate = Document.separation!(doc, 0, "PageInk", dpi: 36)

      assert inspect(plate) =~ ~s(#PdfElixide.Document.SeparationPlate<"PageInk" )
    end
  end
end
