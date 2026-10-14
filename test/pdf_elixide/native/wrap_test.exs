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

    test "a Rustler field-decode message raises ArgumentError instead" do
      # Preserve the field name while classifying the bad option as a caller error.
      assert_raise ArgumentError, "Could not decode field :detect_headings on %{}", fn ->
        Wrap.call(fn -> :erlang.error("Could not decode field :detect_headings on %{}") end)
      end
    end
  end

  describe "call/1 with a broken native boundary" do
    test "re-raises an unloaded NIF" do
      error =
        assert_raise ErlangError, fn ->
          Wrap.call(fn -> :erlang.nif_error(:nif_not_loaded) end)
        end

      assert error.original == :nif_not_loaded
    end

    test "re-raises a panic the NIF did not contain" do
      error =
        assert_raise ErlangError, fn -> Wrap.call(fn -> :erlang.error(:nif_panicked) end) end

      assert error.original == :nif_panicked
    end

    test "re-raises a tagged error whose reason is not a documented one" do
      error =
        assert_raise ErlangError, fn ->
          Wrap.call(fn -> :erlang.error({:not_a_reason, "message"}) end)
        end

      assert error.original == {:not_a_reason, "message"}
    end

    test "re-raises a tagged error whose message is not a binary" do
      error =
        assert_raise ErlangError, fn -> Wrap.call(fn -> :erlang.error({:closed, :closed}) end) end

      assert error.original == {:closed, :closed}
    end

    test "re-raises a bare string that is not a field-decode message" do
      error =
        assert_raise ErlangError, fn ->
          Wrap.call(fn -> :erlang.error("something went wrong") end)
        end

      assert error.original == "something went wrong"
    end

    test "raises on a returned error it cannot normalize" do
      error =
        assert_raise ErlangError, fn ->
          Wrap.call(fn -> {:error, {:not_a_reason, "message"}} end)
        end

      assert error.original == {:error, {:not_a_reason, "message"}}
    end

    test "keeps the stacktrace of the frame that raised" do
      stacktrace =
        try do
          Wrap.call(&unloaded_stub/0)
        rescue
          ErlangError -> __STACKTRACE__
        end

      assert [{:erlang, :nif_error, _, _}, {__MODULE__, :unloaded_stub, 0, _} | _] = stacktrace
    end

    test "call!/1 raises it rather than an Error" do
      assert_raise ErlangError, fn -> Wrap.call!(fn -> :erlang.nif_error(:nif_not_loaded) end) end
    end
  end

  describe "unwrap!/1" do
    test "returns the payload of an {:ok, value} tuple" do
      assert Wrap.unwrap!({:ok, 42}) == 42
      assert Wrap.unwrap!({:ok, nil}) == nil
      assert Wrap.unwrap!({:ok, false}) == false
    end

    test "raises the error struct unchanged" do
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
      raised =
        assert_raise Error, fn ->
          Wrap.call!(fn -> :erlang.error({:closed, "Document is closed"}) end)
        end

      assert raised.reason == :closed
    end

    test "still lets a caller bug through as ArgumentError" do
      assert_raise ArgumentError, fn -> Wrap.call!(fn -> :erlang.error(:badarg) end) end
    end
  end

  describe "call/1 with an exception it must not swallow" do
    test "re-raises :badarg as ArgumentError rather than mangling it" do
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

  defp unloaded_stub, do: :erlang.nif_error(:nif_not_loaded)
end
