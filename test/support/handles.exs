defmodule PdfElixide.Handles do
  @moduledoc false

  # Handles that close when the test ends, so call these from a test or its
  # setup, never from `setup_all`.

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias PdfElixide.Builder
  alias PdfElixide.Document
  alias PdfElixide.Editor

  def open(path, opts \\ []), do: path |> Document.open!(opts) |> closing()

  def open_editor(path, opts \\ []), do: path |> Editor.open!(opts) |> closing()

  def written(%Editor{} = editor), do: editor |> Editor.to_binary!() |> reopened()
  def written(%Builder{} = builder), do: builder |> Builder.to_binary!() |> reopened()

  defp reopened(bytes), do: bytes |> Document.from_binary!() |> closing()

  defp closing(%Document{} = doc) do
    on_exit(fn -> Document.close(doc) end)
    doc
  end

  defp closing(%Editor{} = editor) do
    on_exit(fn -> Editor.close(editor) end)
    editor
  end
end
