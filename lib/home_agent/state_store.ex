defmodule HomeAgent.StateStore do
  @moduledoc """
  ETS-backed cache of the latest Home Assistant entity states.

  Each entry is stored as `{entity_id, state_string, attributes_map, last_changed_unix}`.

  This is intentionally a simple last-write-wins cache. The propagator
  network (PresenceFusion) handles the richer temporal reasoning.
  """

  use GenServer

  @table :ha_state_store

  # --- Public API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Store or update the state for an entity from a raw state_changed data map."
  def put(%{"entity_id" => entity_id, "new_state" => new_state}) when is_map(new_state) do
    state_str = new_state["state"]
    attrs = new_state["attributes"] || %{}
    ts = parse_timestamp(new_state["last_changed"])
    :ets.insert(@table, {entity_id, state_str, attrs, ts})
    :ok
  end

  def put(_), do: :ok

  @doc "Return `{state_string, attributes, timestamp}` for an entity, or `:not_found`."
  def get(entity_id) do
    case :ets.lookup(@table, entity_id) do
      [{^entity_id, state, attrs, ts}] -> {state, attrs, ts}
      [] -> :not_found
    end
  end

  @doc "Return the raw state string (\"on\", \"off\", \"unavailable\", …) or `nil`."
  def state(entity_id) do
    case get(entity_id) do
      {s, _attrs, _ts} -> s
      :not_found -> nil
    end
  end

  @doc "Return true when the entity state is the truthy HA value."
  def on?(entity_id), do: state(entity_id) in ["on", "home", "detected", "True", "true"]

  @doc "Return all stored entity IDs."
  def all_ids do
    :ets.select(@table, [{{:"$1", :_, :_, :_}, [], [:"$1"]}])
  end

  # --- GenServer callbacks ---

  @impl true
  def init([]) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  defp parse_timestamp(nil), do: System.system_time(:second)

  defp parse_timestamp(iso_str) do
    case DateTime.from_iso8601(iso_str) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt)
      _ -> System.system_time(:second)
    end
  end
end
