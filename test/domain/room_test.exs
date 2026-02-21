defmodule Propagator.Domain.RoomTest do
  @moduledoc """
  Tests for the Room domain — the primary test case for the model-interrogation UI.

  Exercises the full ValueInterface: sensor assertions, rule-driven actuator
  propagation, belief retraction cascades, contradictions, and the comfort
  index computation.

  These tests mirror the kinds of interactive explorations you would do in
  the UI: set sensor values, watch actuators respond, retract, observe that
  derived beliefs vanish cleanly.
  """

  use ExUnit.Case, async: true

  alias Propagator.Domain.Room
  alias Propagator.Network

  @settle 50

  defp new_room do
    {:ok, room} = Room.new()
    room
  end

  # ── Sensors default to :nothing ────────────────────────────────────────────

  test "all cells start at :nothing" do
    room = new_room()

    for name <- [:temperature, :humidity, :occupancy, :co2,
                 :comfort_index, :cooling_on, :heating_on,
                 :ventilation_on, :lights_on] do
      assert Room.read(room, name) == :nothing, "expected :nothing for #{name}"
    end
  end

  # ── Cooling rule ────────────────────────────────────────────────────────────

  describe "cooling rule (temp > 76°F)" do
    test "temperature above 76°F turns cooling on" do
      room = new_room()
      Room.set(room, :temperature, 80, :sensor)
      Process.sleep(@settle)

      assert Room.read(room, :cooling_on) == true
      assert Room.read(room, :heating_on) == :nothing
    end

    test "temperature at exactly 76°F does not activate cooling" do
      room = new_room()
      Room.set(room, :temperature, 76, :sensor)
      Process.sleep(@settle)

      assert Room.read(room, :cooling_on) == :nothing
    end

    test "retracting hot sensor reading removes cooling belief" do
      room = new_room()
      Room.set(room, :temperature, 82, :sensor)
      Process.sleep(@settle)
      assert Room.read(room, :cooling_on) == true

      Room.retract(room, :temperature, :sensor)
      Process.sleep(@settle)

      assert Room.read(room, :temperature) == :nothing
      assert Room.read(room, :cooling_on) == :nothing
    end

    test "updating temperature below threshold removes cooling" do
      room = new_room()
      Room.set(room, :temperature, 80, :sensor_a)
      Process.sleep(@settle)
      assert Room.read(room, :cooling_on) == true

      Room.retract(room, :temperature, :sensor_a)
      Room.set(room, :temperature, 70, :sensor_b)
      Process.sleep(@settle)

      assert Room.read(room, :cooling_on) == :nothing
      assert Room.read(room, :heating_on) == :nothing
    end
  end

  # ── Heating rule ────────────────────────────────────────────────────────────

  describe "heating rule (temp < 68°F)" do
    test "temperature below 68°F turns heating on" do
      room = new_room()
      Room.set(room, :temperature, 60, :sensor)
      Process.sleep(@settle)

      assert Room.read(room, :heating_on) == true
      assert Room.read(room, :cooling_on) == :nothing
    end

    test "comfortable temperature: neither cooling nor heating" do
      room = new_room()
      Room.set(room, :temperature, 72, :sensor)
      Process.sleep(@settle)

      assert Room.read(room, :cooling_on) == :nothing
      assert Room.read(room, :heating_on) == :nothing
    end
  end

  # ── Ventilation rule ─────────────────────────────────────────────────────────

  describe "ventilation rule (CO₂ > 1000 ppm)" do
    test "high CO₂ activates ventilation" do
      room = new_room()
      Room.set(room, :co2, 1200, :sensor)
      Process.sleep(@settle)

      assert Room.read(room, :ventilation_on) == true
    end

    test "normal CO₂ does not activate ventilation" do
      room = new_room()
      Room.set(room, :co2, 800, :sensor)
      Process.sleep(@settle)

      assert Room.read(room, :ventilation_on) == :nothing
    end

    test "retracting CO₂ sensor removes ventilation belief" do
      room = new_room()
      Room.set(room, :co2, 1500, :sensor)
      Process.sleep(@settle)
      assert Room.read(room, :ventilation_on) == true

      Room.retract(room, :co2, :sensor)
      Process.sleep(@settle)

      assert Room.read(room, :ventilation_on) == :nothing
    end
  end

  # ── Lights rule ─────────────────────────────────────────────────────────────

  describe "lights rule (occupancy > 0)" do
    test "occupied room: lights on" do
      room = new_room()
      Room.set(room, :occupancy, 3, :sensor)
      Process.sleep(@settle)

      assert Room.read(room, :lights_on) == true
    end

    test "empty room: lights stay off" do
      room = new_room()
      Room.set(room, :occupancy, 0, :sensor)
      Process.sleep(@settle)

      assert Room.read(room, :lights_on) == :nothing
    end

    test "room empties: lights turn off" do
      room = new_room()
      Room.set(room, :occupancy, 5, :sensor_a)
      Process.sleep(@settle)
      assert Room.read(room, :lights_on) == true

      Room.retract(room, :occupancy, :sensor_a)
      Room.set(room, :occupancy, 0, :sensor_b)
      Process.sleep(@settle)

      assert Room.read(room, :lights_on) == :nothing
    end
  end

  # ── Comfort index ────────────────────────────────────────────────────────────

  describe "comfort index (function of temp and humidity)" do
    test "perfect conditions: 72°F, 50% → comfort 100" do
      room = new_room()
      Room.set(room, :temperature, 72, :sensor)
      Room.set(room, :humidity, 50, :sensor)
      Process.sleep(@settle)

      assert Room.read(room, :comfort_index) == 100.0
    end

    test "no temperature: comfort is :nothing" do
      room = new_room()
      Room.set(room, :humidity, 50, :sensor)
      Process.sleep(@settle)

      assert Room.read(room, :comfort_index) == :nothing
    end

    test "high temperature degrades comfort" do
      room = new_room()
      Room.set(room, :temperature, 85, :sensor)
      Room.set(room, :humidity, 50, :sensor)
      Process.sleep(@settle)

      # comfort = 100 - 1.5 * |85 - 72| = 100 - 19.5 = 80.5
      assert_in_delta Room.read(room, :comfort_index), 80.5, 0.1
    end

    test "retracting temperature collapses comfort index" do
      room = new_room()
      Room.set(room, :temperature, 72, :sensor)
      Room.set(room, :humidity, 50, :sensor)
      Process.sleep(@settle)
      assert Room.read(room, :comfort_index) == 100.0

      Room.retract(room, :temperature, :sensor)
      Process.sleep(@settle)

      assert Room.read(room, :comfort_index) == :nothing
    end
  end

  # ── ValueInterface API ────────────────────────────────────────────────────────

  describe "ValueInterface contract" do
    test "cell_specs covers all expected cells" do
      names = Room.cell_specs() |> Enum.map(& &1.name) |> MapSet.new()
      expected = MapSet.new([:temperature, :humidity, :occupancy, :co2,
                             :comfort_index, :cooling_on, :heating_on,
                             :ventilation_on, :lights_on])
      assert names == expected
    end

    test "rule_specs names match expected rules" do
      names = Room.rule_specs() |> Enum.map(& &1.name) |> MapSet.new()
      expected = MapSet.new([:ac_rule, :heat_rule, :ventilation_rule,
                             :lights_rule, :comfort_rule])
      assert names == expected
    end

    test "cell_ids maps all cell names to integer IDs" do
      {:ok, room} = Room.new()
      ids = Room.cell_ids(room)
      expected_names = MapSet.new([:temperature, :humidity, :occupancy, :co2,
                                   :comfort_index, :cooling_on, :heating_on,
                                   :ventilation_on, :lights_on])
      assert MapSet.new(Map.keys(ids)) == expected_names
      assert Enum.all?(ids, fn {_, v} -> is_integer(v) end)
    end

    test "network/1 returns the Network pid" do
      {:ok, room} = Room.new()
      pid = Room.network(room)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  # ── Network inspection ────────────────────────────────────────────────────────

  describe "Network.inspect_state/1" do
    test "snapshot includes all cells and propagators" do
      {:ok, room} = Room.new()
      snap = Network.inspect_state(room.net)

      assert map_size(snap.cells) == 9
      assert map_size(snap.propagators) == 5
    end

    test "event log captures belief additions" do
      {:ok, room} = Room.new()
      Room.set(room, :temperature, 80, :test_sensor)
      Process.sleep(@settle)

      snap = Network.inspect_state(room.net)
      events = Enum.filter(snap.events, &(&1.type == :belief_added))
      assert Enum.any?(events, fn e ->
        e.informant == :test_sensor and e.value == 80
      end)
    end

    test "event log captures cell changes after propagation" do
      {:ok, room} = Room.new()
      Room.set(room, :temperature, 80, :test_sensor)
      Process.sleep(@settle)

      snap = Network.inspect_state(room.net)
      changed = Enum.filter(snap.events, &(&1.type == :cell_changed))
      # At least temperature and cooling_on should have changed
      assert length(changed) >= 2
    end

    test "event log captures retractions" do
      {:ok, room} = Room.new()
      Room.set(room, :temperature, 80, :sensor_x)
      Process.sleep(@settle)
      Room.retract(room, :temperature, :sensor_x)
      Process.sleep(@settle)

      snap = Network.inspect_state(room.net)
      retractions = Enum.filter(snap.events, &(&1.type == :belief_retracted))
      assert Enum.any?(retractions, fn e -> e.informant == :sensor_x end)
    end
  end

  # ── Contradiction handling ──────────────────────────────────────────────────

  describe "contradiction from conflicting sensors" do
    test "two sensors with different temp readings → contradiction" do
      room = new_room()
      Room.set(room, :temperature, 80, :sensor_a)
      Room.set(room, :temperature, 60, :sensor_b)

      assert Room.read(room, :temperature) == :contradiction
    end

    test "removing one sensor resolves contradiction" do
      room = new_room()
      Room.set(room, :temperature, 80, :sensor_a)
      Room.set(room, :temperature, 60, :sensor_b)
      assert Room.read(room, :temperature) == :contradiction

      Room.retract(room, :temperature, :sensor_b)

      assert Room.read(room, :temperature) == 80
      assert Room.read(room, :cooling_on) == true
    end
  end

  # ── Multi-sensor room scenario ──────────────────────────────────────────────

  describe "full room scenario" do
    test "all sensors set: correct actuator states" do
      room = new_room()
      Room.set(room, :temperature, 78, :temp_sensor)
      Room.set(room, :humidity, 60, :humid_sensor)
      Room.set(room, :occupancy, 2, :occupancy_sensor)
      Room.set(room, :co2, 900, :co2_sensor)
      Process.sleep(@settle)

      # Temp 78°F > 76°F → cooling on
      assert Room.read(room, :cooling_on) == true
      # Heating off
      assert Room.read(room, :heating_on) == :nothing
      # CO₂ 900 < 1000 → no ventilation
      assert Room.read(room, :ventilation_on) == :nothing
      # Occupancy 2 > 0 → lights on
      assert Room.read(room, :lights_on) == true
      # Comfort: 100 - 1.5 * |78 - 72| - 0.5 * |60 - 50| = 100 - 9 - 5 = 86
      assert_in_delta Room.read(room, :comfort_index), 86.0, 0.1
    end

    test "night scenario: empty room, cool temperature" do
      room = new_room()
      Room.set(room, :temperature, 65, :temp_sensor)
      Room.set(room, :humidity, 45, :humid_sensor)
      Room.set(room, :occupancy, 0, :occupancy_sensor)
      Room.set(room, :co2, 400, :co2_sensor)
      Process.sleep(@settle)

      assert Room.read(room, :heating_on) == true
      assert Room.read(room, :cooling_on) == :nothing
      assert Room.read(room, :lights_on) == :nothing
      assert Room.read(room, :ventilation_on) == :nothing
    end
  end
end
