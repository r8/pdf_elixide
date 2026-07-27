defmodule PdfElixide.Document.XmpMetadata do
  @moduledoc """
  XMP (Extensible Metadata Platform) metadata — the XML-based metadata packet a
  PDF may carry in addition to, or instead of, the `/Info` dictionary
  (`PdfElixide.Document.Metadata`).

  Obtain it with `PdfElixide.Document.xmp_metadata/1`, which returns `nil` when
  the document has no XMP packet. Field names drop the XMP namespace prefixes
  (`dc:` / `xmp:` / `pdf:` / `xmpRights:`).

  ## Fields

    * `:title`, `:description` — Dublin Core `dc:title` / `dc:description`.
    * `:creators`, `:subjects` — Dublin Core `dc:creator` / `dc:subject` as lists
      (XMP models these as ordered arrays).
    * `:language`, `:rights`, `:format` — `dc:language` / `dc:rights` /
      `dc:format`.
    * `:creator_tool` — `xmp:CreatorTool`.
    * `:create_date`, `:modify_date`, `:metadata_date` — `xmp:CreateDate` /
      `xmp:ModifyDate` / `xmp:MetadataDate` (raw XMP date strings).
    * `:producer`, `:keywords`, `:pdf_version`, `:trapped` — the `pdf:` namespace.
    * `:rights_usage_terms`, `:rights_marked`, `:rights_web_statement` — the
      `xmpRights:` namespace (`:rights_marked` is a boolean or `nil`).
    * `:custom` — a map of any other `namespace:property => value` pairs.
    * `:raw_xml` — the original XMP packet as a string, or `nil`.
  """

  @enforce_keys [
    :title,
    :creators,
    :description,
    :subjects,
    :language,
    :rights,
    :format,
    :creator_tool,
    :create_date,
    :modify_date,
    :metadata_date,
    :producer,
    :keywords,
    :pdf_version,
    :trapped,
    :rights_usage_terms,
    :rights_marked,
    :rights_web_statement,
    :custom,
    :raw_xml
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          title: String.t() | nil,
          creators: [String.t()],
          description: String.t() | nil,
          subjects: [String.t()],
          language: String.t() | nil,
          rights: String.t() | nil,
          format: String.t() | nil,
          creator_tool: String.t() | nil,
          create_date: String.t() | nil,
          modify_date: String.t() | nil,
          metadata_date: String.t() | nil,
          producer: String.t() | nil,
          keywords: String.t() | nil,
          pdf_version: String.t() | nil,
          trapped: String.t() | nil,
          rights_usage_terms: String.t() | nil,
          rights_marked: boolean() | nil,
          rights_web_statement: String.t() | nil,
          custom: %{String.t() => String.t()},
          raw_xml: String.t() | nil
        }

  @doc false
  # Builds an `XmpMetadata` from the raw map returned by the NIF. Fields already
  # arrive in their final shape (strings, lists, a map, and `nil`s).
  @spec from_nif(map()) :: t()
  def from_nif(%{
        title: title,
        creators: creators,
        description: description,
        subjects: subjects,
        language: language,
        rights: rights,
        format: format,
        creator_tool: creator_tool,
        create_date: create_date,
        modify_date: modify_date,
        metadata_date: metadata_date,
        producer: producer,
        keywords: keywords,
        pdf_version: pdf_version,
        trapped: trapped,
        rights_usage_terms: rights_usage_terms,
        rights_marked: rights_marked,
        rights_web_statement: rights_web_statement,
        custom: custom,
        raw_xml: raw_xml
      }) do
    %__MODULE__{
      title: title,
      creators: creators,
      description: description,
      subjects: subjects,
      language: language,
      rights: rights,
      format: format,
      creator_tool: creator_tool,
      create_date: create_date,
      modify_date: modify_date,
      metadata_date: metadata_date,
      producer: producer,
      keywords: keywords,
      pdf_version: pdf_version,
      trapped: trapped,
      rights_usage_terms: rights_usage_terms,
      rights_marked: rights_marked,
      rights_web_statement: rights_web_statement,
      custom: custom,
      raw_xml: raw_xml
    }
  end
end
