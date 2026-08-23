defmodule PdfElixide.Native.WrapTest do
  @moduledoc false

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

    test "a Rustler field-decode message raises ArgumentError instead" do
      # Rustler reports an undecodable `NifMap` field by raising a plain
      # string. A bad option is a caller bug, so it must raise rather than
      # become an error struct — and the message names the field, which is why
      # it is worth keeping instead of collapsing to a bare :badarg.
      assert_raise ArgumentError, "Could not decode field :detect_headings on %{}", fn ->
        Wrap.call(fn -> :erlang.error("Could not decode field :detect_headings on %{}") end)
      end
    end

    test "any other bare string still becomes an :other error" do
      # The clause above matches on Rustler's wording. Should that wording ever
      # change, the fallback below is what the caller gets — the behavior this
      # library shipped before, not a crash.
      assert {:error, %Error{reason: :other, message: "Could not decide anything"}} =
               Wrap.call(fn -> :erlang.error("Could not decide anything") end)
    end

    test "normalizes an unloaded NIF to :other" do
      assert {:error, %Error{reason: :other, message: ":nif_not_loaded"}} =
               Wrap.call(fn -> :erlang.nif_error(:nif_not_loaded) end)
    end
  end

  describe "unwrap!/1" do
    test "returns the payload of an {:ok, value} tuple" do
      assert Wrap.unwrap!({:ok, 42}) == 42
      assert Wrap.unwrap!({:ok, nil}) == nil
      assert Wrap.unwrap!({:ok, false}) == false
    end

    test "raises the error struct unchanged" do
      # The reason must survive: every bang variant's contract is that callers
      # can rescue a `%PdfElixide.Error{}` and match on it, not merely that
      # *something* raised.
      error = %Error{reason: :out_of_range, message: "Page index 99 out of range"}

      raised = assert_raise Error, fn -> Wrap.unwrap!({:error, error}) end

      assert raised == error
    end
  end

  describe "call!/1" do
    test "returns the value of a successful call" do
      assert Wrap.call!(fn -> {:ok, 42} end) == 42
      assert Wrap.call!(fn -> :some_atom end) == :some_atom
    end

    test "raises the normalized error for a returned tagged error" do
      raised =
        assert_raise Error, fn -> Wrap.call!(fn -> {:error, {:not_found, "missing"}} end) end

      assert raised.reason == :not_found
      assert raised.message == "missing"
    end

    test "raises the normalized error for a raised tagged error" do
      # The live path: a NIF reports failure by raising, so this is what
      # `encrypted?/1` hits on a closed handle.
      raised =
        assert_raise Error, fn ->
          Wrap.call!(fn -> :erlang.error({:closed, "Document is closed"}) end)
        end

      assert raised.reason == :closed
    end

    test "still lets a caller bug through as ArgumentError" do
      # `call!/1` composes `call/1`, so the errors-versus-exceptions split it
      # enforces must survive the composition rather than becoming an %Error{}.
      assert_raise ArgumentError, fn -> Wrap.call!(fn -> :erlang.error(:badarg) end) end
    end
  end

  describe "call/1 with an exception it must not swallow" do
    test "re-raises :badarg as ArgumentError rather than mangling it" do
      # A NIF raises :badarg when it cannot decode its arguments. Elixir
      # normalizes that to an ArgumentError.
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
