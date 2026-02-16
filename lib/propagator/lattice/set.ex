defmodule Propagator.Lattice.Set do
  @moduledoc """
  A lattice of sets under intersection (greatest lower bound).

  Useful for constraint domains: start with all possibilities, narrow down
  by intersecting with constraints. Bottom is the empty set (contradiction),
  top is the universe of all values.

  This is dual to the typical set union lattice — we're using intersection
  because constraint solving is about *eliminating* values from domains.
  """

  @behaviour Propagator.Lattice

  @doc """
  Create a new set lattice value.
  """
  def new(elements) when is_list(elements) do
    MapSet.new(elements)
  end

  def new(%MapSet{} = set), do: set

  @impl true
  def bottom, do: MapSet.new()

  @impl true
  def top do
    # In practice, we can't represent "all possible values"
    # So top is context-dependent and must be provided explicitly
    raise "Set lattice top must be provided explicitly for each problem domain"
  end

  @impl true
  def merge(set1, set2) when is_map(set1) and is_map(set2) do
    # Intersection: keep only values that satisfy both constraints
    result = MapSet.intersection(set1, set2)

    cond do
      MapSet.size(result) == 0 ->
        # Empty set = contradiction
        {:ok, :contradiction}

      true ->
        {:ok, result}
    end
  end

  @doc """
  Check if a value is in the set.
  """
  def member?(set, value) when is_map(set) do
    MapSet.member?(set, value)
  end

  @doc """
  Get the size of the set (remaining domain size).
  """
  def size(set) when is_map(set) do
    MapSet.size(set)
  end

  @doc """
  Convert the set to a list.
  """
  def to_list(set) when is_map(set) do
    MapSet.to_list(set)
  end
end
