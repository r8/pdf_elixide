defmodule PdfElixide.DocGroupsTest do
  @moduledoc """
  The HexDocs sidebar inventory, pinned against `lib/`.

  `mix.exs` sorts every public module into a named group so the sidebar reads
  as the API is organised rather than as one flat alphabetical list. The
  grouping is a hand-written list of module names, which is the whole reason
  this file exists: ExDoc does not complain about a module no group claims, it
  quietly appends it to a trailing "Modules" bucket, and nobody notices until
  they look at published docs. So the failure this pins is a *silent* one.

  Three things are asserted, each catching a different mistake:

    * every module carrying a real `@moduledoc` appears in some group — a new
      public module that nobody placed fails here;
    * no module appears in two groups — a copy-paste while moving one between
      groups fails here;
    * no group names a module that is gone or has become `@moduledoc false` —
      a rename or a module made private fails here.

  Membership is derived from the compiled docs chunk rather than a hardcoded
  skip list: `@moduledoc false` reports `:hidden` and a missing one `:none`, so
  `PdfElixide.Native` and `PdfElixide.Native.Wrap` drop out on their own, and a
  module that *becomes* internal stops being required here without an edit.

  Nothing here asserts which group a module belongs in. That is an editorial
  call, and pinning it would only mean writing the same list twice.
  """
  use ExUnit.Case, async: true

  defp groups do
    Mix.Project.config()
    |> Keyword.fetch!(:docs)
    |> Keyword.fetch!(:groups_for_modules)
  end

  defp grouped_modules, do: Enum.flat_map(groups(), fn {_group, modules} -> modules end)

  defp documented_modules do
    {:ok, modules} = :application.get_key(:pdf_elixide, :modules)
    Enum.filter(modules, &documented?/1)
  end

  # `:hidden` is `@moduledoc false`, `:none` is no moduledoc at all, and an
  # `{:error, _}` return means the docs chunk was stripped — none of which ExDoc
  # would render.
  defp documented?(module) do
    match?({:docs_v1, _, _, _, %{}, _, _}, Code.fetch_docs(module))
  end

  test "every documented module is placed in a group" do
    assert documented_modules() -- grouped_modules() == []
  end

  test "no module is placed in two groups" do
    grouped = grouped_modules()

    assert grouped -- Enum.uniq(grouped) == []
  end

  # Deduplicated first: `--` removes one occurrence per element, so a module
  # listed twice would survive the subtraction and report here as well, which is
  # a different defect and has its own test above.
  test "no group names a module that is absent or undocumented" do
    assert Enum.uniq(grouped_modules()) -- documented_modules() == []
  end
end
