defmodule PdfElixide.Document.Annotation.Flags do
  @moduledoc """
  Decoded `/F` annotation flags (ISO 32000-1 §12.5.3, Table 165).

  These flags control how an annotation is displayed and printed. Each is exposed
  as a boolean; `:raw` carries the undecoded `/F` integer for callers that need
  the original bit value.

  ## Fields

    * `:invisible` — do not display the annotation if it has no handler and no
      appearance stream.
    * `:hidden` — do not display or print the annotation.
    * `:print` — print the annotation when the page is printed.
    * `:no_zoom` — do not scale the annotation with the page zoom.
    * `:no_rotate` — do not rotate the annotation with the page.
    * `:no_view` — do not display the annotation on screen (it may still print).
    * `:read_only` — do not allow the user to interact with the annotation.
    * `:locked` — do not allow the annotation to be deleted or its properties
      changed.
    * `:toggle_no_view` — invert `:no_view` for certain events (e.g. mouse-over).
    * `:locked_contents` — do not allow the annotation's contents to be modified.
    * `:raw` — the raw `/F` integer.
  """

  @enforce_keys [
    :invisible,
    :hidden,
    :print,
    :no_zoom,
    :no_rotate,
    :no_view,
    :read_only,
    :locked,
    :toggle_no_view,
    :locked_contents,
    :raw
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          invisible: boolean(),
          hidden: boolean(),
          print: boolean(),
          no_zoom: boolean(),
          no_rotate: boolean(),
          no_view: boolean(),
          read_only: boolean(),
          locked: boolean(),
          toggle_no_view: boolean(),
          locked_contents: boolean(),
          raw: non_neg_integer()
        }
end
