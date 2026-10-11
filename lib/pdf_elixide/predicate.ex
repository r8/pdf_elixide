defmodule PdfElixide.Predicate do
  @moduledoc false

  alias PdfElixide.Error
  alias PdfElixide.Native.Wrap

  # A tolerant predicate may hide a feature it cannot read, but not a handle
  # that cannot be used at all.
  @handle_reasons [:closed, :lock_poisoned, :panic]

  # `mapper` runs on `Wrap.call/1`'s success value, never on the NIF's own
  # return. A NIF reports failure as a `{reason, message}` *tuple* as often as it
  # raises one, so a caller testing the raw return inside the closure would be
  # comparing against that tuple and would answer `true` for the error it meant
  # to degrade.
  #
  # `raising` is the set that still raises; a predicate taking no handle passes
  # `[]`, having none to protect.
  @doc false
  @spec tolerant!((-> term()), (term() -> boolean()), [Error.reason()]) :: boolean()
  def tolerant!(fun, mapper \\ & &1, raising \\ @handle_reasons) do
    case Wrap.call(fun) do
      {:ok, value} ->
        mapper.(value)

      {:error, %Error{reason: reason} = error} ->
        if reason in raising, do: raise(error), else: false
    end
  end
end
