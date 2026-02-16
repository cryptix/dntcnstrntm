defmodule Propagator.Network do
  @moduledoc """
  A Network GenServer that consolidates cells and propagators into a single process.

  Phase 3 architectural shift: instead of one GenServer per cell and one spawned
  process per propagator, the Network holds all cells and propagators in plain maps
  and runs the propagation loop in-memory. This eliminates message-passing overhead
  at scale while preserving the same public API.

  Cells are now BeliefCells — they hold `{value, tms_node}` pairs, and the "current"
  value is derived from which TMS nodes are `:in`. This integrates the propagator
  network with the JTMS for belief tracking and graceful retraction.
  """

  use GenServer
  alias Propagator.JTMS

  # --- Public API ---

  @doc "Start a new propagator network with an associated JTMS."
  def new do
    {:ok, jtms} = JTMS.new()
    GenServer.start_link(__MODULE__, %{jtms: jtms})
  end

  @doc "Create a new belief cell in the network. Returns the cell ID."
  def create_cell(network) do
    GenServer.call(network, :create_cell)
  end

  @doc """
  Read the current value of a cell.

  Returns the active value derived from {value, tms_node} pairs where the
  TMS node is `:in`. If no beliefs are active, returns `:nothing`.
  If multiple conflicting beliefs are active, returns `:contradiction`.
  """
  def read_cell(network, cell_id) do
    GenServer.call(network, {:read_cell, cell_id})
  end

  @doc """
  Add content to a cell with an optional informant.

  - If `informant` is provided, creates a TMS assumption for this value.
  - The value is stored as a {value, tms_node} pair.
  - Triggers propagation if the active value changed.
  """
  def add_content(network, cell_id, value, informant \\ nil) do
    GenServer.call(network, {:add_content, cell_id, value, informant})
  end

  @doc """
  Retract a belief from a cell.

  Finds the TMS node associated with the given informant and retracts it.
  This may cause the cell's active value to change and trigger propagation.
  """
  def retract_content(network, cell_id, informant) do
    GenServer.call(network, {:retract_content, cell_id, informant})
  end

  @doc """
  Create a propagator in the network.

  - `input_cells` — list of cell IDs to watch
  - `output_cells` — list of cell IDs to write to
  - `fun` — fn(input_values) -> [{output_cell_id, value}] | :skip
  - `informant` — identifier for this propagator (used in TMS justifications)

  The propagator subscribes to all input cells and fires whenever any input changes.
  When it computes new values, it creates TMS justifications linking the outputs
  to the inputs.
  """
  def create_propagator(network, input_cells, output_cells, fun, informant) do
    GenServer.call(network, {:create_propagator, input_cells, output_cells, fun, informant})
  end

  @doc "Get the JTMS instance associated with this network."
  def jtms(network) do
    GenServer.call(network, :get_jtms)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(%{jtms: jtms}) do
    state = %{
      jtms: jtms,
      cells: %{},
      propagators: %{},
      next_cell_id: 1,
      next_propagator_id: 1
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:create_cell, _from, state) do
    cell_id = state.next_cell_id
    cell = %{
      id: cell_id,
      # List of %{value, tms_node, informant} beliefs
      beliefs: [],
      # Set of propagator IDs that subscribe to this cell
      subscribers: MapSet.new()
    }

    state =
      state
      |> put_in([:cells, cell_id], cell)
      |> update_in([:next_cell_id], &(&1 + 1))

    {:reply, cell_id, state}
  end

  def handle_call({:read_cell, cell_id}, _from, state) do
    case Map.fetch(state.cells, cell_id) do
      {:ok, cell} ->
        value = compute_active_value(state, cell)
        {:reply, value, state}

      :error ->
        {:reply, {:error, :cell_not_found}, state}
    end
  end

  def handle_call({:add_content, cell_id, value, informant}, _from, state) do
    case Map.fetch(state.cells, cell_id) do
      {:ok, cell} ->
        # Reject nil informant - all beliefs must be traceable
        if informant == nil do
          {:reply, {:error, :informant_required}, state}
        else
          old_active_value = compute_active_value(state, cell)

          # Check if we already have an ACTIVE belief with this exact informant and value
          existing =
            Enum.find(cell.beliefs, fn b ->
              b.informant == informant && values_equal?(b.value, value) &&
                JTMS.node_in?(state.jtms, b.tms_node)
            end)

          state =
            if existing do
              # Already have this exact active belief, nothing to do
              state
            else
              # Create new TMS node and assume it
              node_name = {cell_id, value, informant, make_ref()}
              JTMS.create_node(state.jtms, node_name)
              JTMS.assume_node(state.jtms, node_name)

              belief = %{value: value, tms_node: node_name, informant: informant}
              update_in(state, [:cells, cell_id, :beliefs], &[belief | &1])
            end

          new_active_value = compute_active_value(state, state.cells[cell_id])

          # If the active value changed, trigger propagation
          state =
            if new_active_value != old_active_value do
              propagate(state, cell_id)
            else
              state
            end

          {:reply, :ok, state}
        end

      :error ->
        {:reply, {:error, :cell_not_found}, state}
    end
  end

  def handle_call({:retract_content, cell_id, informant}, _from, state) do
    case Map.fetch(state.cells, cell_id) do
      {:ok, cell} ->
        # Find and retract all TMS nodes associated with this informant
        beliefs = Enum.filter(cell.beliefs, fn b -> b.informant == informant end)

        state =
          Enum.reduce(beliefs, state, fn belief, s ->
            JTMS.retract_assumption(s.jtms, belief.tms_node)
            s
          end)

        # After retraction, TMS labels may have changed for many cells.
        # We need to check all cells and re-propagate any whose active values changed.
        state = check_all_cells_and_propagate(state)

        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :cell_not_found}, state}
    end
  end

  def handle_call({:create_propagator, input_cells, output_cells, fun, informant}, _from, state) do
    # Validate that all input cells exist
    missing_inputs = Enum.reject(input_cells, &Map.has_key?(state.cells, &1))

    if Enum.empty?(missing_inputs) do
      prop_id = state.next_propagator_id

      propagator = %{
        id: prop_id,
        inputs: input_cells,
        outputs: output_cells,
        fun: fun,
        informant: informant
      }

      # Subscribe this propagator to all input cells
      state =
        Enum.reduce(input_cells, state, fn cell_id, s ->
          update_in(s, [:cells, cell_id, :subscribers], &MapSet.put(&1, prop_id))
        end)

      state =
        state
        |> put_in([:propagators, prop_id], propagator)
        |> update_in([:next_propagator_id], &(&1 + 1))

      # Fire the propagator once immediately
      state = fire_propagator(state, prop_id)

      {:reply, prop_id, state}
    else
      {:reply, {:error, {:cells_not_found, missing_inputs}}, state}
    end
  end

  def handle_call(:get_jtms, _from, state) do
    {:reply, state.jtms, state}
  end

  # --- Internal helpers ---

  # Check if two values are equal, using epsilon comparison for floats
  defp values_equal?(a, b) when is_float(a) and is_float(b) do
    abs(a - b) < 1.0e-9
  end

  defp values_equal?(a, b) when is_float(a) and is_number(b) do
    abs(a - b) < 1.0e-9
  end

  defp values_equal?(a, b) when is_number(a) and is_float(b) do
    abs(a - b) < 1.0e-9
  end

  defp values_equal?(a, b), do: a == b

  # After a TMS change (like retraction), re-fire all propagators.
  # This ensures that any cells whose active values changed will propagate correctly.
  defp check_all_cells_and_propagate(state) do
    # Re-fire all propagators (they will skip if inputs haven't meaningfully changed)
    Enum.reduce(state.propagators, state, fn {prop_id, _prop}, s ->
      fire_propagator(s, prop_id)
    end)
  end

  # Compute the active value of a cell from its beliefs.
  # A belief is active if its TMS node is :in.
  defp compute_active_value(state, cell) do
    active_values =
      cell.beliefs
      |> Enum.filter(fn belief ->
        JTMS.node_in?(state.jtms, belief.tms_node)
      end)
      |> Enum.map(fn belief -> belief.value end)

    case active_values do
      [] ->
        :nothing

      [single_value] ->
        single_value

      [first | rest] ->
        # Multiple active values — check if they're all equal (with epsilon for floats)
        if Enum.all?(rest, &values_equal?(first, &1)) do
          first
        else
          :contradiction
        end
    end
  end

  # Propagate changes from a cell to all subscribed propagators.
  defp propagate(state, cell_id) do
    cell = state.cells[cell_id]

    Enum.reduce(cell.subscribers, state, fn prop_id, s ->
      fire_propagator(s, prop_id)
    end)
  end

  # Fire a single propagator: read inputs, run function, write outputs with justifications.
  defp fire_propagator(state, prop_id) do
    prop = state.propagators[prop_id]
    input_values = Enum.map(prop.inputs, &compute_active_value(state, state.cells[&1]))

    case prop.fun.(input_values) do
      :skip ->
        state

      writes when is_list(writes) ->
        Enum.reduce(writes, state, fn {output_cell_id, value}, s ->
          # Add the content and create a TMS justification
          add_derived_content(s, output_cell_id, value, prop)
        end)
    end
  end

  # Add derived content to a cell and create a TMS justification.
  defp add_derived_content(state, cell_id, value, propagator) do
    # Validate that the output cell exists
    case Map.fetch(state.cells, cell_id) do
      :error ->
        # Output cell doesn't exist - skip this write
        state

      {:ok, cell} ->
        do_add_derived_content(state, cell, cell_id, value, propagator)
    end
  end

  defp do_add_derived_content(state, cell, cell_id, value, propagator) do
    old_active_value = compute_active_value(state, cell)

    # Check if we already derived this exact value from this propagator
    existing =
      Enum.find(cell.beliefs, fn b ->
        b.informant == propagator.informant && values_equal?(b.value, value)
      end)

    state =
      if existing do
        # Already have this derived belief, just update its justification
        # Find all active input nodes
        input_nodes =
          propagator.inputs
          |> Enum.flat_map(fn input_cell_id ->
            input_cell = state.cells[input_cell_id]

            # Find all active beliefs in the input cell
            input_cell.beliefs
            |> Enum.filter(fn belief ->
              JTMS.node_in?(state.jtms, belief.tms_node)
            end)
            |> Enum.map(fn belief -> belief.tms_node end)
          end)

        # Re-justify the existing node
        JTMS.justify_node(state.jtms, existing.tms_node, propagator.informant, input_nodes)
        state
      else
        # Create TMS node for this derived value
        node_name = {cell_id, value, propagator.informant, make_ref()}
        JTMS.create_node(state.jtms, node_name)

        # Create justification: this value is believed because all input nodes are :in
        input_nodes =
          propagator.inputs
          |> Enum.flat_map(fn input_cell_id ->
            input_cell = state.cells[input_cell_id]

            # Find all active beliefs in the input cell
            input_cell.beliefs
            |> Enum.filter(fn belief ->
              JTMS.node_in?(state.jtms, belief.tms_node)
            end)
            |> Enum.map(fn belief -> belief.tms_node end)
          end)

        JTMS.justify_node(state.jtms, node_name, propagator.informant, input_nodes)

        # Store the belief
        belief = %{value: value, tms_node: node_name, informant: propagator.informant}
        update_in(state, [:cells, cell_id, :beliefs], &[belief | &1])
      end

    new_active_value = compute_active_value(state, state.cells[cell_id])

    # If active value changed, propagate further
    if new_active_value != old_active_value do
      propagate(state, cell_id)
    else
      state
    end
  end
end
