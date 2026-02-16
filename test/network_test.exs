defmodule Propagator.NetworkTest do
  use ExUnit.Case, async: true

  alias Propagator.Network
  alias Propagator.Network.Arithmetic

  # Small delay to let async propagation settle
  @settle 50

  describe "BeliefCell basics" do
    test "new cell starts with :nothing" do
      {:ok, net} = Network.new()
      cell = Network.create_cell(net)
      assert Network.read_cell(net, cell) == :nothing
    end

    test "adding content with an assumption makes it active" do
      {:ok, net} = Network.new()
      cell = Network.create_cell(net)

      Network.add_content(net, cell, 42, :source1)
      assert Network.read_cell(net, cell) == 42
    end

    test "multiple non-conflicting beliefs with same value" do
      {:ok, net} = Network.new()
      cell = Network.create_cell(net)

      Network.add_content(net, cell, 42, :source1)
      Network.add_content(net, cell, 42, :source2)
      assert Network.read_cell(net, cell) == 42
    end

    test "retracting an assumption removes the value" do
      {:ok, net} = Network.new()
      cell = Network.create_cell(net)

      Network.add_content(net, cell, 42, :source1)
      assert Network.read_cell(net, cell) == 42

      Network.retract_content(net, cell, :source1)
      assert Network.read_cell(net, cell) == :nothing
    end

    test "retracting one assumption keeps others active" do
      {:ok, net} = Network.new()
      cell = Network.create_cell(net)

      Network.add_content(net, cell, 42, :source1)
      Network.add_content(net, cell, 42, :source2)
      assert Network.read_cell(net, cell) == 42

      Network.retract_content(net, cell, :source1)
      assert Network.read_cell(net, cell) == 42
    end

    test "conflicting beliefs produce contradiction" do
      {:ok, net} = Network.new()
      cell = Network.create_cell(net)

      Network.add_content(net, cell, 42, :source1)
      Network.add_content(net, cell, 99, :source2)
      assert Network.read_cell(net, cell) == :contradiction
    end

    test "retracting a conflicting belief resolves contradiction" do
      {:ok, net} = Network.new()
      cell = Network.create_cell(net)

      Network.add_content(net, cell, 42, :source1)
      Network.add_content(net, cell, 99, :source2)
      assert Network.read_cell(net, cell) == :contradiction

      Network.retract_content(net, cell, :source2)
      assert Network.read_cell(net, cell) == 42
    end
  end

  describe "simple propagation with TMS" do
    test "forward propagation creates justified beliefs" do
      {:ok, net} = Network.new()
      a = Network.create_cell(net)
      b = Network.create_cell(net)
      sum = Network.create_cell(net)

      Arithmetic.adder(net, a, b, sum)
      Process.sleep(@settle)

      Network.add_content(net, a, 3, :fact_a)
      Network.add_content(net, b, 5, :fact_b)
      Process.sleep(@settle)

      assert Network.read_cell(net, sum) == 8
    end

    test "retracting input assumption retracts derived belief" do
      {:ok, net} = Network.new()
      a = Network.create_cell(net)
      b = Network.create_cell(net)
      sum = Network.create_cell(net)

      Arithmetic.adder(net, a, b, sum)
      Process.sleep(@settle)

      Network.add_content(net, a, 3, :fact_a)
      Network.add_content(net, b, 5, :fact_b)
      Process.sleep(@settle)
      assert Network.read_cell(net, sum) == 8

      # Retract one input — sum should lose its justification
      Network.retract_content(net, a, :fact_a)
      Process.sleep(@settle)
      assert Network.read_cell(net, sum) == :nothing
    end

    test "backward propagation works" do
      {:ok, net} = Network.new()
      a = Network.create_cell(net)
      b = Network.create_cell(net)
      sum = Network.create_cell(net)

      Arithmetic.adder(net, a, b, sum)
      Process.sleep(@settle)

      Network.add_content(net, sum, 8, :fact_sum)
      Network.add_content(net, a, 3, :fact_a)
      Process.sleep(@settle)

      assert Network.read_cell(net, b) == 5
    end

    test "retracting input to backward propagation removes output" do
      {:ok, net} = Network.new()
      a = Network.create_cell(net)
      b = Network.create_cell(net)
      sum = Network.create_cell(net)

      Arithmetic.adder(net, a, b, sum)
      Process.sleep(@settle)

      Network.add_content(net, sum, 8, :fact_sum)
      Network.add_content(net, a, 3, :fact_a)
      Process.sleep(@settle)
      assert Network.read_cell(net, b) == 5

      Network.retract_content(net, sum, :fact_sum)
      Process.sleep(@settle)
      assert Network.read_cell(net, b) == :nothing
    end
  end

  describe "retraction cascades" do
    test "chain propagation: A → B → C, retract A cascades to C" do
      {:ok, net} = Network.new()
      a = Network.create_cell(net)
      b = Network.create_cell(net)
      c = Network.create_cell(net)
      const_2 = Network.create_cell(net)
      const_3 = Network.create_cell(net)

      # Network: A * 2 = B, B * 3 = C
      Arithmetic.constant(net, const_2, 2, :const_2)
      Arithmetic.constant(net, const_3, 3, :const_3)
      Process.sleep(@settle)

      Arithmetic.multiplier(net, a, const_2, b)
      Arithmetic.multiplier(net, b, const_3, c)
      Process.sleep(@settle)

      Network.add_content(net, a, 5, :fact_a)
      Process.sleep(@settle)

      # A=5, B=10, C=30
      assert Network.read_cell(net, a) == 5
      assert Network.read_cell(net, b) == 10.0
      assert Network.read_cell(net, c) == 30.0

      # Retract A — entire chain should collapse
      Network.retract_content(net, a, :fact_a)
      Process.sleep(@settle)

      assert Network.read_cell(net, a) == :nothing
      assert Network.read_cell(net, b) == :nothing
      assert Network.read_cell(net, c) == :nothing
    end

    test "diamond propagation with retraction" do
      {:ok, net} = Network.new()
      a = Network.create_cell(net)
      b = Network.create_cell(net)
      c = Network.create_cell(net)
      d = Network.create_cell(net)
      const_2 = Network.create_cell(net)
      const_3 = Network.create_cell(net)

      # Diamond: A → B (A*2), A → C (A*3), B+C → D
      Arithmetic.constant(net, const_2, 2, :const_2)
      Arithmetic.constant(net, const_3, 3, :const_3)
      Process.sleep(@settle)

      Arithmetic.multiplier(net, a, const_2, b)
      Arithmetic.multiplier(net, a, const_3, c)
      Arithmetic.adder(net, b, c, d)
      Process.sleep(@settle)

      Network.add_content(net, a, 4, :fact_a)
      Process.sleep(@settle)

      # A=4, B=8, C=12, D=20
      assert Network.read_cell(net, a) == 4
      assert Network.read_cell(net, b) == 8.0
      assert Network.read_cell(net, c) == 12.0
      assert Network.read_cell(net, d) == 20.0

      # Retract A — entire diamond collapses
      Network.retract_content(net, a, :fact_a)
      Process.sleep(@settle)

      assert Network.read_cell(net, a) == :nothing
      assert Network.read_cell(net, b) == :nothing
      assert Network.read_cell(net, c) == :nothing
      assert Network.read_cell(net, d) == :nothing
    end
  end

  describe "multiplier constraint" do
    test "forward: a * b = product" do
      {:ok, net} = Network.new()
      a = Network.create_cell(net)
      b = Network.create_cell(net)
      product = Network.create_cell(net)

      Arithmetic.multiplier(net, a, b, product)
      Process.sleep(@settle)

      Network.add_content(net, a, 4, :fact_a)
      Network.add_content(net, b, 7, :fact_b)
      Process.sleep(@settle)

      assert Network.read_cell(net, product) == 28.0
    end

    test "backward: product / a = b" do
      {:ok, net} = Network.new()
      a = Network.create_cell(net)
      b = Network.create_cell(net)
      product = Network.create_cell(net)

      Arithmetic.multiplier(net, a, b, product)
      Process.sleep(@settle)

      Network.add_content(net, product, 28, :fact_product)
      Network.add_content(net, a, 4, :fact_a)
      Process.sleep(@settle)

      assert Network.read_cell(net, b) == 7.0
    end
  end

  describe "belief tracking scenario" do
    test "multiple sources of evidence, retract weakest" do
      {:ok, net} = Network.new()
      temperature = Network.create_cell(net)

      # Three sources say different things
      Network.add_content(net, temperature, 72, :sensor1)
      Network.add_content(net, temperature, 73, :sensor2)
      Network.add_content(net, temperature, 72, :sensor3)

      # Contradiction because 72 vs 73
      assert Network.read_cell(net, temperature) == :contradiction

      # Retract the outlier sensor
      Network.retract_content(net, temperature, :sensor2)

      # Now both remaining sources agree
      assert Network.read_cell(net, temperature) == 72
    end

    test "derived beliefs depend on assumptions" do
      {:ok, net} = Network.new()

      # Scenario: computing fuel efficiency
      # MPG = miles / gallons
      miles = Network.create_cell(net)
      gallons = Network.create_cell(net)
      mpg = Network.create_cell(net)

      # Create a simple divider using multiplier backward propagation
      # miles = mpg * gallons, so mpg = miles / gallons
      Arithmetic.multiplier(net, mpg, gallons, miles)
      Process.sleep(@settle)

      # Assume we drove 300 miles on 10 gallons
      Network.add_content(net, miles, 300, :odometer)
      Network.add_content(net, gallons, 10, :fuel_gauge)
      Process.sleep(@settle)

      assert Network.read_cell(net, mpg) == 30.0

      # Oops, fuel gauge was wrong — actually 12 gallons
      Network.retract_content(net, gallons, :fuel_gauge)
      Network.add_content(net, gallons, 12, :fuel_gauge_corrected)
      Process.sleep(@settle)

      assert Network.read_cell(net, mpg) == 25.0
    end
  end

  describe "Fahrenheit/Celsius with retractable sources" do
    # Enhanced version: multiple thermometers can provide readings,
    # and we can retract faulty sensors.

    defp build_f_c_network do
      {:ok, net} = Network.new()
      f = Network.create_cell(net)
      c = Network.create_cell(net)
      nine_fifths = Network.create_cell(net)
      thirty_two = Network.create_cell(net)
      product = Network.create_cell(net)

      Arithmetic.constant(net, nine_fifths, 9 / 5, :const_9_5)
      Arithmetic.constant(net, thirty_two, 32, :const_32)
      Process.sleep(@settle)

      # C * 9/5 = product
      Arithmetic.multiplier(net, c, nine_fifths, product)
      # product + 32 = F
      Arithmetic.adder(net, product, thirty_two, f)
      Process.sleep(@settle)

      {net, f, c}
    end

    test "Celsius to Fahrenheit: 0°C = 32°F" do
      {net, f, c} = build_f_c_network()

      Network.add_content(net, c, 0, :thermometer)
      Process.sleep(@settle)

      assert_in_delta Network.read_cell(net, f), 32.0, 0.001
    end

    test "Celsius to Fahrenheit: 100°C = 212°F" do
      {net, f, c} = build_f_c_network()

      Network.add_content(net, c, 100, :thermometer)
      Process.sleep(@settle)

      assert_in_delta Network.read_cell(net, f), 212.0, 0.001
    end

    test "retract temperature reading" do
      {net, f, c} = build_f_c_network()

      Network.add_content(net, c, 100, :thermometer)
      Process.sleep(@settle)
      assert_in_delta Network.read_cell(net, f), 212.0, 0.001

      # Retract the reading
      Network.retract_content(net, c, :thermometer)
      Process.sleep(@settle)

      assert Network.read_cell(net, c) == :nothing
      assert Network.read_cell(net, f) == :nothing
    end

    test "multiple thermometers, retract faulty one" do
      {net, f, c} = build_f_c_network()

      Network.add_content(net, c, 100, :thermometer1)
      Network.add_content(net, c, 100, :thermometer2)
      Process.sleep(@settle)

      assert_in_delta Network.read_cell(net, f), 212.0, 0.001

      # One thermometer fails and is retracted
      Network.retract_content(net, c, :thermometer1)
      Process.sleep(@settle)

      # Still have the other thermometer
      assert_in_delta Network.read_cell(net, f), 212.0, 0.001
    end

    test "conflicting thermometers show contradiction" do
      {net, f, c} = build_f_c_network()

      Network.add_content(net, c, 0, :thermometer1)
      Network.add_content(net, c, 100, :thermometer2)
      Process.sleep(@settle)

      assert Network.read_cell(net, c) == :contradiction
      assert Network.read_cell(net, f) == :contradiction
    end
  end
end
