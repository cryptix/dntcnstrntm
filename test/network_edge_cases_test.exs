defmodule Propagator.NetworkEdgeCasesTest do
  use ExUnit.Case, async: true

  alias Propagator.Network
  alias Propagator.Network.Arithmetic

  @settle 50

  describe "invalid cell_id handling" do
    test "add_content with non-existent cell_id returns error" do
      {:ok, net} = Network.new()

      # Try to add content to a cell that doesn't exist
      assert Network.add_content(net, 999, 42, :source) == {:error, :cell_not_found}
    end

    test "retract_content with non-existent cell_id returns error" do
      {:ok, net} = Network.new()

      # Try to retract from a cell that doesn't exist
      assert Network.retract_content(net, 999, :source) == {:error, :cell_not_found}
    end

    test "read_cell with non-existent cell_id returns error" do
      {:ok, net} = Network.new()

      # Try to read a cell that doesn't exist
      assert Network.read_cell(net, 999) == {:error, :cell_not_found}
    end
  end

  describe "invalid propagator setup" do
    test "creating propagator with non-existent input cells returns error" do
      {:ok, net} = Network.new()
      output = Network.create_cell(net)

      # Try to create a propagator with non-existent input cells
      result =
        Network.create_propagator(
          net,
          [999, 1000],
          [output],
          fn _ -> :skip end,
          :test_prop
        )

      assert {:error, {:cells_not_found, [999, 1000]}} = result
    end

    test "creating propagator with non-existent output cells is handled gracefully" do
      {:ok, net} = Network.new()
      input = Network.create_cell(net)

      # Propagator creation succeeds even if output cells don't exist yet
      Network.create_propagator(
        net,
        [input],
        [999],
        fn
          [v] when is_number(v) -> [{999, v * 2}]
          _ -> :skip
        end,
        :test_prop
      )

      # When we add content and the propagator fires, writes to non-existent cells are skipped
      # This should not crash
      Network.add_content(net, input, 5, :source)

      # Input should have the value
      assert Network.read_cell(net, input) == 5

      # Non-existent output cell should return error
      assert Network.read_cell(net, 999) == {:error, :cell_not_found}
    end
  end

  describe "nil informant handling" do
    test "adding content with nil informant returns error" do
      {:ok, net} = Network.new()
      cell = Network.create_cell(net)

      # Add content without an informant - should be rejected
      assert Network.add_content(net, cell, 42, nil) == {:error, :informant_required}

      # The cell should remain empty
      assert Network.read_cell(net, cell) == :nothing
    end

    test "adding multiple values with nil informant all return errors" do
      {:ok, net} = Network.new()
      cell = Network.create_cell(net)

      # Add multiple values with nil informant - all should fail
      assert Network.add_content(net, cell, 1, nil) == {:error, :informant_required}
      assert Network.add_content(net, cell, 2, nil) == {:error, :informant_required}
      assert Network.add_content(net, cell, 3, nil) == {:error, :informant_required}

      # Cell should still be empty
      assert Network.read_cell(net, cell) == :nothing
    end
  end

  describe "floating point equality issues" do
    test "close floating point values should not cause contradiction" do
      {:ok, net} = Network.new()
      cell = Network.create_cell(net)

      # Add two very close floating point values from different sources
      Network.add_content(net, cell, 1.0, :sensor1)
      Network.add_content(net, cell, 1.0 + 1.0e-14, :sensor2)

      # These should be considered equal, not contradictory (with epsilon comparison)
      result = Network.read_cell(net, cell)
      # Result will be one of the epsilon-equal values, not necessarily exactly 1.0
      assert is_float(result), "Expected float result, got #{inspect(result)}"
      assert_in_delta result, 1.0, 1.0e-9
    end

    test "propagated floating point values should not accumulate contradictions" do
      {:ok, net} = Network.new()
      a = Network.create_cell(net)
      b = Network.create_cell(net)
      sum = Network.create_cell(net)

      Arithmetic.adder(net, a, b, sum)
      Process.sleep(@settle)

      # Add values that will produce floating point results
      Network.add_content(net, a, 0.1, :source_a)
      Network.add_content(net, b, 0.2, :source_b)
      Process.sleep(@settle)

      result = Network.read_cell(net, sum)
      # 0.1 + 0.2 = 0.30000000000000004 in floating point
      # Should not be :contradiction
      assert is_number(result), "Expected numeric result, got #{inspect(result)}"
      assert_in_delta result, 0.3, 0.001
    end
  end

  describe "belief accumulation / memory leak" do
    test "beliefs list grows even when TMS nodes go :out" do
      {:ok, net} = Network.new()
      cell = Network.create_cell(net)

      # Add and retract many values
      for i <- 1..100 do
        informant = :"source_#{i}"
        Network.add_content(net, cell, i, informant)
        Network.retract_content(net, cell, informant)
      end

      # The cell should be empty
      assert Network.read_cell(net, cell) == :nothing

      # But the beliefs list has accumulated 100 entries (memory leak)
      # We can't easily verify this without exposing internals
      # This test documents the expected behavior
    end

    test "derived beliefs accumulate when inputs change frequently" do
      {:ok, net} = Network.new()
      a = Network.create_cell(net)
      b = Network.create_cell(net)
      sum = Network.create_cell(net)

      Arithmetic.adder(net, a, b, sum)
      Process.sleep(@settle)

      # Add initial values
      Network.add_content(net, a, 1, :source_a)
      Network.add_content(net, b, 2, :source_b)
      Process.sleep(@settle)
      assert Network.read_cell(net, sum) == 3

      # Retract and add new values many times
      for i <- 1..50 do
        Network.retract_content(net, a, :source_a)
        Process.sleep(@settle)
        Network.add_content(net, a, i, :source_a)
        Process.sleep(@settle)
      end

      # The sum cell's beliefs list has accumulated many derived values
      # that are no longer active (memory leak)
      # This test documents the issue
    end
  end

  describe "retraction edge cases" do
    test "retracting non-existent informant is a no-op" do
      {:ok, net} = Network.new()
      cell = Network.create_cell(net)

      Network.add_content(net, cell, 42, :source1)
      assert Network.read_cell(net, cell) == 42

      # Retract a different informant that doesn't exist
      Network.retract_content(net, cell, :non_existent)

      # Value should still be there
      assert Network.read_cell(net, cell) == 42
    end

    test "retracting the same assumption twice is a no-op" do
      {:ok, net} = Network.new()
      cell = Network.create_cell(net)

      Network.add_content(net, cell, 42, :source1)
      assert Network.read_cell(net, cell) == 42

      Network.retract_content(net, cell, :source1)
      assert Network.read_cell(net, cell) == :nothing

      # Retract again - should not crash
      Network.retract_content(net, cell, :source1)
      assert Network.read_cell(net, cell) == :nothing
    end
  end

  describe "propagation with :nothing values" do
    test "propagators handle :nothing inputs correctly" do
      {:ok, net} = Network.new()
      a = Network.create_cell(net)
      b = Network.create_cell(net)
      sum = Network.create_cell(net)

      Arithmetic.adder(net, a, b, sum)
      Process.sleep(@settle)

      # Both inputs are :nothing - sum should remain :nothing
      assert Network.read_cell(net, a) == :nothing
      assert Network.read_cell(net, b) == :nothing
      assert Network.read_cell(net, sum) == :nothing

      # Add one value
      Network.add_content(net, a, 5, :source_a)
      Process.sleep(@settle)

      # Sum still :nothing because b is :nothing
      assert Network.read_cell(net, sum) == :nothing
    end
  end

  describe "complex retraction scenarios" do
    test "retract then re-add same value should work" do
      {:ok, net} = Network.new()
      cell = Network.create_cell(net)

      Network.add_content(net, cell, 42, :source1)
      assert Network.read_cell(net, cell) == 42

      Network.retract_content(net, cell, :source1)
      assert Network.read_cell(net, cell) == :nothing

      Network.add_content(net, cell, 42, :source1)
      assert Network.read_cell(net, cell) == 42
    end

    test "retraction in middle of propagation chain" do
      {:ok, net} = Network.new()
      a = Network.create_cell(net)
      b = Network.create_cell(net)
      c = Network.create_cell(net)
      const_2 = Network.create_cell(net)

      Arithmetic.constant(net, const_2, 2, :const)
      Arithmetic.multiplier(net, a, const_2, b)
      Arithmetic.multiplier(net, b, const_2, c)
      Process.sleep(@settle)

      Network.add_content(net, a, 3, :source_a)
      Process.sleep(@settle)

      # a=3, b=6, c=12
      assert Network.read_cell(net, a) == 3
      assert Network.read_cell(net, b) == 6.0
      assert Network.read_cell(net, c) == 12.0

      # Retract the constant in the middle
      Network.retract_content(net, const_2, :const)
      Process.sleep(@settle)

      # All derived values should disappear
      assert Network.read_cell(net, const_2) == :nothing
      assert Network.read_cell(net, b) == :nothing
      assert Network.read_cell(net, c) == :nothing
      # But a should remain
      assert Network.read_cell(net, a) == 3
    end
  end
end
