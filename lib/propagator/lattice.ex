defmodule Propagator.Lattice do
  @moduledoc """
  Behaviour for lattice types used in propagator cells.

  A lattice defines a partial order with a merge operation (join/least upper bound),
  a bottom element (no information), and a top element (contradiction).

  The key invariant: merge(a, b) >= a and merge(a, b) >= b in the lattice ordering.
  If merging ever produces top, we have a contradiction.
  """

  @type value :: term()

  @doc "The bottom element — no information yet."
  @callback bottom() :: value()

  @doc "The top element — contradiction."
  @callback top() :: value()

  @doc """
  Merge two values in the lattice (least upper bound / join).
  Must be commutative, associative, and idempotent.
  """
  @callback merge(value(), value()) :: value()
end
