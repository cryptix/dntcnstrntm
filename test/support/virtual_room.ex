defmodule HomeAgent.VirtualRoom do
  @moduledoc """
  Test helper: simulates a complete room sensor → presence-fusion → lighting
  pipeline without a live Home Assistant instance.

  ## Lifecycle

      room = VirtualRoom.new("vr_kitchen")          # allocates entities, starts PresenceFusion
      room = VirtualRoom.set_mmwave(room, true)      # inject sensor state into StateStore
      room = VirtualRoom.set_pir(room, true)
      room = VirtualRoom.trigger(room)               # fire state-changed, wait for presence event
      VirtualRoom.print(room)                        # ASCII visual summary

  ## Assertions

      {confidence, etype} = VirtualRoom.read_presence(room)
      assert confidence >= 80
      assert etype == :djuno

      assert VirtualRoom.last_command(room) == {:turn_on, kelvin, 255, 1}

  ## Design notes

  * Sensor entities are added to the room's Application config **only when
    `set_*/2` is called**.  This mirrors real rooms where you configure only
    the sensors physically present.  A sensor that was never `set_*` is
    truly absent from the Bayesian fusion (nil → prior stays unchanged),
    rather than reading as "off".

  * `trigger/1` broadcasts a synthetic `state_changed` PubSub message using
    the first registered sensor entity.  When no sensors have been
    registered yet it falls back to `PresenceFusion.read/1` (which returns
    the cached value from `init`, i.e. the prior = 50%).

  * The lighting command stored in the struct is computed locally from the
    presence event + `TimePeriod.circadian_now/0`, mirroring exactly the
    `cond` chain in `LightingController.apply_presence/5`.

  * Cleanup (remove Application env, stop PresenceFusion) is registered via
    `ExUnit.Callbacks.on_exit/1` and is resilient to the process already
    being dead.
  """

  alias HomeAgent.{PubSub, StateStore}
  alias HomeAgent.Propagator.{PresenceFusion, TimePeriod}

  @min_confidence Application.compile_env(:home_agent, :min_presence_confidence, 60)

  # ── Struct ──────────────────────────────────────────────────────────────────

  defstruct [
    :name,
    sensors: %{mmwave: nil, pir: nil, door: nil},
    last_presence: nil,
    commands: []
  ]

  @typedoc "A virtual room struct. Treat as opaque; mutate only via the provided functions."
  @type t :: %__MODULE__{}

  @typedoc "A computed lighting command."
  @type command ::
          {:turn_on, kelvin :: integer, brightness :: integer, transition :: integer}
          | {:turn_off, transition :: integer}
          | :timeout

  # ── Lifecycle ───────────────────────────────────────────────────────────────

  @doc """
  Allocate a virtual room named `name`.

  - Registers a minimal room config (light entity only, no sensor entities)
    in Application env.
  - Subscribes the calling process to `"presence:<name>"` PubSub events.
  - Starts a `PresenceFusion` GenServer for the room.
  - Drains the initial presence event emitted by `PresenceFusion.init/1`
    (all sensors nil → confidence 50%).
  - Registers an `on_exit` hook that removes the room config and stops the
    PresenceFusion process when the test exits.
  """
  @spec new(String.t()) :: t()
  def new(name) when is_binary(name) do
    # Start with only the light entity — no sensor entities yet.
    # Sensors are added to the config lazily by set_*/2, so PresenceFusion
    # treats unset sensors as truly absent (nil) rather than "off".
    base_config = %{light: "light.#{name}"}
    rooms = Application.get_env(:home_agent, :rooms, %{})
    Application.put_env(:home_agent, :rooms, Map.put(rooms, name, base_config))

    # Subscribe before starting PresenceFusion so we receive its init event.
    PubSub.subscribe(HomeAgent.PubSub, "presence:#{name}")

    {:ok, _pid} = PresenceFusion.start_link(name)

    # Drain the initial fuse event (all sensors nil → prior 0.5 → score 50).
    receive do
      {:presence_updated, ^name, _confidence, _etype} -> :ok
    after
      200 -> :ok
    end

    room = %__MODULE__{name: name}

    ExUnit.Callbacks.on_exit({__MODULE__, name}, fn -> cleanup(name) end)

    room
  end

  # ── Sensor injection ─────────────────────────────────────────────────────────

  @doc """
  Register an mmWave sensor and set its state to `true` (detected) or
  `false` (clear).

  First call registers `binary_sensor.<name>_mmwave` in the room config so
  PresenceFusion includes it in the Bayesian fusion.  Subsequent calls
  update only the StateStore entry.
  """
  @spec set_mmwave(t(), boolean()) :: t()
  def set_mmwave(%__MODULE__{} = room, value) when is_boolean(value) do
    entity_id = "binary_sensor.#{room.name}_mmwave"
    ensure_in_config(room.name, :mmwave, entity_id)
    inject_sensor(entity_id, value)
    %{room | sensors: Map.put(room.sensors, :mmwave, value)}
  end

  @doc """
  Register a PIR motion sensor and set its state to `true` (motion
  detected) or `false` (clear).
  """
  @spec set_pir(t(), boolean()) :: t()
  def set_pir(%__MODULE__{} = room, value) when is_boolean(value) do
    entity_id = "binary_sensor.#{room.name}_pir"
    ensure_in_config(room.name, :pir, entity_id)
    inject_sensor(entity_id, value)
    %{room | sensors: Map.put(room.sensors, :pir, value)}
  end

  @doc """
  Register a door contact sensor and set its state to `true` (open) or
  `false` (closed).

  Note: in PresenceFusion semantics, a *closed* door contributes positively
  to occupancy confidence.
  """
  @spec set_door(t(), boolean()) :: t()
  def set_door(%__MODULE__{} = room, value) when is_boolean(value) do
    entity_id = "binary_sensor.#{room.name}_door"
    ensure_in_config(room.name, :door, entity_id)
    inject_sensor(entity_id, value)
    %{room | sensors: Map.put(room.sensors, :door, value)}
  end

  # ── Trigger ──────────────────────────────────────────────────────────────────

  @doc """
  Trigger a presence re-fusion and capture the result.

  If at least one sensor entity has been registered (via `set_*/2`), fires
  a synthetic `state_changed` PubSub event and waits for PresenceFusion to
  publish back the updated presence.

  If no sensors have been registered, reads the cached PresenceFusion value
  directly (which equals the initial fuse result: prior = 50%).

  Returns an updated `VirtualRoom` with `last_presence` and `commands` set.
  """
  @spec trigger(t()) :: t()
  def trigger(%__MODULE__{} = room) do
    config = room_config(room.name)
    entity_id = config[:mmwave] || config[:pir] || config[:door]

    if entity_id do
      trigger_via_pubsub(room, entity_id)
    else
      # No sensors configured — read cached value from PresenceFusion init.
      {confidence, etype} = PresenceFusion.read(room.name)
      command = compute_command(confidence, etype)
      %{room | last_presence: {confidence, etype}, commands: room.commands ++ [command]}
    end
  end

  defp trigger_via_pubsub(room, entity_id) do
    PubSub.broadcast(HomeAgent.PubSub, "state_changed", {
      :state_changed,
      %{
        "entity_id" => entity_id,
        "new_state" => %{"state" => "on", "attributes" => %{}, "last_changed" => nil}
      }
    })

    receive do
      {:presence_updated, _room, confidence, etype} ->
        command = compute_command(confidence, etype)
        %{room | last_presence: {confidence, etype}, commands: room.commands ++ [command]}
    after
      300 ->
        %{room | last_presence: {0, :krici}, commands: room.commands ++ [:timeout]}
    end
  end

  # ── Accessors ────────────────────────────────────────────────────────────────

  @doc "Return `{confidence, epistemic_type}` from the last `trigger/1` call, or `nil`."
  @spec read_presence(t()) :: {integer(), :djuno | :jinvi | :krici} | nil
  def read_presence(%__MODULE__{last_presence: p}), do: p

  @doc "Return all computed lighting commands (one per `trigger/1` call)."
  @spec commands(t()) :: [command()]
  def commands(%__MODULE__{commands: cmds}), do: cmds

  @doc "Return the most recent computed lighting command, or `nil`."
  @spec last_command(t()) :: command() | nil
  def last_command(%__MODULE__{commands: []}), do: nil
  def last_command(%__MODULE__{commands: cmds}), do: List.last(cmds)

  # ── Visual output ────────────────────────────────────────────────────────────

  @doc """
  Print an ASCII-box summary of the room's current state to stdout.

  Returns the room struct unchanged so it can be piped.

      room |> VirtualRoom.trigger() |> VirtualRoom.print()
  """
  @spec print(t()) :: t()
  def print(%__MODULE__{} = room) do
    {confidence, etype} = room.last_presence || {nil, nil}
    command = last_command(room)

    w = 60

    IO.puts("")
    IO.puts(box_top(w))
    IO.puts(box_title("Virtual Room · #{room.name}", w))
    IO.puts(box_sep(w))
    IO.puts(box_row("Sensors", render_sensors(room.sensors), w))
    IO.puts(box_sep(w))
    IO.puts(box_row("Presence", render_presence(confidence, etype), w))
    IO.puts(box_sep(w))
    IO.puts(box_row("Lighting", render_command(command), w))
    IO.puts(box_bottom(w))
    IO.puts("")

    room
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp ensure_in_config(room_name, sensor_key, entity_id) do
    rooms = Application.get_env(:home_agent, :rooms, %{})
    config = Map.get(rooms, room_name, %{})

    unless config[sensor_key] == entity_id do
      Application.put_env(:home_agent, :rooms,
        Map.put(rooms, room_name, Map.put(config, sensor_key, entity_id)))
    end
  end

  defp room_config(name) do
    Application.get_env(:home_agent, :rooms, %{}) |> Map.get(name, %{})
  end

  defp inject_sensor(entity_id, true) do
    StateStore.put(%{
      "entity_id" => entity_id,
      "new_state" => %{"state" => "on", "attributes" => %{}, "last_changed" => nil}
    })
  end

  defp inject_sensor(entity_id, false) do
    StateStore.put(%{
      "entity_id" => entity_id,
      "new_state" => %{"state" => "off", "attributes" => %{}, "last_changed" => nil}
    })
  end

  # Mirror LightingController.apply_presence/5 exactly.
  defp compute_command(confidence, etype) do
    {kelvin, max_brightness} = TimePeriod.circadian_now()

    cond do
      confidence >= 80 and etype == :djuno ->
        {:turn_on, kelvin, max_brightness, 1}

      confidence >= @min_confidence ->
        {:turn_on, kelvin, round(max_brightness * 0.6), 1}

      confidence > 0 ->
        {:turn_on, kelvin, round(max_brightness * 0.3), 2}

      true ->
        {:turn_off, 3}
    end
  end

  defp cleanup(name) do
    rooms = Application.get_env(:home_agent, :rooms, %{})
    Application.put_env(:home_agent, :rooms, Map.delete(rooms, name))

    try do
      case Registry.lookup(HomeAgent.CellRegistry, {:presence_fusion, name}) do
        [{pid, _}] -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 500)
        [] -> :ok
      end
    catch
      :exit, _ -> :ok
    end
  end

  # ── ASCII box rendering ──────────────────────────────────────────────────────

  defp box_top(w), do: "╔" <> String.duplicate("═", w) <> "╗"
  defp box_bottom(w), do: "╚" <> String.duplicate("═", w) <> "╝"
  defp box_sep(w), do: "╠" <> String.duplicate("═", w) <> "╣"

  defp box_title(text, w) do
    content = "  " <> text
    "║" <> String.pad_trailing(content, w) <> "║"
  end

  defp box_row(label, value, w) do
    content = "  " <> String.pad_trailing(label, 10) <> "  " <> value
    "║" <> String.pad_trailing(content, w) <> "║"
  end

  defp render_sensors(%{mmwave: mw, pir: pir, door: door}) do
    [sensor_badge("mmWave", mw), sensor_badge("PIR", pir), sensor_badge("Door", door)]
    |> Enum.join("   ")
  end

  defp sensor_badge(label, nil), do: "#{label}: ─"
  defp sensor_badge(label, true), do: "#{label}: ●"
  defp sensor_badge(label, false), do: "#{label}: ○"

  defp render_presence(nil, _), do: "(not triggered)"

  defp render_presence(confidence, etype) do
    type_desc =
      case etype do
        :djuno -> "djuno · high-confidence knowledge"
        :jinvi -> "jinvi · evidence-based opinion"
        :krici -> "krici · low-confidence belief"
      end

    "#{confidence}%  #{type_desc}"
  end

  defp render_command(nil), do: "(not triggered)"
  defp render_command(:timeout), do: "TIMEOUT — no presence event received"

  defp render_command({:turn_on, kelvin, brightness, transition}) do
    "TURN ON   #{kelvin}K   brightness=#{brightness}   transition=#{transition}s"
  end

  defp render_command({:turn_off, transition}) do
    "TURN OFF   transition=#{transition}s"
  end
end
