defmodule PdfElixide.DocGroupsTest do
  @moduledoc false
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

  # Function groups: the modules whose HexDocs page lists enough functions to
  # need sections. A function missing its `@doc group:` lands in ExDoc's
  # ungrouped "Functions" bucket with no warning, the same silence as an
  # unplaced module.
  @function_grouped_modules [PdfElixide.Document, PdfElixide.Editor, PdfElixide.Document.Page]

  defp function_groups do
    Mix.Project.config()
    |> Keyword.fetch!(:docs)
    |> Keyword.fetch!(:groups_for_docs)
    |> Enum.map(fn {group, _filter} -> group end)
  end

  # `:hidden` is `@doc false`; `:none` (no `@doc` at all) is kept so an
  # undocumented public function reports here too.
  defp function_group_assignments(module) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(module)

    for {{:function, name, arity}, _, _, doc, meta} <- docs, doc != :hidden do
      {{module, name, arity}, meta[:group]}
    end
  end

  test "every documented function in the grouped modules carries a configured group" do
    groups = function_groups()

    unplaced =
      for module <- @function_grouped_modules,
          {fun, group} <- function_group_assignments(module),
          group not in groups,
          do: {fun, group}

    assert unplaced == []
  end

  test "every configured function group is carried by some function" do
    used =
      for module <- @function_grouped_modules,
          {_fun, group} <- function_group_assignments(module),
          uniq: true,
          do: group

    assert function_groups() -- used == []
  end
end
