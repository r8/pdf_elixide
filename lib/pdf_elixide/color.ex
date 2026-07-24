defmodule PdfElixide.Color do
  @moduledoc """
  The color values returned by extraction, one struct per colorspace.

    * `PdfElixide.Color.RGB` — three channels (DeviceRGB).
    * `PdfElixide.Color.CMYK` — four channels (DeviceCMYK).
    * `PdfElixide.Color.Gray` — one channel (DeviceGray).
    * `PdfElixide.Color.Unknown` — components whose colorspace we can't identify.

  Every channel is in the `0.0..1.0` range.

  ## Which shapes appear where

  Text and vector graphics — `PdfElixide.Document.Char`,
  `PdfElixide.Document.Span`, `PdfElixide.Document.Path` — are always
  `PdfElixide.Color.RGB`, never the other structs. Upstream `pdf_oxide` resolves
  every colorspace (CMYK, Lab, Separation, ICCBased) to DeviceRGB while
  extracting, so the original colorspace is gone before it reaches Elixir. Those
  fields are typed `PdfElixide.Color.RGB.t()` rather than `t:t/0` to say so.

  `PdfElixide.Document.Annotation` is the exception: its `:color` and
  `:interior_color` carry the raw `/C` and `/IC` component arrays, so any of the
  four structs can appear there.
  """
  alias PdfElixide.Color.{CMYK, Gray, RGB, Unknown}

  @typedoc """
  Any extracted color.

  See the module documentation for which of these can appear on which field.
  """
  @type t :: RGB.t() | CMYK.t() | Gray.t() | Unknown.t()
end
