defmodule PdfElixide.Native.SchedulingTest do
  @moduledoc """
  Canary for the NIF scheduling invariant.

  **A NIF that can block on a `Closable` lock must not run on a normal
  scheduler.** Reads take that lock shared, so they no longer wait on each other
  — but a plain `#[rustler::nif]` would still park a normal BEAM scheduler
  thread, because the extraction it runs is CPU-bound for seconds whichever
  guard it holds, and because a shared guard still waits behind an exclusive one
  (`document_authenticate`, an editor call, or a `close`), which waits in turn
  for every reader ahead of it. Enough such callers and the VM stops scheduling
  processes, firing timers and sending distribution heartbeats. `Closable::close`
  and `Closable::is_closed` take the same `RwLock` — they recover a poisoned lock
  rather than erroring, but nothing lets them jump an in-flight guard — so the
  `*_close` / `*_closed` NIFs are in scope here too, cheap as their own work
  looks.

  If you add a NIF that reaches a resource, give it `schedule = "DirtyCpu"` (or
  `"DirtyIo"` for filesystem work) rather than relaxing this test.

  This is a source-level check on purpose: proving the hazard behaviourally would
  need a multi-thousand-page PDF generated in-test plus timing assertions, which
  is flaky. The attribute is the invariant, so the attribute is what we pin.

  The definitions come from `PdfElixide.NifSource`, shared with
  `PdfElixide.Native.InventoryTest`. Nothing here checks that the parse found
  anything: a parser that returns nothing makes this file pass vacuously but
  fails the inventory, where every stub is then reported as unbacked.
  """

  use ExUnit.Case, async: true

  # Every entry point on `Closable` that takes its `RwLock`, spelled as the call
  # sites are — the guard-taking `lock`/`read` are private and only ever reached
  # through `with_lock`/`with_read`, so matching `.lock()`/`.read()` would match
  # nothing. `close`/`is_closed` are here because recovering a poisoned lock is
  # not the same as not waiting for one: `close` is an `RwLock::write` that drains
  # every in-flight guard, and `is_closed` an `RwLock::read` that waits behind a
  # held write guard.
  @locking_calls [".with_lock(", ".with_read(", ".close()", ".is_closed()"]

  setup_all do
    {:ok, nifs: PdfElixide.NifSource.nifs()}
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
end
