# Writes THIRD_PARTY_LICENSES: the notices for everything compiled into the
# native library, which the precompiled binaries carry and the Hex package
# delivers.
#
#     elixir priv/scripts/third_party_licenses.exs           # rewrite the file
#     elixir priv/scripts/third_party_licenses.exs --check   # exit 1 if stale
#
# Crates are those reachable from pdf_elixide_nif over normal (not build or
# dev) dependency edges on any target the release workflow builds. Requires
# Elixir 1.18 or later for JSON, and cargo.

defmodule ThirdPartyLicenses do
  @root Path.expand("../..", __DIR__)
  @output Path.join(@root, "THIRD_PARTY_LICENSES")
  @manifest Path.join(@root, "native/pdf_elixide_nif/Cargo.toml")
  @workflow Path.join(@root, ".github/workflows/release.yml")
  @templates Path.join(__DIR__, "licenses")

  # Crates this project binds rather than merely depends on.
  @upstream ["pdf_oxide", "office_oxide"]

  # When a crate offers a choice, the first licence here that it offers is
  # the one it is used under.
  @preference [
    "MIT",
    "Apache-2.0",
    "BSD-3-Clause",
    "BSD-2-Clause",
    "ISC",
    "Zlib",
    "0BSD",
    "Unlicense",
    "CC0-1.0",
    "BSD-1-Clause",
    "Unicode-3.0"
  ]

  def main(["--check"]) do
    expected = render()

    if normalize(File.read!(@output)) == normalize(expected) do
      IO.puts("THIRD_PARTY_LICENSES is up to date")
    else
      IO.puts(
        :stderr,
        "THIRD_PARTY_LICENSES is stale; run elixir priv/scripts/third_party_licenses.exs"
      )

      System.halt(1)
    end
  end

  def main([]) do
    File.write!(@output, render())
    IO.puts("wrote #{Path.relative_to(@output, @root)}")
  end

  def render do
    crates = crates()
    texts = license_texts(crates)

    [
      header(crates),
      bundled_data(crates),
      crate_list(crates, texts),
      text_section(texts),
      notice_section(crates)
    ]
    |> Enum.join("\n")
  end

  # -- dependency graph -----------------------------------------------------

  defp crates do
    metadata = metadata()
    packages = Map.new(metadata["packages"], &{&1["id"], &1})
    nodes = Map.new(metadata["resolve"]["nodes"], &{&1["id"], &1})
    root = metadata["resolve"]["root"]

    edges =
      Map.new(nodes, fn {id, node} ->
        {id,
         for(
           dep <- node["deps"],
           Enum.any?(dep["dep_kinds"], &is_nil(&1["kind"])),
           do: dep["pkg"]
         )}
      end)

    direct = Map.fetch!(edges, root)
    parents = shortest_paths(root, edges)

    reached_through =
      for top <- direct, id <- [top | descendants(top, edges)], reduce: %{} do
        acc -> Map.update(acc, id, MapSet.new([top]), &MapSet.put(&1, top))
      end

    parents
    |> Map.keys()
    |> List.delete(root)
    |> Enum.map(fn id ->
      package = Map.fetch!(packages, id)
      dir = Path.dirname(package["manifest_path"])

      %{
        name: package["name"],
        version: package["version"],
        license: package["license"] || "",
        authors: package["authors"] || [],
        dir: dir,
        files: license_files(dir),
        direct?: id in direct,
        through:
          reached_through |> Map.fetch!(id) |> Enum.map(&packages[&1]["name"]) |> Enum.sort(),
        path: path(id, parents, packages)
      }
    end)
    |> Enum.sort_by(&{&1.name, Version.parse!(&1.version)})
  end

  defp metadata do
    platforms = Enum.flat_map(release_targets(), &["--filter-platform", &1])

    {json, 0} =
      System.cmd(
        "cargo",
        ["metadata", "--format-version", "1", "--locked", "--manifest-path", @manifest] ++
          platforms
      )

    JSON.decode!(json)
  end

  defp release_targets do
    targets =
      Regex.scan(~r/target: ([a-z0-9_]+-[a-z0-9_-]+)/, File.read!(@workflow),
        capture: :all_but_first
      )

    targets |> List.flatten() |> Enum.uniq()
  end

  defp shortest_paths(root, edges) do
    bfs([root], edges, %{root => nil})
  end

  defp bfs([], _edges, seen), do: seen

  defp bfs(queue, edges, seen) do
    {next, seen} =
      for id <- queue, child <- Map.get(edges, id, []), reduce: {[], seen} do
        {next, seen} ->
          if Map.has_key?(seen, child),
            do: {next, seen},
            else: {[child | next], Map.put(seen, child, id)}
      end

    bfs(Enum.reverse(next), edges, seen)
  end

  defp descendants(id, edges), do: id |> shortest_paths(edges) |> Map.keys() |> List.delete(id)

  defp path(id, parents, packages) do
    id
    |> Stream.unfold(fn
      nil -> nil
      id -> {packages[id]["name"], parents[id]}
    end)
    |> Enum.reverse()
    |> Enum.join(" -> ")
  end

  defp relationship(%{direct?: true, name: name}) when name in @upstream,
    do: "upstream, direct dependency"

  defp relationship(%{direct?: true}), do: "direct dependency"

  defp relationship(%{through: through}) do
    through
    |> Enum.map(fn name -> if name in @upstream, do: "#{name} (upstream)", else: name end)
    |> Enum.join(", ")
    |> then(&"via #{&1}")
  end

  # -- licences -------------------------------------------------------------

  # A crate's SPDX expression reduced to the licences it is used under: one
  # alternative of each OR, every operand of each AND.
  defp elected(crate) do
    shipped = crate.files |> Enum.flat_map(fn {_file, kinds} -> kinds end) |> MapSet.new()

    crate.license
    |> String.replace("/", " OR ")
    |> tokenize()
    |> parse_or(shipped)
    |> elem(0)
  end

  defp tokenize(expression) do
    ~r/\(|\)|[A-Za-z0-9.+-]+/
    |> Regex.scan(expression)
    |> List.flatten()
  end

  defp parse_or(tokens, shipped) do
    {left, rest} = parse_and(tokens, shipped)

    case rest do
      ["OR" | rest] ->
        {right, rest} = parse_or(rest, shipped)
        {choose(left, right, shipped), rest}

      _ ->
        {left, rest}
    end
  end

  defp parse_and(tokens, shipped) do
    {left, rest} = parse_atom(tokens, shipped)

    case rest do
      ["AND" | rest] ->
        {right, rest} = parse_and(rest, shipped)
        {Enum.uniq(left ++ right), rest}

      _ ->
        {left, rest}
    end
  end

  defp parse_atom(["(" | rest], shipped) do
    {inner, [")" | rest]} = parse_or(rest, shipped)
    {inner, rest}
  end

  defp parse_atom([id, "WITH", exception | rest], _shipped),
    do: {["#{id} WITH #{exception}"], rest}

  defp parse_atom([id | rest], _shipped), do: {[id], rest}

  # A licence whose text the crate ships beats one it would need a standard
  # text for; otherwise the preference order decides.
  defp choose(left, right, shipped), do: Enum.min_by([left, right], &cost(&1, shipped))

  defp cost(licenses, shipped) do
    licenses
    |> Enum.map(fn license ->
      rank = Enum.find_index(@preference, &(&1 == license)) || 100
      if license in shipped, do: rank, else: rank + 1000
    end)
    |> Enum.sum()
  end

  defp license_texts(crates) do
    crates
    |> Enum.flat_map(fn crate ->
      for license <- elected(crate), do: {text_for(crate, license), license, crate}
    end)
    |> Enum.map(fn {text, license, crate} ->
      {copyright, body} = split_copyright(text)
      {body, license, {label(crate), copyright}}
    end)
    |> Enum.group_by(fn {body, _license, _use} -> normalize(body) end)
    |> Enum.map(fn {_key, [{body, license, _} | _] = uses} ->
      %{body: body, license: license, uses: Enum.map(uses, &elem(&1, 2))}
    end)
    |> Enum.sort_by(&{&1.license, &1.uses |> hd() |> elem(0)})
    |> Enum.with_index(1)
    |> Enum.map(fn {text, index} -> Map.put(text, :index, index) end)
  end

  # Licence texts that differ only in their copyright lines share one body;
  # the lines are kept per crate.
  defp split_copyright(text) do
    {copyright, body} =
      text
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> Enum.split_with(&copyright_line?/1)

    body = Enum.reject(body, &Regex.match?(~r/^\s*(the\s+)?mit license(\s*\(mit\))?\s*$/i, &1))
    {Enum.map(copyright, &String.trim/1), body |> Enum.join("\n") |> String.trim()}
  end

  # "Copyright" followed by a year, (c), ©, a placeholder or a capitalised
  # name; a body line such as "copyright notice, this list of conditions"
  # does not qualify.
  defp copyright_line?(line) do
    Regex.match?(
      ~r/^\s*(copyright\s*(\(c\)|©|\d|\[)|\(c\)\s*\d|©\s*\d|all rights reserved\.?\s*$)/i,
      line
    ) or
      Regex.match?(~r/^\s*Copyright\s+[A-Z]/, line)
  end

  defp text_for(crate, license) do
    Enum.find_value(crate.files, fn {file, kinds} -> if license in kinds, do: File.read!(file) end) ||
      template(license, crate)
  end

  # Each licence-like file with the licences its text holds; a file holding
  # none, such as a COPYRIGHT list, is kept for its copyright lines.
  defp license_files(dir) do
    dir
    |> File.ls!()
    |> Enum.filter(&Regex.match?(~r/^(licen[cs]e|copying|copyright|unlicense)/i, &1))
    |> Enum.sort()
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&{&1, kinds(Path.basename(&1), File.read!(&1))})
  end

  # Which licences a licence file holds, from its name and its text.
  defp kinds(name, text) do
    [
      {"MIT", ~r/MIT/, ~r/Permission is hereby granted, free of charge/},
      {"Apache-2.0", ~r/APACHE/i, ~r/Apache License\s+Version 2\.0/},
      {"BSD-3-Clause", ~r/BSD/i, ~r/Neither the name/},
      {"BSD-2-Clause", ~r/BSD/i, ~r/Redistribution and use in source and binary forms/},
      {"ISC", ~r/ISC/, ~r/Permission to use, copy, modify, and\/or distribute/},
      {"Zlib", ~r/ZLIB/i, ~r/This software is provided 'as-is'/},
      {"Unicode-3.0", ~r/UNICODE/i, ~r/UNICODE LICENSE V3/},
      {"Unlicense", ~r/UNLICENSE/i, ~r/This is free and unencumbered software/},
      {"CC0-1.0", ~r/CC0/i, ~r/CC0 1\.0 Universal/}
    ]
    |> Enum.filter(fn {_license, by_name, by_text} ->
      Regex.match?(by_text, text) or (Regex.match?(by_name, name) and not generic?(name))
    end)
    |> Enum.map(&elem(&1, 0))
    |> reject_bsd2_when_bsd3(text)
  end

  defp generic?(name), do: Regex.match?(~r/^(licen[cs]e|copying)(\.(md|txt))?$/i, name)

  defp reject_bsd2_when_bsd3(kinds, text) do
    if Regex.match?(~r/Neither the name/, text),
      do: List.delete(kinds, "BSD-2-Clause"),
      else: kinds
  end

  defp template(license, crate) do
    path = Path.join(@templates, "#{license}.txt")

    unless File.exists?(path) do
      raise "#{label(crate)} ships no #{license} text and #{Path.relative_to(path, @root)} is missing"
    end

    copyright =
      case for {file, []} <- crate.files, do: File.read!(file) do
        [] ->
          holders =
            if crate.authors == [],
              do: "the #{crate.name} authors",
              else: Enum.join(crate.authors, ", ")

          "Copyright (c) #{holders}"

        statements ->
          statements |> Enum.map(&String.trim/1) |> Enum.join("\n\n")
      end

    copyright <> "\n\n" <> File.read!(path)
  end

  defp notices(crate) do
    crate.dir
    |> File.ls!()
    |> Enum.filter(&Regex.match?(~r/^notice/i, &1))
    |> Enum.sort()
    |> Enum.map(&File.read!(Path.join(crate.dir, &1)))
  end

  # -- rendering ------------------------------------------------------------

  defp label(crate), do: "#{crate.name} #{crate.version}"

  defp normalize(text),
    do: text |> String.replace("\r\n", "\n") |> String.split() |> Enum.join(" ")

  defp rule(title), do: "\n#{String.duplicate("=", 78)}\n#{title}\n#{String.duplicate("=", 78)}\n"

  defp header(crates) do
    direct = Enum.count(crates, & &1.direct?)

    upstream_only =
      Enum.count(crates, &(not &1.direct? and Enum.all?(&1.through, fn t -> t in @upstream end)))

    """
    THIRD-PARTY LICENCES

    pdf_elixide is released under the MIT License (see LICENSE). Its native
    library, which the precompiled binaries contain, also compiles in the
    third-party code and data listed here, whose licences require these
    notices to travel with every copy.

    The library binds pdf_oxide and office_oxide, the upstream Rust libraries.
    Each crate below says how it is reached: as a direct dependency of
    pdf_elixide_nif, the binding's own crate, or as a dependency of one of
    those direct dependencies, with the shortest chain that pulls it in.

    Crates on the targets the precompiled binaries are built for:

      Direct dependencies:                          #{direct}
      Reached only through the upstream libraries:  #{upstream_only}
      Reached through at least one other:           #{length(crates) - direct - upstream_only}
      Total:                                        #{length(crates)}

    Where a crate offers a choice of licences, it is used under the one named
    after "Used under". The Elixir packages this library depends on are not
    part of it; each carries its own licence.

    This file is generated by priv/scripts/third_party_licenses.exs.
    """
  end

  defp bundled_data(crates) do
    pdf_oxide = Enum.find(crates, &(&1.name == "pdf_oxide"))
    hayro = Enum.find(crates, &(&1.name == "hayro-jpeg2000"))
    dejavu = File.read!(Path.join(pdf_oxide.dir, "src/fonts/assets/LICENSE-DejaVu"))

    rule("Bundled data") <>
      """

      Data files compiled into the library alongside the code.

      1. DejaVu Sans and DejaVu Sans Bold fonts
         Reached through: #{label(pdf_oxide)} (upstream), src/fonts/assets/
         Licence: Bitstream Vera Fonts licence, with the DejaVu changes in
         the public domain:

      #{indent(dejavu)}

      2. sRGB colour profile written by PdfElixide.Compliance.convert/3
         This project: native/pdf_elixide_nif/src/srgb-v2-magic.icc, from
         Compact-ICC-Profiles (https://github.com/saucecontrol/Compact-ICC-Profiles).
         Licence: CC0 1.0 Universal (public domain dedication).

      3. sRGB colour profile compiled into pdf_oxide
         Reached through: #{label(pdf_oxide)} (upstream),
         src/compliance/srgb_profile_placeholder.bin
         This file is byte-identical to iccprofiles/srgb.icc from Ghostscript,
         Copyright Artifex Software 2011, which Artifex distributes under the
         GNU Affero General Public License, version 3 or later
         (https://www.gnu.org/licenses/agpl-3.0.html). Its source is the file
         itself, available in the pdf_oxide crate and at
         https://github.com/ArtifexSoftware/ghostpdl/tree/master/iccprofiles.
         pdf_elixide never writes it into a document: it passes its own
         profile (item 2) to every conversion.

      4. ICC profiles compiled into hayro-jpeg2000
         Reached through: #{label(hayro)} (#{relationship(hayro)})
         ProPhoto-v2-micro.icc, CGATS001Compat-v2-micro.icc and LAB.icc.
         Licence: CC0 1.0 Universal (public domain dedication), per the
         crate's assets/README.md.

      5. Base-14 font metrics
         This project: native/pdf_elixide_nif/src/base14.rs holds advance
         widths and glyph bounding boxes extracted from Adobe's Core 14 AFM
         files, Copyright (c) 1985-1997 Adobe Systems Incorporated. The
         tables are a modification of the AFM data. The AFM files' ReadMe
         reads:

         This file and the 14 PostScript(R) AFM files it accompanies may be
         used, copied, and distributed for any purpose and without charge,
         with or without modification, provided that all copyright notices
         are retained; that the AFM files are not distributed without this
         file; that all modifications to this file or any of the AFM files
         are prominently noted in the modified file(s); and that this
         paragraph is not modified. Adobe Systems has no responsibility or
         obligation to support the use of the AFM files.
      """
  end

  defp crate_list(crates, texts) do
    index =
      for text <- texts, {crate, _copyright} <- text.uses, reduce: %{} do
        acc -> Map.update(acc, crate, [text.index], &(&1 ++ [text.index]))
      end

    entries =
      Enum.map(crates, fn crate ->
        used_under = crate |> elected() |> Enum.join(" AND ")

        license =
          if used_under == crate.license,
            do: used_under,
            else: "#{used_under} (of #{crate.license})"

        refs = index |> Map.fetch!(label(crate)) |> Enum.map_join(", ", &"[#{&1}]")

        "#{label(crate)} — #{license} — #{relationship(crate)} — #{refs}\n  #{crate.path}"
      end)

    rule("Crates") <> "\n" <> Enum.join(entries, "\n") <> "\n"
  end

  defp text_section(texts) do
    body =
      Enum.map_join(texts, "\n", fn text ->
        notices =
          Enum.map_join(text.uses, "\n", fn
            {crate, []} -> "  #{crate}"
            {crate, lines} -> "  #{crate}: #{Enum.join(lines, " / ")}"
          end)

        """
        [#{text.index}] #{text.license}, used by these crates under their copyright notices:

        #{notices}

        #{text.body}
        #{String.duplicate("-", 78)}
        """
      end)

    rule("Licence texts") <> "\n" <> body
  end

  defp notice_section(crates) do
    body =
      crates
      |> Enum.flat_map(fn crate -> for notice <- notices(crate), do: {crate, notice} end)
      |> Enum.map_join("\n", fn {crate, notice} ->
        """
        NOTICE of #{label(crate)}

        #{String.trim(notice)}
        #{String.duplicate("-", 78)}
        """
      end)

    preface = """

    Each NOTICE file is reproduced verbatim from its crate. Paths in it refer
    to that crate's own repository; of the files it names, only those listed
    under "Bundled data" above are part of this library.
    """

    rule("NOTICE files") <> preface <> "\n" <> body
  end

  defp indent(text) do
    text
    |> String.trim()
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing("   " <> &1))
  end
end

ThirdPartyLicenses.main(System.argv())
