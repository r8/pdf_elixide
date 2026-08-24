defmodule PdfElixide.DocRefsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  # ExDoc resolves an unqualified `fun/arity` against the module the doc block
  # sits in, and renders one that does not resolve as plain text — no link, and
  # no warning even under `mix docs --warnings-as-errors`. A reference that
  # drifts onto the wrong module is therefore invisible in CI and in the built
  # HTML alike, which is what this test exists to catch.

  # Deliberate non-references: the prose asserts the function's *absence*, or
  # names a callback of another module by its bare name. Add to this only with a
  # reason — the default answer to a failure here is to qualify the reference.
  @allowed [
    {PdfElixide.Document.Page, "Page.close/1"},
    {PdfElixide.Document.Table, "close!/1"},
    {PdfElixide.Logging, "start/2"}
  ]

  # A whole backticked span, so prose that merely contains a slash cannot match.
  # `\w` would let `1/2` through as a function named "1", hence the leading
  # lowercase class. The trailing `,` form covers `flatten/1,2`.
  @ref ~r/^(?:(t|c):)?(?:([A-Z][\w.]*)\.)?([a-z_]\w*[?!]?)\/(\d+(?:,\d+)*)$/

  defp modules do
    {:ok, modules} = :application.get_key(:pdf_elixide, :modules)
    modules
  end

  defp doc_strings(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, module_doc, _, docs} ->
        [text(module_doc) | Enum.map(docs, fn {_, _, _, doc, _} -> text(doc) end)]

      _ ->
        []
    end
  end

  defp text(%{} = doc), do: Map.get(doc, "en", "")
  defp text(_), do: ""

  defp refs(module) do
    module
    |> doc_strings()
    |> Enum.flat_map(&Regex.scan(~r/`([^`\n]+)`/, &1, capture: :all_but_first))
    |> Enum.flat_map(fn [span] -> parse(module, span) end)
    |> Enum.uniq()
  end

  defp parse(module, span) do
    case Regex.run(@ref, span, capture: :all_but_first) do
      [sigil, mod, name, arities] ->
        for arity <- String.split(arities, ","),
            do: {span, sigil, target(module, mod), String.to_atom(name), String.to_integer(arity)}

      nil ->
        []
    end
  end

  defp target(module, ""), do: module
  defp target(_module, mod), do: Module.concat([mod])

  defp resolves?({_span, sigil, module, name, arity}) do
    Code.ensure_loaded?(module) and resolves?(sigil, module, name, arity)
  end

  defp resolves?(sigil, module, name, arity) when sigil in ["t", "c"] do
    kind = if sigil == "t", do: :type, else: :callback

    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, _, _, docs} ->
        Enum.any?(docs, &match?({{^kind, ^name, ^arity}, _, _, _, _}, &1))

      _ ->
        false
    end
  end

  defp resolves?(_sigil, module, name, arity) do
    function_exported?(module, name, arity) or macro_exported?(module, name, arity)
  end

  test "every function, type and callback reference in a doc block resolves" do
    unresolved =
      for module <- modules(),
          ref <- refs(module),
          {span, _, _, _, _} = ref,
          {module, span} not in @allowed,
          not resolves?(ref),
          do: "#{inspect(module)}: `#{span}`"

    assert unresolved == []
  end

  # Without this the test above passes vacuously if the scan or the docs chunk
  # ever stops yielding anything.
  test "the scan finds references to check" do
    assert length(Enum.flat_map(modules(), &refs/1)) > 100
  end
end
