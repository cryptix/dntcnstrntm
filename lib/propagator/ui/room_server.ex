defmodule Propagator.UI.RoomServer do
  @moduledoc """
  GenServer that owns the Room domain instance and exposes it for the HTTP UI.

  Holds a `Propagator.Domain.Room` struct (which wraps a Network + JTMS) and
  provides an API for the router to read state, assert sensor values, retract
  them, and retrieve the full inspectable network snapshot.

  Using a GenServer here means the room is process-owned and survives router
  restarts; it's also a stable named process the HTTP layer can call directly.
  """

  use GenServer

  alias Propagator.Domain.Room
  alias Propagator.Network

  @name __MODULE__

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], Keyword.put_new(opts, :name, @name))
  end

  @doc "Read the active value of a named cell."
  def read(cell_name), do: GenServer.call(@name, {:read, cell_name})

  @doc "Assert a value into a named cell from a named source."
  def set(cell_name, value, source), do: GenServer.call(@name, {:set, cell_name, value, source})

  @doc "Retract all beliefs from a named source in a named cell."
  def retract(cell_name, source), do: GenServer.call(@name, {:retract, cell_name, source})

  @doc "Return full inspection snapshot enriched with domain metadata."
  def inspect_state, do: GenServer.call(@name, :inspect_state)

  @doc "Return events with id > since (newest first)."
  def get_events(since \\ 0), do: GenServer.call(@name, {:get_events, since})

  @doc "Return domain metadata: cell specs and rule specs."
  def domain_meta, do: GenServer.call(@name, :domain_meta)

  # ── GenServer callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_) do
    {:ok, room} = Room.new()
    {:ok, %{room: room}}
  end

  @impl true
  def handle_call({:read, cell_name}, _from, %{room: room} = state) do
    {:reply, Room.read(room, cell_name), state}
  end

  def handle_call({:set, cell_name, value, source}, _from, %{room: room} = state) do
    result = Room.set(room, cell_name, value, source)
    {:reply, result, state}
  end

  def handle_call({:retract, cell_name, source}, _from, %{room: room} = state) do
    result = Room.retract(room, cell_name, source)
    {:reply, result, state}
  end

  def handle_call(:inspect_state, _from, %{room: room} = state) do
    net_snapshot = Network.inspect_state(room.net)
    cell_ids = Room.cell_ids(room)

    # Build reverse map: cell_id → cell_name
    id_to_name = Map.new(cell_ids, fn {name, id} -> {id, name} end)

    # Enrich cell data with domain metadata
    cell_specs_by_name = Map.new(Room.cell_specs(), fn spec -> {spec.name, spec} end)

    named_cells =
      Map.new(net_snapshot.cells, fn {cell_id, cell_data} ->
        name = Map.get(id_to_name, cell_id, :"cell_#{cell_id}")
        spec = Map.get(cell_specs_by_name, name, %{type: :unknown, description: "", unit: nil})

        enriched =
          cell_data
          |> Map.put(:name, name)
          |> Map.put(:type, spec.type)
          |> Map.put(:description, spec.description)
          |> Map.put(:unit, spec.unit)

        {cell_id, enriched}
      end)

    # Enrich propagator data with rule name
    rule_specs_by_informant = Map.new(Room.rule_specs(), fn spec -> {spec.name, spec} end)

    named_propagators =
      Map.new(net_snapshot.propagators, fn {prop_id, prop_data} ->
        rule = Map.get(rule_specs_by_informant, prop_data.informant, %{name: nil, description: ""})

        enriched =
          prop_data
          |> Map.put(:rule_name, rule[:name] || prop_data.informant)
          |> Map.put(:description, rule[:description] || "")

        {prop_id, enriched}
      end)

    # Enrich events with cell names
    named_events =
      Enum.map(net_snapshot.events, fn event ->
        event
        |> maybe_add_cell_name(:cell_id, id_to_name)
      end)

    result = %{
      cells: named_cells,
      propagators: named_propagators,
      events: named_events,
      cell_name_to_id: cell_ids
    }

    {:reply, result, state}
  end

  def handle_call({:get_events, since}, _from, %{room: room} = state) do
    events = Network.get_events(room.net, since)
    {:reply, events, state}
  end

  def handle_call(:domain_meta, _from, state) do
    meta = %{
      domain: "Room",
      cell_specs: Room.cell_specs(),
      rule_specs: Room.rule_specs()
    }

    {:reply, meta, state}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp maybe_add_cell_name(event, key, id_to_name) do
    case Map.fetch(event, key) do
      {:ok, id} ->
        name = Map.get(id_to_name, id, :"cell_#{id}")
        Map.put(event, :cell_name, name)

      :error ->
        event
    end
  end
end
