defmodule PdfElixide.Native.InventoryTest do
  @moduledoc """
  The stub list in `PdfElixide.Native`, pinned against the registered NIFs.

  Every NIF is declared twice — once as a `#[rustler::nif]` function in the
  crate, once as a hand-written stub whose body is `:erlang.nif_error/1` until
  the library loads over it. The two lists are kept in step by hand, and only one
  direction of drift is loud:

    * **A registered NIF with no stub** — or a stub whose arity disagrees — makes
      `:erlang.load_nif` reject the whole library, because it requires an
      exported function of matching name and arity for each NIF. ERTS logs
      `{:bad_lib, ~c"Function not found …"}` naming the offender, the module then
      does not exist, and every test in the suite falls over at once.
    * **A stub with no NIF behind it** — a leftover after a Rust rename, or a
      typo — is invisible. Nothing fails at load: the stub stays an ordinary
      Elixir function, and calling it raises `ErlangError` with an original of
      `:nif_not_loaded`, which `PdfElixide.Native.Wrap.call/1` normalizes through
      its catch-all into `{:error, %PdfElixide.Error{reason: :other}}`. A caller
      cannot tell that from a genuine PDF failure, and neither can a test that
      only asserts an error came back. That is the failure this file exists to
      make loud.

  So of the two assertions below only the second can report the drift it is named
  for; the first cannot even run in a build where a stub is missing, since its
  `setup_all` needs the module the load rejected. It is kept for the mistakes that
  *do* leave the module loadable: the comparison is against a parse of the Rust
  sources, so a NIF the parser reads under the wrong name or arity — the risk of
  reading the signature at all — fails there rather than skewing the inventory
  silently.

  The second assertion is also the parser's canary: a parse that finds nothing
  makes every stub unbacked, which is why `PdfElixide.Native.SchedulingTest` no
  longer carries a floor of its own.

  What is compared is name and arity as *Elixir* sees them, so the parser honors
  a `name = "…"` override on the attribute and drops rustler's injected `env`
  parameter. See `PdfElixide.NifSource`.
  """
  use ExUnit.Case, async: true

  # Generated rather than hand-written, so neither is a NIF stub. `rustler_init/0`
  # comes from `use Rustler`, which `RustlerPrecompiled` delegates to under
  # `force_build` — the dev and test setting, `config/dev.exs` and
  # `config/test.exs`; `load_rustler_precompiled/0` is its counterpart in a
  # precompiled build. Both are named so this test reads the same either way.
  # `__info__/1` and `module_info/0,1` are not reported by `__info__(:functions)`.
  @generated [rustler_init: 0, load_rustler_precompiled: 0]

  setup_all do
    assert File.dir?(PdfElixide.NifSource.src_dir()),
           "NIF sources not found at #{PdfElixide.NifSource.src_dir()}"

    nifs = for nif <- PdfElixide.NifSource.nifs(), do: {String.to_atom(nif.name), nif.arity}

    # Not `registered:` — ExUnit reserves that context key for
    # `register_attribute/3` and silently overwrites the value with its own map.
    {:ok, nifs: nifs, stubs: PdfElixide.Native.__info__(:functions) -- @generated}
  end

  test "every registered NIF has a stub", %{nifs: nifs, stubs: stubs} do
    missing = nifs -- stubs

    assert missing == [],
           """
           These NIFs were parsed out of the crate but have no matching function in
           `PdfElixide.Native`. A genuinely missing stub would have kept the
           library from loading at all, so reaching this assertion most likely
           means `PdfElixide.NifSource` read a name or arity wrongly. Check that
           first, then add the stub:

           #{format(missing)}
           """
  end

  test "every stub is backed by a registered NIF", %{nifs: nifs, stubs: stubs} do
    stray = stubs -- nifs

    assert stray == [],
           """
           These functions in `PdfElixide.Native` have no `#[rustler::nif]` behind
           them, so they stay stubs after the library loads and report
           `:nif_not_loaded` — which `Wrap.call/1` hands back as an ordinary
           `%PdfElixide.Error{reason: :other}`. Remove each, or fix the name or
           arity it was meant to match:

           #{format(stray)}
           """
  end

  defp format(entries) do
    Enum.map_join(entries, "\n", fn {name, arity} -> "  - #{name}/#{arity}" end)
  end
end
