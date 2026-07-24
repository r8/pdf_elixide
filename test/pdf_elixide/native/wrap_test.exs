defmodule PdfElixide.Native.WrapTest do
  use ExUnit.Case, async: true

  alias PdfElixide.Error
  alias PdfElixide.Native.Wrap

  describe "call/1 with a returned value" do
    test "passes an {:ok, value} tuple through" do
      assert {:ok, 42} = Wrap.call(fn -> {:ok, 42} end)
    end

    test "wraps a bare value" do
      assert {:ok, :some_atom} = Wrap.call(fn -> :some_atom end)
      assert {:ok, [1, 2, 3]} = Wrap.call(fn -> [1, 2, 3] end)
    end

    test "normalizes a returned tagged error" do
      assert {:error, %Error{reason: :not_found, message: "missing"}} =
               Wrap.call(fn -> {:error, {:not_found, "missing"}} end)
    end
  end

  describe "call/1 with a raised NIF error" do
    test "normalizes a raised tagged error — the live path for NIF failures" do
      assert {:error, %Error{reason: :closed, message: "Document is closed"}} =
               Wrap.call(fn -> :erlang.error({:closed, "Document is closed"}) end)
    end

    test "normalizes a raised bare string to :other" do
      assert {:error, %Error{reason: :other, message: "something went wrong"}} =
               Wrap.call(fn -> :erlang.error("something went wrong") end)
    end

    test "normalizes an unloaded NIF to :other" do
      assert {:error, %Error{reason: :other, message: ":nif_not_loaded"}} =
               Wrap.call(fn -> :erlang.nif_error(:nif_not_loaded) end)
    end
  end

  describe "call/1 with an exception it must not swallow" do
    test "re-raises :badarg as ArgumentError rather than mangling it" do
      # A NIF raises :badarg when it cannot decode its arguments. Elixir
      # normalizes that to an ArgumentError, which carries no :original key —
      # reading one used to raise a KeyError from inside call/1.
      assert_raise ArgumentError, fn -> Wrap.call(fn -> :erlang.error(:badarg) end) end
    end

    test "re-raises an Elixir exception with its message intact" do
      assert_raise RuntimeError, "boom", fn -> Wrap.call(fn -> raise "boom" end) end
    end

    test "preserves the stacktrace of a re-raised exception" do
      raiser = fn -> :erlang.error(:badarg) end

      stacktrace =
        try do
          Wrap.call(raiser)
        rescue
          _ -> __STACKTRACE__
        end

      assert Enum.any?(stacktrace, fn {module, _fun, _arity, _location} ->
               module == __MODULE__
             end)
    end
  end
end
