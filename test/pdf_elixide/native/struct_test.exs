defmodule PdfElixide.Native.StructTest do
  @moduledoc false
  use ExUnit.Case, async: true

  setup_all do
    assert File.dir?(PdfElixide.NifSource.src_dir()),
           "NIF sources not found at #{PdfElixide.NifSource.src_dir()}"

    {:ok, structs: PdfElixide.NifSource.structs()}
  end

  test "every NifStruct names a module that defines a struct", %{structs: structs} do
    unbacked =
      for %{file: file, name: name, module: module} <- structs,
          mod = Module.concat([module]),
          not (Code.ensure_loaded?(mod) and function_exported?(mod, :__struct__, 0)),
          do: "  - #{file}: #{name} -> #{inspect(module)}"

    assert unbacked == [],
           """
           These `NifStruct` derives name an Elixir module that defines no struct:

           #{Enum.join(unbacked, "\n")}
           """
  end

  test "every NifStruct's fields are exactly its module's struct keys", %{structs: structs} do
    drifted =
      for %{file: file, name: name, module: module, fields: fields} <- structs,
          mod = Module.concat([module]),
          Code.ensure_loaded?(mod) and function_exported?(mod, :__struct__, 0),
          rust = fields |> Enum.map(&String.to_atom/1) |> Enum.sort(),
          elixir = mod |> struct() |> Map.keys() |> List.delete(:__struct__) |> Enum.sort(),
          rust != elixir do
        """
          - #{file}: #{name} (#{inspect(module)})
              only in Rust:   #{inspect(rust -- elixir)}
              only in Elixir: #{inspect(elixir -- rust)}
        """
      end

    assert drifted == [],
           """
           These `NifStruct` derives disagree with their Elixir `defstruct`:

           #{Enum.join(drifted)}
           """
  end

  # Every #[module] attribute in this crate belongs to a NifStruct.
  test "the parse finds every #[module] attribute in the crate", %{structs: structs} do
    attributes =
      PdfElixide.NifSource.src_dir()
      |> Path.join("*.rs")
      |> Path.wildcard()
      |> Enum.map(fn path ->
        path
        |> File.read!()
        |> String.split("#[cfg(test)]", parts: 2)
        |> hd()
        |> then(&length(Regex.scan(~r/#\[module\s*=\s*"/, &1)))
      end)
      |> Enum.sum()

    assert attributes > 0
    assert length(structs) == attributes
    assert Enum.all?(structs, &(&1.module != nil and &1.fields != []))
  end
end
