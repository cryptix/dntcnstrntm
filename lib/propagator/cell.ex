defmodule Propagator.Cell do
  @moduledoc """
  A Cell is a GenServer holding a lattice value plus a list of subscriber pids.

  When new content is added via `add_content/2`, the cell merges the new value
  with the existing one. If the result differs from the old value, all subscribers
  are notified with a `:propagate` message so they can re-run.
  """

  use GenServer

  # --- Public API ---

  @doc "Start a cell with the given lattice module. Value starts at lattice.bottom()."
  def new(lattice_mod) do
    GenServer.start_link(__MODULE__, lattice_mod)
  end

  @doc "Read the current value of the cell."
  def read(cell) do
    GenServer.call(cell, :read)
  end

  @doc "Merge new content into the cell. Notifies subscribers if the value changed."
  def add_content(cell, value) do
    GenServer.call(cell, {:add_content, value})
  end

  @doc "Subscribe a pid to be notified (via `:propagate`) when this cell's value changes."
  def subscribe(cell, pid) do
    GenServer.call(cell, {:subscribe, pid})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(lattice_mod) do
    {:ok, %{lattice: lattice_mod, value: lattice_mod.bottom(), subscribers: MapSet.new()}}
  end

  @impl true
  def handle_call(:read, _from, state) do
    {:reply, state.value, state}
  end

  def handle_call({:add_content, new_value}, _from, state) do
    merged = state.lattice.merge(state.value, new_value)

    if merged == state.value do
      {:reply, :ok, state}
    else
      new_state = %{state | value: merged}
      notify_subscribers(new_state.subscribers)
      {:reply, :ok, new_state}
    end
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  defp notify_subscribers(subscribers) do
    Enum.each(subscribers, fn pid -> send(pid, :propagate) end)
  end
end
