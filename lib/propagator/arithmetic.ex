defmodule Propagator.Arithmetic do
  @moduledoc """
  Bidirectional arithmetic constraints built from primitive propagators.

  Each constraint (e.g. `adder(a, b, sum)`) installs multiple one-directional
  propagators so that information can flow in any direction. If you know `sum`
  and `a`, the network deduces `b`, and so on.
  """

  alias Propagator.{Cell, Propagator}

  @doc """
  Constraint: a + b = sum

  Installs three propagators:
  - a, b known → sum = a + b
  - a, sum known → b = sum - a
  - b, sum known → a = sum - b
  """
  def adder(a, b, sum) do
    # Forward: a + b -> sum
    Propagator.new([a, b], fn
      [av, bv] when is_number(av) and is_number(bv) -> [{sum, av + bv}]
      _ -> :skip
    end)

    # Backward: sum - a -> b
    Propagator.new([sum, a], fn
      [sv, av] when is_number(sv) and is_number(av) -> [{b, sv - av}]
      _ -> :skip
    end)

    # Backward: sum - b -> a
    Propagator.new([sum, b], fn
      [sv, bv] when is_number(sv) and is_number(bv) -> [{a, sv - bv}]
      _ -> :skip
    end)
  end

  @doc """
  Constraint: a * b = product

  Installs three propagators:
  - a, b known → product = a * b
  - a, product known → b = product / a  (when a != 0)
  - b, product known → a = product / b  (when b != 0)
  """
  def multiplier(a, b, product) do
    # Forward: a * b -> product
    Propagator.new([a, b], fn
      [av, bv] when is_number(av) and is_number(bv) -> [{product, av * bv}]
      _ -> :skip
    end)

    # Backward: product / a -> b
    Propagator.new([product, a], fn
      [pv, av] when is_number(pv) and is_number(av) and av != 0 -> [{b, pv / av}]
      _ -> :skip
    end)

    # Backward: product / b -> a
    Propagator.new([product, b], fn
      [pv, bv] when is_number(pv) and is_number(bv) and bv != 0 -> [{a, pv / bv}]
      _ -> :skip
    end)
  end

  @doc """
  Constraint: cell holds a known constant value.
  Immediately writes the value into the cell.
  """
  def constant(cell, value) do
    Cell.add_content(cell, value)
  end
end
