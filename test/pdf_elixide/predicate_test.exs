defmodule PdfElixide.PredicateTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias PdfElixide.Error
  alias PdfElixide.Predicate

  describe "tolerant!/3" do
    test "answers false for a reason outside the raising set" do
      refute Predicate.tolerant!(fn -> :erlang.error({:invalid_pdf, "bad"}) end)
    end

    test "raises a reason in the raising set" do
      assert_raise Error, fn ->
        Predicate.tolerant!(fn -> :erlang.error({:closed, "closed"}) end)
      end
    end

    test "does not answer false for an unloaded NIF" do
      assert_raise ErlangError, fn ->
        Predicate.tolerant!(fn -> :erlang.nif_error(:nif_not_loaded) end)
      end

      assert_raise ErlangError, fn ->
        Predicate.tolerant!(fn -> :erlang.nif_error(:nif_not_loaded) end, & &1, [])
      end
    end
  end
end
