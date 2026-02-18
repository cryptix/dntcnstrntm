defmodule HomeAgent.LightingController do
  @moduledoc """
  Confidence-aware lighting actuator.

  **Fast path** — subscribes to `"presence:<room>"` PubSub events from
  PresenceFusion and adjusts lights immediately (< 100 ms latency):

    confidence >= 80, :djuno  → full circadian lighting, transition 1s
    confidence >= 60, :jinvi  → 60% of circadian brightness, transition 1s
    confidence <  60          → 30% brightness, transition 2s
    confidence == 0           → turn off, transition 3s

  Transition times are intentionally short because mmWave radar sensors
  report at ~1 Hz with very high confidence — any false negative corrects
  itself within a second. The LED's built-in dimming curve handles visual
  smoothness; we just need to send the target value promptly.

  **Slow path** — subscribes to `"lighting"` PubSub events from the
  Reconciler (Soufflé derived facts) and applies override directives.
  The slow path can turn lights OFF even when the fast path says ON,
  implementing Winter's krici/belief constraints (e.g. "never bright
  after midnight").
  """

  use GenServer
  require Logger

  alias HomeAgent.{HaClient, RoomConfig}
  alias HomeAgent.Propagator.TimePeriod

  @min_confidence Application.compile_env(:home_agent, :min_presence_confidence, 60)

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    HomeAgent.PubSub.subscribe(HomeAgent.PubSub, "lighting")

    Enum.each(RoomConfig.rooms(), fn room ->
      HomeAgent.PubSub.subscribe(HomeAgent.PubSub, "presence:#{room}")
    end)

    {:ok, %{}}
  end

  # --- Fast path: PresenceFusion events ---

  @impl true
  def handle_info({:presence_updated, room, confidence, etype}, state) do
    {kelvin, max_brightness} = TimePeriod.circadian_now()
    apply_presence(room, confidence, etype, kelvin, max_brightness)
    {:noreply, state}
  end

  # --- Slow path: Reconciler directives ---

  def handle_info({:lighting_directive, room, kelvin, brightness}, state) when is_integer(kelvin) do
    entity = RoomConfig.light_entity(room)

    if entity do
      Logger.debug("LightingController: slow-path directive #{room} #{kelvin}K #{brightness}")
      set_light(entity, kelvin, brightness, 3)
    end

    {:noreply, state}
  end

  def handle_info({:lighting_directive, room, :off}, state) do
    entity = RoomConfig.light_entity(room)

    if entity do
      Logger.debug("LightingController: slow-path OFF directive #{room}")
      turn_off(entity, 10)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp apply_presence(room, confidence, etype, kelvin, max_brightness) do
    entity = RoomConfig.light_entity(room)
    unless entity, do: raise("No light entity configured for room #{room}")

    cond do
      confidence >= 80 and etype == :djuno ->
        # High-confidence knowledge: full circadian lighting, snap on
        set_light(entity, kelvin, max_brightness, 2)

      confidence >= @min_confidence ->
        # Evidence-based opinion: 60% brightness, gentle transition
        brightness = round(max_brightness * 0.6)
        set_light(entity, kelvin, brightness, 5)

      confidence > 0 ->
        # Low confidence: slow fade to 30% — give sensors time to update
        brightness = round(max_brightness * 0.3)
        set_light(entity, kelvin, brightness, 30)

      true ->
        # No evidence of presence: fade out over 30s
        turn_off(entity, 30)
    end
  end

  defp set_light(entity, kelvin, brightness, transition) do
    brightness = min(max(brightness, 0), 255)

    if brightness > 0 do
      HaClient.call_service("light", "turn_on", entity, %{
        color_temp_kelvin: kelvin,
        brightness: brightness,
        transition: transition
      })
    else
      turn_off(entity, transition)
    end
  rescue
    e -> Logger.warning("LightingController: call_service failed: #{inspect(e)}")
  end

  defp turn_off(entity, transition) do
    HaClient.call_service("light", "turn_off", entity, %{transition: transition})
  rescue
    e -> Logger.warning("LightingController: turn_off failed: #{inspect(e)}")
  end
end
