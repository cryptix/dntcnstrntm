defmodule PropagatorTest do
  use ExUnit.Case

  alias Propagator.{Cell, Arithmetic}
  alias Propagator.Lattice.Number

  # Small delay to let the async propagator messages settle.
  @settle 50

  describe "Cell basics" do
    test "new cell starts at bottom (:nothing)" do
      {:ok, c} = Cell.new(Number)
      assert Cell.read(c) == :nothing
    end

    test "add_content merges into cell" do
      {:ok, c} = Cell.new(Number)
      Cell.add_content(c, 42)
      assert Cell.read(c) == 42
    end

    test "adding the same value is idempotent" do
      {:ok, c} = Cell.new(Number)
      Cell.add_content(c, 42)
      Cell.add_content(c, 42)
      assert Cell.read(c) == 42
    end

    test "adding a conflicting value produces contradiction" do
      {:ok, c} = Cell.new(Number)
      Cell.add_content(c, 42)
      Cell.add_content(c, 99)
      assert Cell.read(c) == :contradiction
    end

    test "subscribers are notified on value change" do
      {:ok, c} = Cell.new(Number)
      Cell.subscribe(c, self())
      Cell.add_content(c, 42)
      assert_receive :propagate, 100
    end

    test "subscribers are NOT notified when value doesn't change" do
      {:ok, c} = Cell.new(Number)
      Cell.add_content(c, 42)
      Cell.subscribe(c, self())
      Cell.add_content(c, 42)
      refute_receive :propagate, 50
    end
  end

  describe "Lattice.Number" do
    test "merge with :nothing yields the other value" do
      assert Number.merge(:nothing, 5) == 5
      assert Number.merge(5, :nothing) == 5
    end

    test "merge equal values yields the value" do
      assert Number.merge(5, 5) == 5
    end

    test "merge different values yields contradiction" do
      assert Number.merge(5, 6) == :contradiction
    end

    test "merge with contradiction yields contradiction" do
      assert Number.merge(:contradiction, 5) == :contradiction
      assert Number.merge(5, :contradiction) == :contradiction
    end

    test "close floating point values merge successfully" do
      # These are close enough to be considered equal
      assert Number.merge(1.0, 1.0 + 1.0e-15) == 1.0
    end
  end

  describe "adder (a + b = sum)" do
    test "forward: knowing a and b computes sum" do
      {:ok, a} = Cell.new(Number)
      {:ok, b} = Cell.new(Number)
      {:ok, sum} = Cell.new(Number)

      Arithmetic.adder(a, b, sum)

      Cell.add_content(a, 3)
      Cell.add_content(b, 5)
      Process.sleep(@settle)

      assert Cell.read(sum) == 8
    end

    test "backward: knowing sum and a computes b" do
      {:ok, a} = Cell.new(Number)
      {:ok, b} = Cell.new(Number)
      {:ok, sum} = Cell.new(Number)

      Arithmetic.adder(a, b, sum)

      Cell.add_content(sum, 8)
      Cell.add_content(a, 3)
      Process.sleep(@settle)

      assert Cell.read(b) == 5
    end

    test "backward: knowing sum and b computes a" do
      {:ok, a} = Cell.new(Number)
      {:ok, b} = Cell.new(Number)
      {:ok, sum} = Cell.new(Number)

      Arithmetic.adder(a, b, sum)

      Cell.add_content(sum, 8)
      Cell.add_content(b, 5)
      Process.sleep(@settle)

      assert Cell.read(a) == 3
    end
  end

  describe "multiplier (a * b = product)" do
    test "forward: knowing a and b computes product" do
      {:ok, a} = Cell.new(Number)
      {:ok, b} = Cell.new(Number)
      {:ok, product} = Cell.new(Number)

      Arithmetic.multiplier(a, b, product)

      Cell.add_content(a, 4)
      Cell.add_content(b, 7)
      Process.sleep(@settle)

      assert Cell.read(product) == 28
    end

    test "backward: knowing product and a computes b" do
      {:ok, a} = Cell.new(Number)
      {:ok, b} = Cell.new(Number)
      {:ok, product} = Cell.new(Number)

      Arithmetic.multiplier(a, b, product)

      Cell.add_content(product, 28)
      Cell.add_content(a, 4)
      Process.sleep(@settle)

      assert Cell.read(b) == 7.0
    end
  end

  describe "Fahrenheit/Celsius converter" do
    # The classic example from Radul's thesis.
    #
    # F = C * 9/5 + 32
    #
    # Network topology:
    #
    #   C ----[*]----> product ----[+]----> F
    #          |                     |
    #       nine_fifths          thirty_two
    #
    # With bidirectional propagators, setting either end computes the other.

    defp build_f_c_network do
      {:ok, f} = Cell.new(Number)
      {:ok, c} = Cell.new(Number)
      {:ok, nine_fifths} = Cell.new(Number)
      {:ok, thirty_two} = Cell.new(Number)
      {:ok, product} = Cell.new(Number)

      Arithmetic.constant(nine_fifths, 9 / 5)
      Arithmetic.constant(thirty_two, 32)

      # C * 9/5 = product
      Arithmetic.multiplier(c, nine_fifths, product)
      # product + 32 = F
      Arithmetic.adder(product, thirty_two, f)

      {f, c}
    end

    test "Celsius to Fahrenheit: 0°C = 32°F" do
      {f, c} = build_f_c_network()

      Cell.add_content(c, 0)
      Process.sleep(@settle)

      assert_in_delta Cell.read(f), 32.0, 0.001
    end

    test "Celsius to Fahrenheit: 100°C = 212°F" do
      {f, c} = build_f_c_network()

      Cell.add_content(c, 100)
      Process.sleep(@settle)

      assert_in_delta Cell.read(f), 212.0, 0.001
    end

    test "Fahrenheit to Celsius: 32°F = 0°C" do
      {f, c} = build_f_c_network()

      Cell.add_content(f, 32)
      Process.sleep(@settle)

      assert_in_delta Cell.read(c), 0.0, 0.001
    end

    test "Fahrenheit to Celsius: 212°F = 100°C" do
      {f, c} = build_f_c_network()

      Cell.add_content(f, 212)
      Process.sleep(@settle)

      assert_in_delta Cell.read(c), 100.0, 0.001
    end

    test "Fahrenheit to Celsius: 72°F ≈ 22.22°C" do
      {f, c} = build_f_c_network()

      Cell.add_content(f, 72)
      Process.sleep(@settle)

      assert_in_delta Cell.read(c), 22.222, 0.01
    end
  end
end
