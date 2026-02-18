defmodule HomeAgent.Datalog.Reconciler do
  @moduledoc """
  Subscribes to `"datalog_facts"` PubSub events (emitted by FactGenerator),
  invokes the RuleEngine, and feeds derived facts back into the system:

    - `should_light_on(room, kelvin, brightness)` → broadcasts
      `{:lighting_directive, room, kelvin, brightness}` on `"lighting"` topic
    - `room_inactive(room)` → broadcasts `{:lighting_directive, room, :off}` on `"lighting"`

  This is the slow-path "second opinion" described in the architecture:
  it can override the fast-path LightingController when complex rules fire.

  The Reconciler is intentionally stateless — it just translates Soufflé
  output events into PubSub messages. The LightingController decides
  whether to act.
  """

  use GenServer
  require Logger

  alias HomeAgent.Datalog.RuleEngine

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    HomeAgent.PubSub.subscribe(HomeAgent.PubSub, "datalog_facts")
    {:ok, nil}
  end

  @impl true
  def handle_info({:facts_ready, path}, state) do
    case RuleEngine.evaluate(path) do
      {:ok, results} ->
        File.rm(path)
        process_results(results)

      {:error, :souffle_not_found} ->
        Logger.info("Reconciler: Soufflé not available, skipping slow-path evaluation")

      {:error, reason} ->
        Logger.warning("Reconciler: rule evaluation failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp process_results(results) do
    emit_lighting_directives(results)
    emit_inactive_rooms(results)
  end

  # should_light_on(room, kelvin, brightness) → light directive
  defp emit_lighting_directives(results) do
    rows = Map.get(results, "should_light_on", [])

    Enum.each(rows, fn
      [room, kelvin_str, brightness_str] ->
        kelvin = parse_int(kelvin_str)
        brightness = parse_int(brightness_str)

        if kelvin && brightness do
          HomeAgent.PubSub.broadcast(
            HomeAgent.PubSub,
            "lighting",
            {:lighting_directive, room, kelvin, brightness}
          )
        end

      _ ->
        :ok
    end)
  end

  # room_inactive(room) → turn off directive
  defp emit_inactive_rooms(results) do
    rows = Map.get(results, "room_inactive", [])

    Enum.each(rows, fn
      [room] ->
        HomeAgent.PubSub.broadcast(
          HomeAgent.PubSub,
          "lighting",
          {:lighting_directive, room, :off}
        )

      _ ->
        :ok
    end)
  end

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end
end
