defmodule Propagator.Lattice.Number do
  @moduledoc """
  A flat lattice over numbers.

       :contradiction (top)
        /   |   \\
      1.0  2.0  3.0  ...  (all concrete numbers, incomparable)
        \\   |   /
        :nothing (bottom)

  - bottom is :nothing (no information)
  - top is :contradiction (conflicting information)
  - merging two equal numbers keeps the value
  - merging :nothing with a number yields the number
  - merging two different numbers yields :contradiction
  """

  @behaviour Propagator.Lattice

  @epsilon 1.0e-10

  @impl true
  def bottom, do: :nothing

  @impl true
  def top, do: :contradiction

  @impl true
  def merge(:nothing, value), do: value
  def merge(value, :nothing), do: value
  def merge(:contradiction, _), do: :contradiction
  def merge(_, :contradiction), do: :contradiction

  def merge(a, b) when is_number(a) and is_number(b) do
    if close_enough?(a, b), do: a, else: :contradiction
  end

  defp close_enough?(a, b) do
    abs(a - b) <= @epsilon * max(abs(a), abs(b))
  end
end
