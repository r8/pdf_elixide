defmodule PdfElixide.NifSource do
  @moduledoc false

  @src Path.expand("../../native/pdf_elixide_nif/src", __DIR__)

  @doc false
  def nifs do
    @src
    |> Path.join("*.rs")
    |> Path.wildcard()
    |> Enum.flat_map(&parse_file/1)
  end

  @doc false
  def structs do
    @src
    |> Path.join("*.rs")
    |> Path.wildcard()
    |> Enum.flat_map(&parse_structs/1)
  end

  @doc false
  def src_dir, do: @src

  # Discard the preamble before the first NIF attribute.
  defp parse_file(path) do
    file = Path.basename(path)

    path
    |> File.read!()
    |> strip_tests()
    |> String.split("#[rustler::nif")
    |> Enum.drop(1)
    |> Enum.map(&parse_nif(file, &1))
  end

  # Exclude the trailing test module from the last NIF's body.
  defp strip_tests(source) do
    source |> String.split("#[cfg(test)]", parts: 2) |> hd()
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
         {:ok, params} <- balanced(rest, ")") do
      params
      |> split_params()
      |> Enum.reject(&injected_env?/1)
      |> length()
    else
      _ -> nil
    end
  end

  # Line comments are stripped before the split: the field regex is anchored,
  # so a comment glued to a field by the comma split would hide it, and one
  # containing `word:` would invent one.
  defp parse_structs(path) do
    file = Path.basename(path)

    path
    |> File.read!()
    |> strip_tests()
    |> String.replace(~r{//[^\n]*}, "")
    |> String.split("#[derive(")
    |> Enum.drop(1)
    |> Enum.filter(&nif_struct?/1)
    |> Enum.map(&parse_struct(file, &1))
  end

  defp nif_struct?(chunk) do
    chunk |> String.split(")", parts: 2) |> hd() |> String.contains?("NifStruct")
  end

  defp parse_struct(file, chunk) do
    %{
      file: file,
      name: capture(~r/\bstruct\s+([A-Za-z0-9_]+)/, chunk),
      module: capture(~r/#\[module\s*=\s*"([^"]+)"\]/, chunk),
      fields: struct_fields(chunk)
    }
  end

  defp struct_fields(chunk) do
    with [_, rest] <- Regex.split(~r/\bstruct\s+[A-Za-z0-9_]+\s*\{/, chunk, parts: 2),
         {:ok, body} <- balanced(rest, "}") do
      body
      |> split_params()
      |> Enum.map(&capture(~r/^(?:pub(?:\([^)]*\))?\s+)?([a-z_][a-z0-9_]*)\s*:/, &1))
      |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  # Everything up to the bracket that closes the parameter list or struct body,
  # which is not the first closer in the general case — a type may contain its
  # own brackets.
  defp balanced(rest, closer) do
    rest
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn char, {taken, depth} ->
      case {char, depth} do
        {^closer, 0} -> {:halt, {:ok, taken |> Enum.reverse() |> Enum.join()}}
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
  # cannot hide a comma. A comparison operator would unbalance this, but neither
  # a parameter list nor a struct body has expressions in it.
  defp nesting(char) when char in ["(", "<", "[", "{"], do: 1
  defp nesting(char) when char in [")", ">", "]", "}"], do: -1
  defp nesting(_char), do: 0

  defp injected_env?(param), do: Regex.match?(~r/^env\s*:\s*Env\b/, param)
end
