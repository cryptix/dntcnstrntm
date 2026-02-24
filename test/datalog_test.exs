defmodule Propagator.DatalogTest do
  @moduledoc """
  Tests for Datalog serialization and git-backed persistence.

  Exercises the round-trip: network state → Datalog files → git commits,
  plus introspection (log, diff, history, blame, branches).
  """

  use ExUnit.Case

  alias Propagator.Datalog
  alias Propagator.Datalog.GitStore
  alias Propagator.Domain.Room
  alias Propagator.Network

  @settle 50

  defp new_room do
    {:ok, room} = Room.new()
    room
  end

  defp tmp_path do
    name = "propagator_test_#{:erlang.unique_integer([:positive])}"
    Path.join(System.tmp_dir!(), name)
  end

  # ── Serialization ──────────────────────────────────────────────────────────

  describe "Datalog.serialize/2" do
    test "produces files for all cells, rules, and schema" do
      room = new_room()
      snap = Network.inspect_state(room.net)
      files = Datalog.serialize(room, snap)

      # Schema
      assert Map.has_key?(files, "schema.dl")

      # Cell files
      for spec <- Room.cell_specs() do
        assert Map.has_key?(files, "cells/#{spec.name}.dl"),
               "missing cell file for #{spec.name}"
      end

      # Rule files
      for spec <- Room.rule_specs() do
        assert Map.has_key?(files, "rules/#{spec.name}.dl"),
               "missing rule file for #{spec.name}"
      end
    end

    test "empty cells have no belief facts" do
      room = new_room()
      snap = Network.inspect_state(room.net)
      files = Datalog.serialize(room, snap)

      content = files["cells/temperature.dl"]
      assert content =~ "%% active_value: nothing"
      refute content =~ "belief("
    end

    test "cells with beliefs include belief facts" do
      room = new_room()
      Room.set(room, :temperature, 75, :sensor)
      Process.sleep(@settle)

      snap = Network.inspect_state(room.net)
      files = Datalog.serialize(room, snap)

      content = files["cells/temperature.dl"]
      assert content =~ "%% active_value: 75"
      assert content =~ "belief(75, sensor, in)."
    end

    test "derived beliefs appear in actuator cells" do
      room = new_room()
      Room.set(room, :temperature, 80, :sensor)
      Process.sleep(@settle)

      snap = Network.inspect_state(room.net)
      files = Datalog.serialize(room, snap)

      content = files["cells/cooling_on.dl"]
      assert content =~ "belief(true, ac_rule, in)."
    end

    test "retracted beliefs show as out" do
      room = new_room()
      Room.set(room, :temperature, 80, :sensor_a)
      Process.sleep(@settle)
      Room.retract(room, :temperature, :sensor_a)
      Room.set(room, :temperature, 70, :sensor_b)
      Process.sleep(@settle)

      snap = Network.inspect_state(room.net)
      files = Datalog.serialize(room, snap)

      content = files["cells/temperature.dl"]
      assert content =~ "belief(70, sensor_b, in)."
      assert content =~ "belief(80, sensor_a, out)."
    end

    test "schema file contains cell definitions" do
      room = new_room()
      snap = Network.inspect_state(room.net)
      files = Datalog.serialize(room, snap)

      schema = files["schema.dl"]
      assert schema =~ "cell(temperature, sensor,"
      assert schema =~ "cell(cooling_on, actuator,"
      assert schema =~ "cell(comfort_index, derived,"
    end

    test "rule files contain input/output facts" do
      room = new_room()
      snap = Network.inspect_state(room.net)
      files = Datalog.serialize(room, snap)

      ac_rule = files["rules/ac_rule.dl"]
      assert ac_rule =~ "input(temperature)."
      assert ac_rule =~ "output(cooling_on)."

      comfort = files["rules/comfort_rule.dl"]
      assert comfort =~ "input(temperature)."
      assert comfort =~ "input(humidity)."
      assert comfort =~ "output(comfort_index)."
    end
  end

  # ── Parsing round-trip ────────────────────────────────────────────────────

  describe "parse round-trip" do
    test "parse_cell recovers cell data" do
      room = new_room()
      Room.set(room, :temperature, 75, :sensor)
      Process.sleep(@settle)

      snap = Network.inspect_state(room.net)
      files = Datalog.serialize(room, snap)

      parsed = Datalog.parse_cell(files["cells/temperature.dl"])
      assert parsed.name == :temperature
      assert parsed.type == :sensor
      assert parsed.active_value == 75
      assert {75, :sensor, :in} in parsed.beliefs
    end

    test "parse_cell handles empty cells" do
      room = new_room()
      snap = Network.inspect_state(room.net)
      files = Datalog.serialize(room, snap)

      parsed = Datalog.parse_cell(files["cells/humidity.dl"])
      assert parsed.name == :humidity
      assert parsed.active_value == :nothing
      assert parsed.beliefs == []
    end

    test "parse_cell handles boolean values" do
      room = new_room()
      Room.set(room, :temperature, 80, :sensor)
      Process.sleep(@settle)

      snap = Network.inspect_state(room.net)
      files = Datalog.serialize(room, snap)

      parsed = Datalog.parse_cell(files["cells/cooling_on.dl"])
      assert parsed.name == :cooling_on
      assert parsed.active_value == true
      assert {true, :ac_rule, :in} in parsed.beliefs
    end

    test "parse_cell handles float values" do
      room = new_room()
      Room.set(room, :temperature, 72, :sensor)
      Room.set(room, :humidity, 50, :sensor)
      Process.sleep(@settle)

      snap = Network.inspect_state(room.net)
      files = Datalog.serialize(room, snap)

      parsed = Datalog.parse_cell(files["cells/comfort_index.dl"])
      assert parsed.name == :comfort_index
      assert_in_delta parsed.active_value, 100.0, 0.1
    end

    test "parse_rule recovers rule structure" do
      room = new_room()
      snap = Network.inspect_state(room.net)
      files = Datalog.serialize(room, snap)

      parsed = Datalog.parse_rule(files["rules/ac_rule.dl"])
      assert parsed.name == :ac_rule
      assert parsed.inputs == [:temperature]
      assert parsed.outputs == [:cooling_on]
    end

    test "parse_rule handles multi-input rules" do
      room = new_room()
      snap = Network.inspect_state(room.net)
      files = Datalog.serialize(room, snap)

      parsed = Datalog.parse_rule(files["rules/comfort_rule.dl"])
      assert parsed.name == :comfort_rule
      assert :temperature in parsed.inputs
      assert :humidity in parsed.inputs
      assert parsed.outputs == [:comfort_index]
    end

    test "parse_schema recovers cell specs" do
      room = new_room()
      snap = Network.inspect_state(room.net)
      files = Datalog.serialize(room, snap)

      specs = Datalog.parse_schema(files["schema.dl"])
      names = Enum.map(specs, & &1.name) |> MapSet.new()

      assert :temperature in names
      assert :cooling_on in names
      assert :comfort_index in names

      temp = Enum.find(specs, &(&1.name == :temperature))
      assert temp.type == :sensor
      assert temp.description == "Room temperature"
    end
  end

  # ── GitStore ──────────────────────────────────────────────────────────────

  describe "GitStore.init/1" do
    test "creates a git repository" do
      path = tmp_path()

      {:ok, _store} = GitStore.init(path)

      assert File.dir?(Path.join(path, ".git"))

      # Clean up
      File.rm_rf!(path)
    end
  end

  describe "GitStore.snapshot/3" do
    test "commits network state as Datalog files" do
      path = tmp_path()
      {:ok, store} = GitStore.init(path)
      room = new_room()

      Room.set(room, :temperature, 75, :sensor)
      Process.sleep(@settle)

      {:ok, sha} = GitStore.snapshot(store, room, "Sensor: temperature 75°F")

      assert is_binary(sha)
      assert String.length(sha) > 0

      # Verify files exist
      assert File.exists?(Path.join(path, "cells/temperature.dl"))
      assert File.exists?(Path.join(path, "rules/ac_rule.dl"))
      assert File.exists?(Path.join(path, "schema.dl"))

      # Verify content
      {:ok, content} = File.read(Path.join(path, "cells/temperature.dl"))
      assert content =~ "belief(75, sensor, in)."

      File.rm_rf!(path)
    end

    test "successive snapshots create separate commits" do
      path = tmp_path()
      {:ok, store} = GitStore.init(path)
      room = new_room()

      Room.set(room, :temperature, 75, :sensor)
      Process.sleep(@settle)
      {:ok, sha1} = GitStore.snapshot(store, room, "Temperature: 75°F")

      Room.retract(room, :temperature, :sensor)
      Room.set(room, :temperature, 82, :sensor_b)
      Process.sleep(@settle)
      {:ok, sha2} = GitStore.snapshot(store, room, "Temperature: 82°F")

      assert sha1 != sha2

      {:ok, log} = GitStore.log(store)
      assert log =~ "Temperature: 82"
      assert log =~ "Temperature: 75"

      File.rm_rf!(path)
    end
  end

  describe "GitStore.diff/2" do
    test "shows what changed between snapshots" do
      path = tmp_path()
      {:ok, store} = GitStore.init(path)
      room = new_room()

      Room.set(room, :temperature, 75, :sensor)
      Process.sleep(@settle)
      {:ok, _} = GitStore.snapshot(store, room, "Temperature: 75°F")

      Room.retract(room, :temperature, :sensor)
      Room.set(room, :temperature, 82, :sensor_b)
      Process.sleep(@settle)
      {:ok, _} = GitStore.snapshot(store, room, "Temperature: 82°F")

      {:ok, diff} = GitStore.diff(store, "HEAD~1")

      # The diff should show changes in the temperature cell
      assert diff =~ "temperature"

      File.rm_rf!(path)
    end
  end

  describe "GitStore.history/2" do
    test "shows per-file history" do
      path = tmp_path()
      {:ok, store} = GitStore.init(path)
      room = new_room()

      Room.set(room, :temperature, 75, :sensor)
      Process.sleep(@settle)
      {:ok, _} = GitStore.snapshot(store, room, "Temperature: 75°F")

      Room.retract(room, :temperature, :sensor)
      Room.set(room, :temperature, 82, :sensor_b)
      Process.sleep(@settle)
      {:ok, _} = GitStore.snapshot(store, room, "Temperature: 82°F")

      {:ok, history} = GitStore.history(store, "cells/temperature.dl")

      assert history =~ "Temperature: 82"
      assert history =~ "Temperature: 75"

      File.rm_rf!(path)
    end
  end

  describe "GitStore.blame/2" do
    test "shows line-by-line attribution" do
      path = tmp_path()
      {:ok, store} = GitStore.init(path)
      room = new_room()

      Room.set(room, :temperature, 75, :sensor)
      Process.sleep(@settle)
      {:ok, _} = GitStore.snapshot(store, room, "Temperature: 75°F")

      {:ok, blame} = GitStore.blame(store, "cells/temperature.dl")

      assert blame =~ "belief(75, sensor, in)."

      File.rm_rf!(path)
    end
  end

  describe "GitStore.branch/2 and checkout/2" do
    test "what-if reasoning via branches" do
      path = tmp_path()
      {:ok, store} = GitStore.init(path)
      room = new_room()

      # Baseline state
      Room.set(room, :temperature, 72, :sensor)
      Room.set(room, :humidity, 50, :sensor)
      Process.sleep(@settle)
      {:ok, _} = GitStore.snapshot(store, room, "Baseline: comfortable")

      # Branch for "what if it gets hot"
      :ok = GitStore.branch(store, "what-if-hot")

      Room.retract(room, :temperature, :sensor)
      Room.set(room, :temperature, 90, :hot_sensor)
      Process.sleep(@settle)
      {:ok, _} = GitStore.snapshot(store, room, "What if: 90°F")

      # Verify the hot branch has cooling on
      {:ok, hot_cell} = GitStore.read_cell(store, :temperature)
      assert hot_cell.active_value == 90

      {:ok, cooling} = GitStore.read_cell(store, :cooling_on)
      assert {true, :ac_rule, :in} in cooling.beliefs

      # Switch back to main and verify baseline is preserved
      :ok = GitStore.checkout(store, "main")

      {:ok, main_cell} = GitStore.read_cell(store, :temperature)
      assert main_cell.active_value == 72

      # Diff between branches
      {:ok, diff} = GitStore.diff_refs(store, "main", "what-if-hot")
      assert diff =~ "temperature"

      # List branches
      {:ok, branches} = GitStore.branches(store)
      branch_names = Enum.map(branches, &elem(&1, 0))
      assert "main" in branch_names
      assert "what-if-hot" in branch_names

      File.rm_rf!(path)
    end
  end

  describe "GitStore.tag/2" do
    test "tags name important states" do
      path = tmp_path()
      {:ok, store} = GitStore.init(path)
      room = new_room()

      Room.set(room, :temperature, 72, :sensor)
      Room.set(room, :humidity, 50, :sensor)
      Process.sleep(@settle)
      {:ok, _} = GitStore.snapshot(store, room, "Comfortable state")

      :ok = GitStore.tag(store, "comfortable-baseline", "Known good state")

      {:ok, tags} = GitStore.tags(store)
      assert tags =~ "comfortable-baseline"

      File.rm_rf!(path)
    end
  end

  describe "GitStore.read_cell_at/3" do
    test "reads historical cell state" do
      path = tmp_path()
      {:ok, store} = GitStore.init(path)
      room = new_room()

      Room.set(room, :temperature, 75, :sensor)
      Process.sleep(@settle)
      {:ok, sha1} = GitStore.snapshot(store, room, "Temperature: 75°F")

      Room.retract(room, :temperature, :sensor)
      Room.set(room, :temperature, 82, :sensor_b)
      Process.sleep(@settle)
      {:ok, _sha2} = GitStore.snapshot(store, room, "Temperature: 82°F")

      # Read the old state
      {:ok, old_cell} = GitStore.read_cell_at(store, :temperature, sha1)
      assert old_cell.active_value == 75

      # Read the current state
      {:ok, current_cell} = GitStore.read_cell(store, :temperature)
      assert current_cell.active_value == 82

      File.rm_rf!(path)
    end
  end

  describe "GitStore.log_entries/1" do
    test "returns structured log entries" do
      path = tmp_path()
      {:ok, store} = GitStore.init(path)
      room = new_room()

      Room.set(room, :temperature, 75, :sensor)
      Process.sleep(@settle)
      {:ok, _} = GitStore.snapshot(store, room, "Temperature: 75°F")

      {:ok, entries} = GitStore.log_entries(store)

      assert length(entries) >= 2
      entry = List.first(entries)
      assert entry.message == "Temperature: 75°F"
      assert is_binary(entry.sha)
      assert is_binary(entry.timestamp)

      File.rm_rf!(path)
    end
  end

  # ── Full scenario ──────────────────────────────────────────────────────────

  describe "full room scenario with git history" do
    test "day-in-a-room recorded in git" do
      path = tmp_path()
      {:ok, store} = GitStore.init(path)
      room = new_room()

      # Morning: cool, occupied
      Room.set(room, :temperature, 65, :morning_sensor)
      Room.set(room, :humidity, 55, :morning_sensor)
      Room.set(room, :occupancy, 1, :badge_reader)
      Room.set(room, :co2, 450, :air_sensor)
      Process.sleep(@settle)
      {:ok, _} = GitStore.snapshot(store, room, "Morning: cool, one occupant")

      # Midday: warms up, more people
      Room.retract(room, :temperature, :morning_sensor)
      Room.retract(room, :humidity, :morning_sensor)
      Room.retract(room, :occupancy, :badge_reader)
      Room.retract(room, :co2, :air_sensor)
      Room.set(room, :temperature, 78, :midday_sensor)
      Room.set(room, :humidity, 45, :midday_sensor)
      Room.set(room, :occupancy, 5, :badge_reader_v2)
      Room.set(room, :co2, 1100, :air_sensor_v2)
      Process.sleep(@settle)
      {:ok, _} = GitStore.snapshot(store, room, "Midday: warm, crowded, high CO2")

      # Evening: empties out
      Room.retract(room, :temperature, :midday_sensor)
      Room.retract(room, :humidity, :midday_sensor)
      Room.retract(room, :occupancy, :badge_reader_v2)
      Room.retract(room, :co2, :air_sensor_v2)
      Room.set(room, :temperature, 70, :evening_sensor)
      Room.set(room, :humidity, 50, :evening_sensor)
      Room.set(room, :occupancy, 0, :badge_reader_v3)
      Room.set(room, :co2, 500, :air_sensor_v3)
      Process.sleep(@settle)
      {:ok, _} = GitStore.snapshot(store, room, "Evening: comfortable, empty")

      # Verify log tells the story
      {:ok, log} = GitStore.log(store)
      assert log =~ "Evening"
      assert log =~ "Midday"
      assert log =~ "Morning"

      # Verify temperature history
      {:ok, temp_history} = GitStore.history(store, "cells/temperature.dl")
      assert temp_history =~ "70"
      assert temp_history =~ "78"
      assert temp_history =~ "65"

      # Verify final state
      {:ok, temp} = GitStore.read_cell(store, :temperature)
      assert temp.active_value == 70

      {:ok, cooling} = GitStore.read_cell(store, :cooling_on)
      assert cooling.active_value == :nothing

      {:ok, lights} = GitStore.read_cell(store, :lights_on)
      assert lights.active_value == :nothing

      File.rm_rf!(path)
    end
  end
end
