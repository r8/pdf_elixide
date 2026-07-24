defmodule PdfElixide.Document.Annotation do
  @moduledoc """
  A single annotation on a PDF page — a link, sticky note, highlight, form
  widget, stamp, and so on — with its zero-based `:page` index.

  Obtain annotations with `PdfElixide.Document.annotations/1` (whole document) or
  `PdfElixide.Document.annotations/2` (a single page).

  `:subtype` is the parsed annotation kind as an atom (`:link`, `:text`,
  `:highlight`, `:widget`, `:three_d`, `:unknown`, …); `:raw_subtype` preserves
  the original `/Subtype` name, which is useful when `:subtype` is `:unknown`.
  `:rect` is the annotation's bounding box as a `PdfElixide.Geometry.Rect`.

  Several fields are populated only for particular subtypes:

    * `:destination` / `:action` — `:link` annotations (where the link points).
    * `:quad_points` — text-markup annotations (`:highlight`, `:underline`,
      `:squiggly`, `:strike_out`); each quad is a list of eight numbers.
    * `:field_type`, `:field_name`, `:field_value`, `:default_value`,
      `:field_flags`, `:options`, `:appearance_state` — `:widget` (form field)
      annotations. For richer form-field access see `PdfElixide.Form`.

  `:color` and `:interior_color` are decoded from the raw `/C` and `/IC`
  component arrays into a colorspace-tagged term (see `t:color/0`).
  """
  alias PdfElixide.Document.Annotation
  alias PdfElixide.Document.Annotation.Flags
  alias PdfElixide.Geometry.Rect

  @typedoc """
  Where a link annotation points.

    * `{:named, name}` — a named destination (unresolved name string).
    * `{:explicit, page, fit_type, params}` — a zero-based target page, a fit
      type (`"XYZ"`, `"Fit"`, `"FitH"`, …), and its numeric parameters.
  """
  @type destination ::
          {:named, String.t()}
          | {:explicit, page :: non_neg_integer(), fit_type :: String.t(), params :: [float()]}

  @typedoc """
  A link annotation's action.

    * `{:uri, url}` — open a web URL.
    * `{:goto, destination}` — jump to a destination in this document.
    * `{:goto_remote, file, destination | nil}` — jump into another file.
    * `{:other, action_type}` — any other action, carrying its `/S` name.
  """
  @type action ::
          {:uri, String.t()}
          | {:goto, destination()}
          | {:goto_remote, file :: String.t(), destination() | nil}
          | {:other, action_type :: String.t()}

  @typedoc """
  A widget form field's type.

    * `:text`, `:button`, `:signature`, `:unknown` — bare kinds.
    * `{:checkbox, checked?}` — a checkbox and whether it is checked.
    * `{:radio, selected | nil}` — a radio button and its selected value.
    * `{:choice, options, selected | nil}` — a dropdown/list and its choices.
  """
  @type field_type ::
          :text
          | :button
          | :signature
          | :unknown
          | {:checkbox, boolean()}
          | {:radio, String.t() | nil}
          | {:choice, [String.t()], String.t() | nil}

  @typedoc """
  An annotation color, decoded from the raw `/C` (or `/IC`) component array by
  its length:

    * `:transparent` — an empty array.
    * `{:gray, g}` — one component (DeviceGray).
    * `{:rgb, r, g, b}` — three components (DeviceRGB).
    * `{:cmyk, c, m, y, k}` — four components (DeviceCMYK).
    * `{:other, components}` — any other length (preserved verbatim).

  Each component is in the `0.0..1.0` range.
  """
  @type color ::
          :transparent
          | {:gray, float()}
          | {:rgb, float(), float(), float()}
          | {:cmyk, float(), float(), float(), float()}
          | {:other, [float()]}

  @enforce_keys [
    :page,
    :type,
    :subtype,
    :raw_subtype,
    :contents,
    :rect,
    :author,
    :subject,
    :creation_date,
    :modification_date,
    :destination,
    :action,
    :quad_points,
    :color,
    :interior_color,
    :opacity,
    :flags,
    :border,
    :field_type,
    :field_name,
    :field_value,
    :default_value,
    :field_flags,
    :options,
    :appearance_state
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          page: non_neg_integer(),
          type: String.t(),
          subtype: atom(),
          raw_subtype: String.t() | nil,
          contents: String.t() | nil,
          rect: Rect.t() | nil,
          author: String.t() | nil,
          subject: String.t() | nil,
          creation_date: String.t() | nil,
          modification_date: String.t() | nil,
          destination: destination() | nil,
          action: action() | nil,
          quad_points: [[float()]] | nil,
          color: color() | nil,
          interior_color: color() | nil,
          opacity: float() | nil,
          flags: Flags.t(),
          border: [float()] | nil,
          field_type: field_type() | nil,
          field_name: String.t() | nil,
          field_value: String.t() | nil,
          default_value: String.t() | nil,
          field_flags: non_neg_integer() | nil,
          options: [String.t()] | nil,
          appearance_state: String.t() | nil
        }

  @doc false
  # Builds an `Annotation` from the raw map returned by the NIF. Every field
  # already arrives in its final shape (subtype as an atom, `rect`/`flags` as
  # structs, destination/action/field_type/color as tagged terms); only
  # `annotation_type` is renamed to the `:type` field.
  @spec from_nif(map()) :: t()
  def from_nif(map) when is_map(map) do
    {type, rest} = Map.pop(map, :annotation_type)
    struct(__MODULE__, Map.put(rest, :type, type))
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Annotation{page: page, subtype: subtype}, _opts) do
      concat([
        "#PdfElixide.Document.Annotation<p",
        to_string(page),
        " ",
        inspect(subtype),
        ">"
      ])
    end
  end
end
