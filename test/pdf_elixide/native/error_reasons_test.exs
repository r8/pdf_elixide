defmodule PdfElixide.Native.ErrorReasonsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias PdfElixide.Error

  test "the NIF's reason atoms are the reasons the Elixir side accepts" do
    nif = PdfElixide.NifSource.error_reasons()

    assert Enum.sort(nif) == Enum.sort(Error.__reasons__()),
           """
           The "Error reason tags" group in lib.rs and `@reasons` in
           `PdfElixide.Error` disagree. A reason the NIF raises but `@reasons`
           lacks makes `Wrap.call/1` re-raise it as an `ErlangError`.

             only in lib.rs: #{inspect(nif -- Error.__reasons__())}
             only in Error:  #{inspect(Error.__reasons__() -- nif)}
           """
  end

  test "the reason typespec is the reason list" do
    {:ok, types} = Code.Typespec.fetch_types(Error)
    [union] = for {:type, {:reason, union, []}} <- types, do: union

    assert union_atoms(union) == Error.__reasons__()
  end

  test "the moduledoc documents every reason" do
    {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Error)

    [_, section] = String.split(moduledoc, "## Reasons", parts: 2)
    [section | _] = String.split(section, "\n## ", parts: 2)

    documented =
      for [_, name] <- Regex.scan(~r/^\s*\* `:(\w+)`/m, section), do: String.to_atom(name)

    assert documented == Error.__reasons__()
  end

  defp union_atoms({:type, _, :union, members}), do: Enum.flat_map(members, &union_atoms/1)
  defp union_atoms({:atom, _, atom}), do: [atom]
end
