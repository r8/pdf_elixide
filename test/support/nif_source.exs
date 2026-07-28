defmodule PdfElixide.NifSource do
  @moduledoc """
  The Rust NIF sources, parsed once for the source-level canaries.

  Two tests read the NIF definitions rather than the running library —
  `PdfElixide.Native.InventoryTest`, which pins the stub list in
  `PdfElixide.Native` against what is registered, and
  `PdfElixide.Native.SchedulingTest`, which pins that a lock-taking NIF runs on a
  dirty scheduler. They asked the same question of the same files, so the parser
  lives here and each test spells only its own invariant.

  This is a `.exs` required from `test/test_helper.exs`, deliberately, rather
  than a `.ex` under an `elixirc_paths(:test)` entry: a compiled `test/support`
  module is part of the application in the test environment, so
  `:application.get_key(:pdf_elixide, :modules)` would return it and
  `PdfElixide.DocGroupsTest` — which derives its inventory from exactly that
  call — would demand a HexDocs group for a test helper. A required script is
  never in the application at all.

  `nifs/0` returns one map per `#[rustler::nif…]` attribute found under
  `native/pdf_elixide_nif/src`:

      %{file: "document.rs", name: "document_open", arity: 2, scheduled?: true, body: "…"}

  Three details decide whether `name` and `arity` describe the function *Elixir*
  sees, which is the whole point of the inventory comparison:

    * `name = "…"` in the attribute overrides the Rust function name as the
      exported one. None of the NIFs use it today; reading it is what keeps the
      mapping honest on the day one does.
    * A leading `env: Env<…>` parameter is injected by rustler and is not an
      Elixir argument, so it does not count toward the arity (`image_data` and
      `font_data` are the two NIFs this affects).
    * A lifetime generic between the name and the parameter list (`fn f<'a>(…)`)
      is skipped, so the balanced scan starts at the real opening paren.

  Nothing here validates the parse. A regression that finds no NIFs at all
  surfaces in the inventory test, as every stub reported unbacked.
  """

  @src Path.expand("../../native/pdf_elixide_nif/src", __DIR__)

  @doc """
  Every `#[rustler::nif…]` definition in the crate.
  """
  def nifs do
    @src
    |> Path.join("*.rs")
    |> Path.wildcard()
    |> Enum.flat_map(&parse_file/1)
  end

  @doc """
  The directory the definitions are read from, so a test can assert it exists.
  """
  def src_dir, do: @src

  # Splits a source at each attribute: the chunk before the first one is
  # preamble, and every chunk after it opens with the attribute's own arguments
  # and runs to the next attribute (or end of file), which is the body a caller
  # searches for calls.
  defp parse_file(path) do
    file = Path.basename(path)

    path
    |> File.read!()
    |> String.split("#[rustler::nif")
    |> Enum.drop(1)
    |> Enum.map(&parse_nif(file, &1))
  end

  defp parse_nif(file, chunk) do
    {attr, body} = split_attribute(chunk)

    %{
      file: file,
      name: nif_name(attr, body),
      arity: nif_arity(body),
      scheduled?: String.contains?(attr, "schedule ="),
      body: body
    }
  end

  defp split_attribute(chunk) do
    case String.split(chunk, "]", parts: 2) do
      [attr, body] -> {attr, body}
      [attr] -> {attr, ""}
    end
  end

  defp nif_name(attr, body) do
    with nil <- capture(~r/name\s*=\s*"([^"]+)"/, attr),
         nil <- capture(~r/\bfn\s+([a-z0-9_]+)/, body) do
      "<unnamed>"
    end
  end

  defp capture(regex, source) do
    case Regex.run(regex, source) do
      [_, capture] -> capture
      nil -> nil
    end
  end

  # Counts the parameters of the first signature in the body, which is the NIF's
  # own: the attribute applies to the item directly beneath it.
  defp nif_arity(body) do
    with [_, rest] <- Regex.split(~r/\bfn\s+[a-z0-9_]+\s*(?:<[^>(]*>)?\s*\(/, body, parts: 2),
         {:ok, params} <- balanced(rest) do
      params
      |> split_params()
      |> Enum.reject(&injected_env?/1)
      |> length()
    else
      _ -> nil
    end
  end

  # Everything up to the paren that closes the parameter list, which is not the
  # first `)` in the general case — a parameter type may contain its own parens.
  defp balanced(rest) do
    rest
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn char, {taken, depth} ->
      case {char, depth} do
        {")", 0} -> {:halt, {:ok, taken |> Enum.reverse() |> Enum.join()}}
        _ -> {:cont, {[char | taken], depth + nesting(char)}}
      end
    end)
    |> case do
      {:ok, _} = ok -> ok
      _ -> :error
    end
  end

  defp split_params(params) do
    params
    |> String.graphemes()
    |> Enum.reduce({[""], 0}, fn char, {[current | rest], depth} ->
      if char == "," and depth == 0 do
        {["", current | rest], depth}
      else
        {[current <> char | rest], depth + nesting(char)}
      end
    end)
    |> then(fn {parts, _depth} -> parts end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reverse()
  end

  # `<` and `>` are counted alongside the brackets so a generic parameter type
  # cannot hide a comma. A comparison operator would unbalance this, but a
  # parameter list has no expressions in it.
  defp nesting(char) when char in ["(", "<", "["], do: 1
  defp nesting(char) when char in [")", ">", "]"], do: -1
  defp nesting(_char), do: 0

  defp injected_env?(param), do: Regex.match?(~r/^env\s*:\s*Env\b/, param)
end
