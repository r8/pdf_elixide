defmodule PdfElixide.Native.SchedulingTest do
  @moduledoc """
  Canary for the NIF scheduling invariant.

  **A NIF that can block on a `Closable` lock must not run on a normal
  scheduler.** `Closable::lock` is an `RwLock::write` and a long extraction on
  the same handle holds it for seconds, so a plain `#[rustler::nif]` that takes
  the lock parks a normal BEAM scheduler thread for that whole duration — enough
  such callers and the VM stops scheduling processes, firing timers and sending
  distribution heartbeats. `Closable::close` and `Closable::is_closed` take that
  same `RwLock` — they recover a poisoned lock rather than erroring, but nothing
  lets them jump an in-flight guard — so the `*_close` / `*_closed` NIFs are in
  scope here too, cheap as their own work looks.

  If you add a NIF that reaches a resource, give it `schedule = "DirtyCpu"` (or
  `"DirtyIo"` for filesystem work) rather than relaxing this test.

  This is a source-level check on purpose: proving the hazard behaviourally would
  need a multi-thousand-page PDF generated in-test plus timing assertions, which
  is flaky. The attribute is the invariant, so the attribute is what we pin.
  """

  use ExUnit.Case, async: true

  @src Path.expand("../../../native/pdf_elixide_nif/src", __DIR__)

  # Every entry point on `Closable` that takes its `RwLock`, spelled as the call
  # sites are — the guard-taking `lock`/`read` are private and only ever reached
  # through `with_lock`/`with_read`, so matching `.lock()`/`.read()` would match
  # nothing. `close`/`is_closed` are here because recovering a poisoned lock is
  # not the same as not waiting for one: `close` is an `RwLock::write` that drains
  # every in-flight guard, and `is_closed` an `RwLock::read` that waits behind a
  # held write guard.
  @locking_calls [".with_lock(", ".with_read(", ".close()", ".is_closed()"]

  # Sanity floor for the block parser, well under the 67 stubs registered in
  # `PdfElixide.Native`, so a parsing regression fails loudly instead of finding
  # nothing to check.
  @min_nifs 60

  setup_all do
    assert File.dir?(@src), "NIF sources not found at #{@src}"

    nifs =
      @src
      |> Path.join("*.rs")
      |> Path.wildcard()
      |> Enum.flat_map(&parse_nifs/1)

    {:ok, nifs: nifs}
  end

  test "the parser finds the NIFs", %{nifs: nifs} do
    assert length(nifs) >= @min_nifs
  end

  test "no unscheduled NIF takes a resource lock", %{nifs: nifs} do
    offenders =
      for %{scheduled?: false, file: file, name: name, body: body} <- nifs,
          Enum.any?(@locking_calls, &String.contains?(body, &1)),
          do: "#{file}: #{name}"

    assert offenders == [],
           """
           These NIFs run on a normal scheduler yet take a resource lock, so they
           can block a scheduler thread behind a concurrent extraction (see
           review §1.1). Add `schedule = "DirtyCpu"` to each:

           #{Enum.map_join(offenders, "\n", &"  - #{&1}")}
           """
  end

  # Splits a Rust source into one entry per `#[rustler::nif…]` attribute: the
  # attribute line decides `scheduled?`, and everything up to the next attribute
  # (or end of file) is the body searched for lock calls.
  defp parse_nifs(path) do
    file = Path.basename(path)

    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.chunk_while(nil, &chunk_nif/2, &{:cont, &1, nil})
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn {scheduled?, lines} ->
      body = lines |> Enum.reverse() |> Enum.join("\n")
      %{file: file, name: fn_name(body), scheduled?: scheduled?, body: body}
    end)
  end

  defp chunk_nif(line, acc) do
    if String.starts_with?(line, "#[rustler::nif") do
      {:cont, acc, {String.contains?(line, "schedule ="), []}}
    else
      case acc do
        nil -> {:cont, nil}
        {scheduled?, lines} -> {:cont, {scheduled?, [line | lines]}}
      end
    end
  end

  defp fn_name(body) do
    case Regex.run(~r/^fn ([a-z0-9_]+)/m, body) do
      [_, name] -> name
      nil -> "<unnamed>"
    end
  end
end
