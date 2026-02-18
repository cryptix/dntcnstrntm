defmodule HomeAgent.Propagator.PresenceFusion do
  @moduledoc """
  Per-room GenServer that subscribes to PubSub state_changed events,
  fuses mmWave + PIR + door-state signals via Bayesian updating, and
  publishes a confidence score (0–100) plus epistemic type to PubSub
  topic `"presence:<room>"`.

  Epistemic categories (Winter's model):
    :djuno  — high-confidence knowledge  (score >= 80, mmWave active)
    :jinvi  — evidence-based opinion     (60 <= score < 80)
    :krici  — belief without direct obs  (score < 60, inferred from absence)

  The fusion result is also stored in the StateStore for the Datalog
  fact generator to pick up on its next cycle.
  """

  use GenServer
  require Logger

  alias HomeAgent.{RoomConfig, StateStore}

  # Sensor likelihood table:  {P(E|occupied), P(E|not_occupied)}
  @likelihoods %{
    mmwave: {0.95, 0.05},
    pir: {0.80, 0.20},
    door_closed: {0.70, 0.15}
  }

  # --- Child spec ---

  def child_spec(room) do
    %{
      id: {__MODULE__, room},
      start: {__MODULE__, :start_link, [room]},
      restart: :permanent,
      type: :worker
    }
  end

  def start_link(room) do
    GenServer.start_link(__MODULE__, room, name: via(room))
  end

  # --- Public API ---

  @doc "Read the latest fused confidence for a room. Returns `{score, epistemic_type}`."
  def read(room) do
    GenServer.call(via(room), :read)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(room) do
    HomeAgent.PubSub.subscribe(HomeAgent.PubSub, "state_changed")

    state = %{
      room: room,
      confidence: 0,
      epistemic_type: :krici,
      last_updated: System.system_time(:second)
    }

    # Run an initial fusion pass from whatever's already in the StateStore
    state = fuse(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:read, _from, state) do
    {:reply, {state.confidence, state.epistemic_type}, state}
  end

  @impl true
  def handle_info({:state_changed, data}, state) do
    entity_id = get_in(data, ["entity_id"]) || get_in(data, ["new_state", "entity_id"])

    # Only re-fuse if the changed entity belongs to this room
    case RoomConfig.entity_to_room(entity_id) do
      {room, _sensor_type} when room == state.room ->
        state = fuse(state)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Fusion logic ---

  defp fuse(state) do
    room = state.room
    prior = 0.5

    posterior =
      prior
      |> update(mmwave_value(room), :mmwave)
      |> update(pir_value(room), :pir)
      |> update(door_closed_value(room), :door_closed)

    score = round(posterior * 100)
    etype = epistemic_type(score, mmwave_value(room))

    new_state = %{
      state
      | confidence: score,
        epistemic_type: etype,
        last_updated: System.system_time(:second)
    }

    publish(new_state)
    new_state
  end

  # Bayesian update: P(H|E) = P(E|H)P(H) / [P(E|H)P(H) + P(E|¬H)P(¬H)]
  defp update(prior, nil, _sensor), do: prior

  defp update(prior, observed, sensor) do
    {p_true, p_false} = @likelihoods[sensor]

    {likelihood_given_H, likelihood_given_not_H} =
      if observed, do: {p_true, p_false}, else: {1 - p_true, 1 - p_false}

    numerator = likelihood_given_H * prior
    denominator = numerator + likelihood_given_not_H * (1 - prior)
    if denominator == 0, do: prior, else: numerator / denominator
  end

  defp mmwave_value(room) do
    case RoomConfig.mmwave_entity(room) do
      nil -> nil
      id -> StateStore.on?(id)
    end
  end

  defp pir_value(room) do
    case RoomConfig.pir_entity(room) do
      nil -> nil
      id -> StateStore.on?(id)
    end
  end

  # Door-closed contributes to occupancy confidence: closed door suggests someone is inside
  defp door_closed_value(room) do
    case RoomConfig.door_entity(room) do
      nil -> nil
      id -> not StateStore.on?(id)
    end
  end

  defp epistemic_type(score, mmwave_on) when score >= 80 and mmwave_on == true, do: :djuno
  defp epistemic_type(score, _) when score >= 60, do: :jinvi
  defp epistemic_type(_, _), do: :krici

  defp publish(state) do
    HomeAgent.PubSub.broadcast(
      HomeAgent.PubSub,
      "presence:#{state.room}",
      {:presence_updated, state.room, state.confidence, state.epistemic_type}
    )
  end

  defp via(room), do: {:via, Registry, {HomeAgent.CellRegistry, {:presence_fusion, room}}}
end
