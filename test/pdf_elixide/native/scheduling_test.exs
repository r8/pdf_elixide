defmodule PdfElixide.Native.SchedulingTest do
  @moduledoc false

  use ExUnit.Case, async: true

  # Match the public guard-taking calls; private `lock`/`read` have no call sites.
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
