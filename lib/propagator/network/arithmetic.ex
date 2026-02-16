defmodule Propagator.Network.Arithmetic do
  @moduledoc """
  Bidirectional arithmetic constraints for the Network-based propagator system.

  These functions create propagators within a Network that work with BeliefCells
  and automatically generate TMS justifications for derived values.

  Each constraint installs multiple one-directional propagators so information
  can flow in any direction, just like the original Propagator.Arithmetic module,
  but integrated with the JTMS for belief tracking.
  """

  alias Propagator.Network

  @doc """
  Constraint: a + b = sum

  Installs three propagators:
  - a, b known → sum = a + b
  - a, sum known → b = sum - a
  - b, sum known → a = sum - b

  Each derived value is linked via TMS justifications to its inputs.
  """
  def adder(network, a_cell, b_cell, sum_cell) do
    # Forward: a + b -> sum
    Network.create_propagator(
      network,
      [a_cell, b_cell],
      [sum_cell],
      fn
        [:contradiction, _] -> [{sum_cell, :contradiction}]
        [_, :contradiction] -> [{sum_cell, :contradiction}]
        [av, bv] when is_number(av) and is_number(bv) -> [{sum_cell, av + bv}]
        _ -> :skip
      end,
      {:adder_forward, a_cell, b_cell, sum_cell}
    )

    # Backward: sum - a -> b
    Network.create_propagator(
      network,
      [sum_cell, a_cell],
      [b_cell],
      fn
        [:contradiction, _] -> [{b_cell, :contradiction}]
        [_, :contradiction] -> [{b_cell, :contradiction}]
        [sv, av] when is_number(sv) and is_number(av) -> [{b_cell, sv - av}]
        _ -> :skip
      end,
      {:adder_backward_b, a_cell, b_cell, sum_cell}
    )

    # Backward: sum - b -> a
    Network.create_propagator(
      network,
      [sum_cell, b_cell],
      [a_cell],
      fn
        [:contradiction, _] -> [{a_cell, :contradiction}]
        [_, :contradiction] -> [{a_cell, :contradiction}]
        [sv, bv] when is_number(sv) and is_number(bv) -> [{a_cell, sv - bv}]
        _ -> :skip
      end,
      {:adder_backward_a, a_cell, b_cell, sum_cell}
    )
  end

  @doc """
  Constraint: a * b = product

  Installs three propagators:
  - a, b known → product = a * b
  - a, product known → b = product / a  (when a != 0)
  - b, product known → a = product / b  (when b != 0)

  Each derived value is linked via TMS justifications to its inputs.
  """
  def multiplier(network, a_cell, b_cell, product_cell) do
    # Forward: a * b -> product
    Network.create_propagator(
      network,
      [a_cell, b_cell],
      [product_cell],
      fn
        [:contradiction, _] -> [{product_cell, :contradiction}]
        [_, :contradiction] -> [{product_cell, :contradiction}]
        [av, bv] when is_number(av) and is_number(bv) -> [{product_cell, av * bv}]
        _ -> :skip
      end,
      {:multiplier_forward, a_cell, b_cell, product_cell}
    )

    # Backward: product / a -> b
    Network.create_propagator(
      network,
      [product_cell, a_cell],
      [b_cell],
      fn
        [:contradiction, _] -> [{b_cell, :contradiction}]
        [_, :contradiction] -> [{b_cell, :contradiction}]
        [pv, av] when is_number(pv) and is_number(av) and av != 0 -> [{b_cell, pv / av}]
        _ -> :skip
      end,
      {:multiplier_backward_b, a_cell, b_cell, product_cell}
    )

    # Backward: product / b -> a
    Network.create_propagator(
      network,
      [product_cell, b_cell],
      [a_cell],
      fn
        [:contradiction, _] -> [{a_cell, :contradiction}]
        [_, :contradiction] -> [{a_cell, :contradiction}]
        [pv, bv] when is_number(pv) and is_number(bv) and bv != 0 -> [{a_cell, pv / bv}]
        _ -> :skip
      end,
      {:multiplier_backward_a, a_cell, b_cell, product_cell}
    )
  end

  @doc """
  Constraint: cell holds a known constant value.

  Adds the value to the cell as an assumption with the given informant.
  This creates a TMS assumption that can be retracted later.
  """
  def constant(network, cell, value, informant \\ :constant) do
    Network.add_content(network, cell, value, informant)
  end
end
