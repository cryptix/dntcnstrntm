defmodule Propagator.Propagator do
  @moduledoc """
  A Propagator is a lightweight process that watches input cells and pushes
  derived values into output cells.

  It subscribes to all input cells. On any `:propagate` message it reads
  all inputs, applies its function, and calls `add_content` on each output
  cell with the result.

  The function receives the list of input values and returns a list of
  `{cell, value}` pairs to write. If any input is `:nothing`, the function
  can choose to do nothing (return an empty list) — this is the standard
  "wait until all inputs are known" pattern.
  """

  alias Propagator.Cell

  @doc """
  Spawn a propagator.

  - `inputs` — list of cell pids to subscribe to
  - `fun` — fn(input_values) -> [{output_cell, value}, ...] | :skip

  The propagator fires once immediately after setup, then again every time
  an input cell notifies it.
  """
  def new(inputs, fun) do
    pid = spawn_link(fn -> loop(inputs, fun) end)

    Enum.each(inputs, fn cell -> Cell.subscribe(cell, pid) end)

    # Fire once immediately to pick up any values already in the cells.
    send(pid, :propagate)

    pid
  end

  defp loop(inputs, fun) do
    receive do
      :propagate ->
        values = Enum.map(inputs, &Cell.read/1)

        case fun.(values) do
          :skip ->
            :ok

          writes when is_list(writes) ->
            Enum.each(writes, fn {cell, value} ->
              Cell.add_content(cell, value)
            end)
        end

        loop(inputs, fun)
    end
  end
end
