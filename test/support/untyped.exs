defmodule PdfElixide.Untyped do
  @moduledoc false

  # Identity at runtime, so the guard under test still receives the value the
  # test wrote. Its only job is to stand between that value and the compiler's
  # type inference; it must stay a bare pass-through.
  def untyped(value), do: value
end
