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
  def src_dir, do: @src

  # Discard the preamble before the first NIF attribute.
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
