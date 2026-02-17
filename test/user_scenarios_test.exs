defmodule Propagator.UserScenariosTest do
  @moduledoc """
  Phase 5: End-to-end user scenarios exercising the full propagator stack.

  These tests tell the story of a GardenBot — a belief-tracking agent that
  manages garden watering. It perceives sensor data, computes watering needs
  through propagation networks, tracks beliefs via JTMS, handles contradictions
  from faulty sensors, and allocates scarce water via constraint solving.

  The bot stays composed under stress: unexpected weather, sensor failures,
  and competing demands don't cause it to overwater or panic.

  Exercises all four phases:
    Phase 1 — Cells & propagators (bidirectional arithmetic)
    Phase 2 — JTMS (non-monotonic default reasoning, belief revision)
    Phase 3 — Network with BeliefCells (retraction cascades, contradiction)
    Phase 4 — Constraint solver (resource allocation under pressure)
  """

  use ExUnit.Case, async: true

  alias Propagator.Network
  alias Propagator.Network.Arithmetic
  alias Propagator.JTMS
  alias Propagator.Lattice.Set
  alias Propagator.Solver.AC3

  @settle 50

  # ── Helper: build a watering-need computation network ─────────────────
  #
  #   current_moisture + deficit = target_moisture
  #                                (deficit = target - current)
  #   deficit * liters_per_point = water_needed
  #
  defp build_watering_network do
    {:ok, net} = Network.new()

    current_moisture = Network.create_cell(net)
    target_moisture = Network.create_cell(net)
    deficit = Network.create_cell(net)
    liters_per_point = Network.create_cell(net)
    water_needed = Network.create_cell(net)

    # current + deficit = target  →  deficit = target - current
    Arithmetic.adder(net, current_moisture, deficit, target_moisture)
    # deficit * liters_per_point = water_needed
    Arithmetic.multiplier(net, deficit, liters_per_point, water_needed)
    Process.sleep(@settle)

    %{
      net: net,
      current_moisture: current_moisture,
      target_moisture: target_moisture,
      deficit: deficit,
      liters_per_point: liters_per_point,
      water_needed: water_needed
    }
  end

  # ── Helper: build an evaporation-chain network ────────────────────────
  #
  #   temperature * evap_coefficient = evaporation
  #   evaporation + drainage = total_loss
  #
  defp build_evaporation_chain do
    {:ok, net} = Network.new()

    temperature = Network.create_cell(net)
    evap_coeff = Network.create_cell(net)
    evaporation = Network.create_cell(net)
    drainage = Network.create_cell(net)
    total_loss = Network.create_cell(net)

    Arithmetic.multiplier(net, temperature, evap_coeff, evaporation)
    Arithmetic.adder(net, evaporation, drainage, total_loss)
    Process.sleep(@settle)

    Arithmetic.constant(net, evap_coeff, 0.1, :evap_calibration)
    Arithmetic.constant(net, drainage, 2.0, :drainage_rate)
    Process.sleep(@settle)

    %{
      net: net,
      temperature: temperature,
      evaporation: evaporation,
      total_loss: total_loss
    }
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Scenario 1 — Basic watering computation
  # The bot reads sensors and computes how much water is needed.
  # ═══════════════════════════════════════════════════════════════════════

  describe "GardenBot computes watering needs from sensors" do
    test "derives water needed from moisture deficit and conversion factor" do
      w = build_watering_network()

      # Soil sensor reads 40% moisture
      Network.add_content(w.net, w.current_moisture, 40, :soil_sensor)
      # We want 70% moisture
      Arithmetic.constant(w.net, w.target_moisture, 70, :target_config)
      # Each percentage point of deficit needs 0.5 liters
      Arithmetic.constant(w.net, w.liters_per_point, 0.5, :calibration)
      Process.sleep(@settle)

      # deficit = 70 - 40 = 30
      assert_in_delta Network.read_cell(w.net, w.deficit), 30.0, 0.01
      # water_needed = 30 * 0.5 = 15 liters
      assert_in_delta Network.read_cell(w.net, w.water_needed), 15.0, 0.01
    end

    test "wetter soil means less water needed" do
      w = build_watering_network()

      Arithmetic.constant(w.net, w.target_moisture, 70, :target_config)
      Arithmetic.constant(w.net, w.liters_per_point, 0.5, :calibration)
      Process.sleep(@settle)

      # First reading: dry soil at 30%
      Network.add_content(w.net, w.current_moisture, 30, :sensor_morning)
      Process.sleep(@settle)
      assert_in_delta Network.read_cell(w.net, w.water_needed), 20.0, 0.01

      # Retract morning reading, afternoon sensor shows soil recovered to 55%
      Network.retract_content(w.net, w.current_moisture, :sensor_morning)
      Network.add_content(w.net, w.current_moisture, 55, :sensor_afternoon)
      Process.sleep(@settle)

      # deficit = 70 - 55 = 15, water = 15 * 0.5 = 7.5
      assert_in_delta Network.read_cell(w.net, w.water_needed), 7.5, 0.01
    end

    test "backward inference: water applied reveals what moisture was" do
      w = build_watering_network()

      Arithmetic.constant(w.net, w.target_moisture, 70, :target_config)
      Arithmetic.constant(w.net, w.liters_per_point, 0.5, :calibration)
      Process.sleep(@settle)

      # We know we applied 10 liters — what was the moisture?
      # water_needed = 10 → deficit = 10/0.5 = 20 → current = 70-20 = 50
      Network.add_content(w.net, w.water_needed, 10, :flow_meter)
      Process.sleep(@settle)

      assert_in_delta Network.read_cell(w.net, w.deficit), 20.0, 0.01
      assert_in_delta Network.read_cell(w.net, w.current_moisture), 50.0, 0.01
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Scenario 2 — Weather forecast changes mid-plan
  # The bot adjusts its watering plan when forecasts shift.
  # ═══════════════════════════════════════════════════════════════════════

  describe "GardenBot reacts to weather forecast changes" do
    test "rain forecast eliminates watering need" do
      w = build_watering_network()

      Arithmetic.constant(w.net, w.target_moisture, 70, :target_config)
      Arithmetic.constant(w.net, w.liters_per_point, 0.5, :calibration)
      Network.add_content(w.net, w.current_moisture, 40, :soil_sensor)
      Process.sleep(@settle)

      # Bot computed: need 15 liters
      assert_in_delta Network.read_cell(w.net, w.water_needed), 15.0, 0.01

      # Rain forecast: soil will reach target on its own
      Network.retract_content(w.net, w.current_moisture, :soil_sensor)
      Network.add_content(w.net, w.current_moisture, 70, :rain_forecast)
      Process.sleep(@settle)

      # deficit = 0, water_needed = 0
      assert_in_delta Network.read_cell(w.net, w.deficit), 0.0, 0.01
      assert_in_delta Network.read_cell(w.net, w.water_needed), 0.0, 0.01
    end

    test "forecast flip-flop: sun → rain → sun tracks correctly" do
      w = build_watering_network()

      Arithmetic.constant(w.net, w.target_moisture, 70, :target_config)
      Arithmetic.constant(w.net, w.liters_per_point, 0.5, :calibration)
      Process.sleep(@settle)

      # Sunny morning: soil is dry
      Network.add_content(w.net, w.current_moisture, 40, :sensor_sunny)
      Process.sleep(@settle)
      assert_in_delta Network.read_cell(w.net, w.water_needed), 15.0, 0.01

      # Forecast changes to rain
      Network.retract_content(w.net, w.current_moisture, :sensor_sunny)
      Network.add_content(w.net, w.current_moisture, 70, :forecast_rain)
      Process.sleep(@settle)
      assert_in_delta Network.read_cell(w.net, w.water_needed), 0.0, 0.01

      # Forecast reverts to sun — rain won't come after all
      Network.retract_content(w.net, w.current_moisture, :forecast_rain)
      Network.add_content(w.net, w.current_moisture, 40, :sensor_revised)
      Process.sleep(@settle)
      assert_in_delta Network.read_cell(w.net, w.water_needed), 15.0, 0.01
    end

    test "retracted forecast leaves no stale beliefs" do
      w = build_watering_network()

      Arithmetic.constant(w.net, w.target_moisture, 70, :target_config)
      Arithmetic.constant(w.net, w.liters_per_point, 0.5, :calibration)
      Process.sleep(@settle)

      # Add and retract a rain forecast
      Network.add_content(w.net, w.current_moisture, 70, :rain_forecast)
      Process.sleep(@settle)
      assert_in_delta Network.read_cell(w.net, w.water_needed), 0.0, 0.01

      Network.retract_content(w.net, w.current_moisture, :rain_forecast)
      Process.sleep(@settle)

      # Everything derived from that forecast is gone
      assert Network.read_cell(w.net, w.current_moisture) == :nothing
      assert Network.read_cell(w.net, w.deficit) == :nothing
      assert Network.read_cell(w.net, w.water_needed) == :nothing
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Scenario 3 — Sensor disagreement and recovery
  # Two sensors disagree — the bot detects contradiction and recovers
  # when the faulty sensor is removed. No guessing, no panic.
  # ═══════════════════════════════════════════════════════════════════════

  describe "GardenBot handles conflicting sensors without panic" do
    test "two sensors disagree → contradiction, not a wild guess" do
      {:ok, net} = Network.new()
      moisture = Network.create_cell(net)

      Network.add_content(net, moisture, 40, :sensor_east)
      Network.add_content(net, moisture, 65, :sensor_west)

      # System recognizes contradiction — doesn't average, doesn't pick one
      assert Network.read_cell(net, moisture) == :contradiction
    end

    test "removing faulty sensor resolves contradiction and restores computation" do
      w = build_watering_network()

      Arithmetic.constant(w.net, w.target_moisture, 70, :target_config)
      Arithmetic.constant(w.net, w.liters_per_point, 0.5, :calibration)
      Process.sleep(@settle)

      # Two sensors disagree
      Network.add_content(w.net, w.current_moisture, 40, :sensor_a)
      Network.add_content(w.net, w.current_moisture, 65, :sensor_b)
      Process.sleep(@settle)

      assert Network.read_cell(w.net, w.current_moisture) == :contradiction

      # Diagnose: sensor_b had a loose wire. Retract it.
      Network.retract_content(w.net, w.current_moisture, :sensor_b)
      Process.sleep(@settle)

      # System recovers cleanly
      assert Network.read_cell(w.net, w.current_moisture) == 40
      assert_in_delta Network.read_cell(w.net, w.water_needed), 15.0, 0.01
    end

    test "three sensors — two agree, one outlier — contradiction until outlier removed" do
      {:ok, net} = Network.new()
      moisture = Network.create_cell(net)

      # Two say 40, one says 90 (clearly broken)
      Network.add_content(net, moisture, 40, :sensor_1)
      Network.add_content(net, moisture, 40, :sensor_2)
      Network.add_content(net, moisture, 90, :sensor_3)

      # Contradiction — the system doesn't do majority voting
      assert Network.read_cell(net, moisture) == :contradiction

      # Remove the outlier
      Network.retract_content(net, moisture, :sensor_3)
      assert Network.read_cell(net, moisture) == 40
    end

    test "replacing a sensor: retract old, add new, no stale data" do
      w = build_watering_network()

      Arithmetic.constant(w.net, w.target_moisture, 70, :target_config)
      Arithmetic.constant(w.net, w.liters_per_point, 0.5, :calibration)
      Process.sleep(@settle)

      # Original sensor
      Network.add_content(w.net, w.current_moisture, 50, :old_sensor)
      Process.sleep(@settle)
      assert_in_delta Network.read_cell(w.net, w.water_needed), 10.0, 0.01

      # Replace with new sensor (different reading)
      Network.retract_content(w.net, w.current_moisture, :old_sensor)
      Network.add_content(w.net, w.current_moisture, 60, :new_sensor)
      Process.sleep(@settle)

      # Computation reflects only the new sensor
      assert_in_delta Network.read_cell(w.net, w.water_needed), 5.0, 0.01
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Scenario 4 — Overwatering prevention via constraint solving
  # Limited water budget. The bot allocates across zones without
  # over-committing or silently under-watering critical zones.
  # ═══════════════════════════════════════════════════════════════════════

  describe "GardenBot prevents overwatering with constraint solving" do
    test "allocates water across zones within a limited budget" do
      # Three zones, 20-liter daily budget
      variables = %{
        vegetables: Set.new([0, 2, 4, 6, 8, 10, 12]),
        flowers: Set.new([0, 2, 4, 6, 8]),
        lawn: Set.new([0, 2, 4, 6])
      }

      budget =
        {[:vegetables, :flowers, :lawn],
         fn a ->
           if map_size(a) == 3, do: a.vegetables + a.flowers + a.lawn <= 20, else: true
         end}

      # Vegetables need at least 6 liters
      veg_min =
        {[:vegetables],
         fn a -> if Map.has_key?(a, :vegetables), do: a.vegetables >= 6, else: true end}

      # Flowers need at least 4 liters
      flower_min =
        {[:flowers],
         fn a -> if Map.has_key?(a, :flowers), do: a.flowers >= 4, else: true end}

      assert {:ok, solution} = AC3.solve(variables, [budget, veg_min, flower_min])

      assert solution.vegetables >= 6
      assert solution.flowers >= 4
      assert solution.vegetables + solution.flowers + solution.lawn <= 20
    end

    test "impossible demands detected, not papered over" do
      # Each zone needs 10 liters minimum, but only 20 total
      variables = %{
        zone_a: Set.new([0, 5, 10, 15]),
        zone_b: Set.new([0, 5, 10, 15]),
        zone_c: Set.new([0, 5, 10, 15])
      }

      budget =
        {[:zone_a, :zone_b, :zone_c],
         fn a -> if map_size(a) == 3, do: a.zone_a + a.zone_b + a.zone_c <= 20, else: true end}

      min_a = {[:zone_a], fn a -> if Map.has_key?(a, :zone_a), do: a.zone_a >= 10, else: true end}
      min_b = {[:zone_b], fn a -> if Map.has_key?(a, :zone_b), do: a.zone_b >= 10, else: true end}
      min_c = {[:zone_c], fn a -> if Map.has_key?(a, :zone_c), do: a.zone_c >= 10, else: true end}

      assert {:error, :no_solution} = AC3.solve(variables, [budget, min_a, min_b, min_c])
    end

    test "heat wave tightens budget — solver finds reduced allocation" do
      heat_wave_budget = 15

      variables = %{
        vegetables: Set.new([0, 2, 4, 6, 8, 10]),
        herbs: Set.new([0, 2, 4, 6]),
        flowers: Set.new([0, 2, 4, 6]),
        lawn: Set.new([0, 2, 4])
      }

      budget =
        {[:vegetables, :herbs, :flowers, :lawn],
         fn a ->
           if map_size(a) == 4 do
             a.vegetables + a.herbs + a.flowers + a.lawn <= heat_wave_budget
           else
             true
           end
         end}

      veg_min =
        {[:vegetables],
         fn a -> if Map.has_key?(a, :vegetables), do: a.vegetables >= 6, else: true end}

      herb_min =
        {[:herbs], fn a -> if Map.has_key?(a, :herbs), do: a.herbs >= 2, else: true end}

      assert {:ok, solution} = AC3.solve(variables, [budget, veg_min, herb_min])

      assert solution.vegetables >= 6
      assert solution.herbs >= 2
      total = solution.vegetables + solution.herbs + solution.flowers + solution.lawn
      assert total <= heat_wave_budget
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Scenario 5 — Temperature cascades through evaporation chain
  # A temperature change propagates: temp → evaporation → total loss.
  # Retraction collapses the entire chain cleanly.
  # ═══════════════════════════════════════════════════════════════════════

  describe "GardenBot: temperature changes cascade through the network" do
    test "normal temperature produces modest water loss" do
      e = build_evaporation_chain()

      Network.add_content(e.net, e.temperature, 25, :thermometer)
      Process.sleep(@settle)

      # evaporation = 25 * 0.1 = 2.5
      assert_in_delta Network.read_cell(e.net, e.evaporation), 2.5, 0.01
      # total_loss = 2.5 + 2.0 = 4.5
      assert_in_delta Network.read_cell(e.net, e.total_loss), 4.5, 0.01
    end

    test "heat wave: temperature spike cascades to higher water loss" do
      e = build_evaporation_chain()

      Network.add_content(e.net, e.temperature, 25, :thermometer)
      Process.sleep(@settle)
      normal_loss = Network.read_cell(e.net, e.total_loss)

      # Heat wave — retract old reading, add new
      Network.retract_content(e.net, e.temperature, :thermometer)
      Network.add_content(e.net, e.temperature, 42, :thermometer_heatwave)
      Process.sleep(@settle)

      # evaporation = 42 * 0.1 = 4.2, total_loss = 4.2 + 2.0 = 6.2
      assert_in_delta Network.read_cell(e.net, e.evaporation), 4.2, 0.01
      heatwave_loss = Network.read_cell(e.net, e.total_loss)
      assert_in_delta heatwave_loss, 6.2, 0.01
      assert heatwave_loss > normal_loss
    end

    test "retracting temperature collapses entire chain" do
      e = build_evaporation_chain()

      Network.add_content(e.net, e.temperature, 30, :thermometer)
      Process.sleep(@settle)
      assert is_number(Network.read_cell(e.net, e.total_loss))

      # Thermometer removed — all derived values lose justification
      Network.retract_content(e.net, e.temperature, :thermometer)
      Process.sleep(@settle)

      assert Network.read_cell(e.net, e.temperature) == :nothing
      assert Network.read_cell(e.net, e.evaporation) == :nothing
      # Adder needs BOTH inputs; with evaporation gone, total_loss can't be computed
      assert Network.read_cell(e.net, e.total_loss) == :nothing
    end

    test "corrected temperature reading updates entire chain in-place" do
      e = build_evaporation_chain()

      # Faulty thermometer reads high
      Network.add_content(e.net, e.temperature, 50, :faulty_thermometer)
      Process.sleep(@settle)
      assert_in_delta Network.read_cell(e.net, e.evaporation), 5.0, 0.01

      # Replace with calibrated reading
      Network.retract_content(e.net, e.temperature, :faulty_thermometer)
      Network.add_content(e.net, e.temperature, 28, :calibrated_thermometer)
      Process.sleep(@settle)

      # Chain reflects corrected temperature
      assert_in_delta Network.read_cell(e.net, e.evaporation), 2.8, 0.01
      assert_in_delta Network.read_cell(e.net, e.total_loss), 4.8, 0.01
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Scenario 6 — Non-monotonic reasoning with JTMS out-lists
  # "Water the garden by default, UNLESS rain is expected."
  # Classic default logic: the plan is active when its defeater is absent.
  # ═══════════════════════════════════════════════════════════════════════

  describe "GardenBot: default reasoning with JTMS" do
    test "default plan: water unless rain is forecast" do
      {:ok, jtms} = JTMS.new()

      JTMS.create_node(jtms, :rain_forecast)
      JTMS.create_node(jtms, :water_plan)

      # Default rule: water_plan is IN when rain_forecast is OUT
      JTMS.justify_node(jtms, :water_plan, :default_rule, [], [:rain_forecast])

      # No rain → plan to water
      assert JTMS.node_in?(jtms, :water_plan)
      assert JTMS.node_out?(jtms, :rain_forecast)

      # Rain forecast arrives
      JTMS.assume_node(jtms, :rain_forecast)
      assert JTMS.node_in?(jtms, :rain_forecast)
      assert JTMS.node_out?(jtms, :water_plan)

      # Rain forecast retracted (was wrong)
      JTMS.retract_assumption(jtms, :rain_forecast)
      assert JTMS.node_out?(jtms, :rain_forecast)
      assert JTMS.node_in?(jtms, :water_plan)
    end

    test "multiple weather threats: rain OR frost blocks watering" do
      {:ok, jtms} = JTMS.new()

      JTMS.create_node(jtms, :rain_expected)
      JTMS.create_node(jtms, :frost_warning)
      JTMS.create_node(jtms, :safe_to_water)
      JTMS.create_node(jtms, :water_plan)

      # safe_to_water only if NEITHER rain NOR frost
      JTMS.justify_node(jtms, :safe_to_water, :weather_check, [], [:rain_expected, :frost_warning])
      # water_plan requires safe_to_water
      JTMS.justify_node(jtms, :water_plan, :garden_policy, [:safe_to_water], [])

      # Clear weather → water
      assert JTMS.node_in?(jtms, :safe_to_water)
      assert JTMS.node_in?(jtms, :water_plan)

      # Rain comes → don't water
      JTMS.assume_node(jtms, :rain_expected)
      assert JTMS.node_out?(jtms, :water_plan)

      # Rain passes, frost arrives → still don't water
      JTMS.retract_assumption(jtms, :rain_expected)
      JTMS.assume_node(jtms, :frost_warning)
      assert JTMS.node_out?(jtms, :water_plan)

      # Frost clears → safe again
      JTMS.retract_assumption(jtms, :frost_warning)
      assert JTMS.node_in?(jtms, :water_plan)
    end

    test "redundant justifications provide resilience" do
      {:ok, jtms} = JTMS.new()

      JTMS.create_node(jtms, :soil_sensor_says_dry)
      JTMS.create_node(jtms, :schedule_says_water)
      JTMS.create_node(jtms, :water_plan)

      JTMS.assume_node(jtms, :soil_sensor_says_dry)
      JTMS.assume_node(jtms, :schedule_says_water)

      # Two independent justifications for watering
      JTMS.justify_node(jtms, :water_plan, :sensor_based, [:soil_sensor_says_dry], [])
      JTMS.justify_node(jtms, :water_plan, :schedule_based, [:schedule_says_water], [])
      assert JTMS.node_in?(jtms, :water_plan)

      # Sensor goes offline — schedule still justifies
      JTMS.retract_assumption(jtms, :soil_sensor_says_dry)
      assert JTMS.node_in?(jtms, :water_plan)

      # Schedule also retracted — no justification left
      JTMS.retract_assumption(jtms, :schedule_says_water)
      assert JTMS.node_out?(jtms, :water_plan)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Scenario 7 — The composed gardener: simultaneous stresses
  # Heat wave + sensor failure + manual override all at once.
  # The bot handles each perturbation without losing coherence.
  # ═══════════════════════════════════════════════════════════════════════

  describe "GardenBot stays composed under multiple simultaneous stresses" do
    test "heat wave + sensor failure: recovers when sensor is replaced" do
      w = build_watering_network()

      Arithmetic.constant(w.net, w.target_moisture, 70, :target_config)
      Arithmetic.constant(w.net, w.liters_per_point, 0.5, :calibration)
      Process.sleep(@settle)

      # Normal operation: sensor reads 50%
      Network.add_content(w.net, w.current_moisture, 50, :sensor_main)
      Process.sleep(@settle)
      assert_in_delta Network.read_cell(w.net, w.water_needed), 10.0, 0.01

      # STRESS 1: Heat wave — raise the target (plants need more moisture)
      Network.retract_content(w.net, w.target_moisture, :target_config)
      Arithmetic.constant(w.net, w.target_moisture, 80, :heatwave_target)
      Process.sleep(@settle)

      # deficit = 80 - 50 = 30, water = 30 * 0.5 = 15
      assert_in_delta Network.read_cell(w.net, w.water_needed), 15.0, 0.01

      # STRESS 2: Main sensor fails — backup sensor reports differently → contradiction
      Network.add_content(w.net, w.current_moisture, 20, :sensor_backup)
      Process.sleep(@settle)
      assert Network.read_cell(w.net, w.current_moisture) == :contradiction

      # RECOVERY: Identify main sensor as faulty, remove it
      Network.retract_content(w.net, w.current_moisture, :sensor_main)
      Process.sleep(@settle)

      # Now only backup (20%) with heatwave target (80%)
      # deficit = 80 - 20 = 60, water = 60 * 0.5 = 30
      assert_in_delta Network.read_cell(w.net, w.water_needed), 30.0, 0.01
    end

    test "neighbor waters the garden — bot adjusts, doesn't double-water" do
      w = build_watering_network()

      Arithmetic.constant(w.net, w.target_moisture, 70, :target_config)
      Arithmetic.constant(w.net, w.liters_per_point, 0.5, :calibration)
      Process.sleep(@settle)

      # Morning: soil is dry
      Network.add_content(w.net, w.current_moisture, 35, :sensor_morning)
      Process.sleep(@settle)
      assert_in_delta Network.read_cell(w.net, w.water_needed), 17.5, 0.01

      # Neighbor waters the garden! New sensor reading shows moisture jumped
      Network.retract_content(w.net, w.current_moisture, :sensor_morning)
      Network.add_content(w.net, w.current_moisture, 65, :sensor_post_neighbor)
      Process.sleep(@settle)

      # deficit = 70 - 65 = 5, water = 5 * 0.5 = 2.5
      # Bot only adds a small top-up, doesn't re-dump the original 17.5L
      assert_in_delta Network.read_cell(w.net, w.water_needed), 2.5, 0.01
    end

    test "full day: dawn to dusk with changing conditions" do
      w = build_watering_network()

      Arithmetic.constant(w.net, w.target_moisture, 70, :target_config)
      Arithmetic.constant(w.net, w.liters_per_point, 0.5, :calibration)
      Process.sleep(@settle)

      # Dawn: dry soil
      Network.add_content(w.net, w.current_moisture, 30, :sensor_dawn)
      Process.sleep(@settle)
      assert_in_delta Network.read_cell(w.net, w.water_needed), 20.0, 0.01

      # Mid-morning: bot watered, soil improved
      Network.retract_content(w.net, w.current_moisture, :sensor_dawn)
      Network.add_content(w.net, w.current_moisture, 60, :sensor_midmorning)
      Process.sleep(@settle)
      assert_in_delta Network.read_cell(w.net, w.water_needed), 5.0, 0.01

      # Noon: heat spike dries soil again
      Network.retract_content(w.net, w.current_moisture, :sensor_midmorning)
      Network.add_content(w.net, w.current_moisture, 45, :sensor_noon)
      Process.sleep(@settle)
      assert_in_delta Network.read_cell(w.net, w.water_needed), 12.5, 0.01

      # Afternoon: unexpected rain! Soil saturated beyond target
      Network.retract_content(w.net, w.current_moisture, :sensor_noon)
      Network.add_content(w.net, w.current_moisture, 80, :sensor_after_rain)
      Process.sleep(@settle)
      # deficit = 70 - 80 = -10, water = -10 * 0.5 = -5 (surplus — don't water!)
      rain_need = Network.read_cell(w.net, w.water_needed)
      assert rain_need < 0

      # Dusk: soil draining back toward normal
      Network.retract_content(w.net, w.current_moisture, :sensor_after_rain)
      Network.add_content(w.net, w.current_moisture, 68, :sensor_dusk)
      Process.sleep(@settle)
      assert_in_delta Network.read_cell(w.net, w.water_needed), 1.0, 0.01
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Scenario 8 — Multi-zone scheduling under constraints
  # Multiple zones compete for a single hose in limited time windows.
  # The constraint solver assigns non-overlapping time slots.
  # ═══════════════════════════════════════════════════════════════════════

  describe "GardenBot: scheduling watering across zones" do
    test "assigns non-overlapping time slots respecting each zone's window" do
      variables = %{
        vegetables: Set.new([0, 1, 2, 3]),
        herbs: Set.new([1, 2, 3, 4]),
        flowers: Set.new([2, 3, 4, 5]),
        lawn: Set.new([0, 1, 2, 3, 4, 5])
      }

      neq = fn var1, var2 ->
        {[var1, var2],
         fn a ->
           if Map.has_key?(a, var1) and Map.has_key?(a, var2), do: a[var1] != a[var2], else: true
         end}
      end

      constraints = [
        neq.(:vegetables, :herbs),
        neq.(:vegetables, :flowers),
        neq.(:vegetables, :lawn),
        neq.(:herbs, :flowers),
        neq.(:herbs, :lawn),
        neq.(:flowers, :lawn)
      ]

      assert {:ok, solution} = AC3.solve(variables, constraints)

      # All slots are unique
      times = Map.values(solution)
      assert length(Enum.uniq(times)) == 4

      # Each zone within its allowed window
      assert solution.vegetables in [0, 1, 2, 3]
      assert solution.herbs in [1, 2, 3, 4]
      assert solution.flowers in [2, 3, 4, 5]
      assert solution.lawn in [0, 1, 2, 3, 4, 5]
    end

    test "too many zones in a narrow window → infeasible" do
      # Three zones in only 2 available slots
      variables = %{
        zone_a: Set.new([1, 2]),
        zone_b: Set.new([1, 2]),
        zone_c: Set.new([1, 2])
      }

      neq = fn var1, var2 ->
        {[var1, var2],
         fn a ->
           if Map.has_key?(a, var1) and Map.has_key?(a, var2), do: a[var1] != a[var2], else: true
         end}
      end

      constraints = [neq.(:zone_a, :zone_b), neq.(:zone_b, :zone_c), neq.(:zone_a, :zone_c)]
      assert {:error, :no_solution} = AC3.solve(variables, constraints)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Scenario 9 — Diamond dependency in irrigation planning
  # A single water source splits to two zones, both feed total usage.
  # Retracting the source collapses the entire diamond; restoring it
  # re-derives all values.
  # ═══════════════════════════════════════════════════════════════════════

  describe "GardenBot: diamond dependency — single source, two zones" do
    test "source splits to zones, both contribute to total" do
      {:ok, net} = Network.new()

      source_flow = Network.create_cell(net)
      zone_a_ratio = Network.create_cell(net)
      zone_b_ratio = Network.create_cell(net)
      zone_a_usage = Network.create_cell(net)
      zone_b_usage = Network.create_cell(net)
      total_usage = Network.create_cell(net)

      Arithmetic.multiplier(net, source_flow, zone_a_ratio, zone_a_usage)
      Arithmetic.multiplier(net, source_flow, zone_b_ratio, zone_b_usage)
      Arithmetic.adder(net, zone_a_usage, zone_b_usage, total_usage)
      Process.sleep(@settle)

      Arithmetic.constant(net, zone_a_ratio, 0.6, :zone_a_config)
      Arithmetic.constant(net, zone_b_ratio, 0.4, :zone_b_config)
      Process.sleep(@settle)

      Network.add_content(net, source_flow, 100, :flow_meter)
      Process.sleep(@settle)

      assert_in_delta Network.read_cell(net, zone_a_usage), 60.0, 0.01
      assert_in_delta Network.read_cell(net, zone_b_usage), 40.0, 0.01
      assert_in_delta Network.read_cell(net, total_usage), 100.0, 0.01

      # Valve fails — entire diamond collapses
      Network.retract_content(net, source_flow, :flow_meter)
      Process.sleep(@settle)

      assert Network.read_cell(net, source_flow) == :nothing
      assert Network.read_cell(net, zone_a_usage) == :nothing
      assert Network.read_cell(net, zone_b_usage) == :nothing
      assert Network.read_cell(net, total_usage) == :nothing

      # Flow restored at lower rate
      Network.add_content(net, source_flow, 50, :flow_meter_restored)
      Process.sleep(@settle)

      assert_in_delta Network.read_cell(net, zone_a_usage), 30.0, 0.01
      assert_in_delta Network.read_cell(net, zone_b_usage), 20.0, 0.01
      assert_in_delta Network.read_cell(net, total_usage), 50.0, 0.01
    end

    test "backward inference: know total usage, deduce source flow" do
      {:ok, net} = Network.new()

      source_flow = Network.create_cell(net)
      ratio = Network.create_cell(net)
      usage = Network.create_cell(net)

      Arithmetic.multiplier(net, source_flow, ratio, usage)
      Process.sleep(@settle)

      Arithmetic.constant(net, ratio, 0.6, :zone_config)
      Network.add_content(net, usage, 30, :usage_meter)
      Process.sleep(@settle)

      # source_flow = usage / ratio = 30 / 0.6 = 50
      assert_in_delta Network.read_cell(net, source_flow), 50.0, 0.01
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Scenario 10 — The patient gardener: sequential belief revision
  # The bot accumulates observations over time, revises its diagnosis
  # of a plant problem, and adjusts its response. No knee-jerk reactions.
  # ═══════════════════════════════════════════════════════════════════════

  describe "GardenBot: patient belief revision over time" do
    test "revises plant diagnosis as new evidence arrives" do
      {:ok, jtms} = JTMS.new()

      # Observations
      JTMS.create_node(jtms, :yellow_leaves)
      JTMS.create_node(jtms, :wilting)

      # Diagnoses
      JTMS.create_node(jtms, :overwatered)
      JTMS.create_node(jtms, :underwatered)

      # Actions
      JTMS.create_node(jtms, :reduce_water)
      JTMS.create_node(jtms, :increase_water)

      # Observation: yellow leaves
      JTMS.assume_node(jtms, :yellow_leaves)

      # Hypothesis 1: yellow leaves WITHOUT wilting → overwatered
      JTMS.justify_node(jtms, :overwatered, :hypothesis_1, [:yellow_leaves], [:wilting])
      assert JTMS.node_in?(jtms, :overwatered)

      # If overwatered → reduce water
      JTMS.justify_node(jtms, :reduce_water, :response_overwater, [:overwatered], [])
      assert JTMS.node_in?(jtms, :reduce_water)

      # New observation: plant is ALSO wilting
      JTMS.assume_node(jtms, :wilting)

      # Wilting invalidates the overwatering hypothesis (it required wilting OUT)
      assert JTMS.node_out?(jtms, :overwatered)
      assert JTMS.node_out?(jtms, :reduce_water)

      # Hypothesis 2: yellow leaves + wilting → underwatered
      JTMS.justify_node(jtms, :underwatered, :hypothesis_2, [:yellow_leaves, :wilting], [])
      assert JTMS.node_in?(jtms, :underwatered)

      # If underwatered → increase water
      JTMS.justify_node(jtms, :increase_water, :response_underwater, [:underwatered], [])
      assert JTMS.node_in?(jtms, :increase_water)

      # Bot pivoted from "reduce" to "increase" — no contradiction, just revision
      assert JTMS.node_out?(jtms, :reduce_water)
      assert JTMS.node_in?(jtms, :increase_water)
    end

    test "retracted observation restores original default reasoning" do
      {:ok, jtms} = JTMS.new()

      JTMS.create_node(jtms, :soil_dry)
      JTMS.create_node(jtms, :recent_rain)
      JTMS.create_node(jtms, :should_water)

      # Default: water if soil is dry and no recent rain
      JTMS.assume_node(jtms, :soil_dry)
      JTMS.justify_node(jtms, :should_water, :dry_soil_rule, [:soil_dry], [:recent_rain])
      assert JTMS.node_in?(jtms, :should_water)

      # It rained
      JTMS.assume_node(jtms, :recent_rain)
      assert JTMS.node_out?(jtms, :should_water)

      # Days pass, rain is no longer "recent"
      JTMS.retract_assumption(jtms, :recent_rain)
      assert JTMS.node_in?(jtms, :should_water)

      # Soil measurement updated — no longer dry
      JTMS.retract_assumption(jtms, :soil_dry)
      assert JTMS.node_out?(jtms, :should_water)
    end

    test "chain of reasoning: weather → soil prediction → action" do
      {:ok, jtms} = JTMS.new()

      JTMS.create_node(jtms, :hot_weather)
      JTMS.create_node(jtms, :cold_weather)
      JTMS.create_node(jtms, :soil_will_dry)
      JTMS.create_node(jtms, :soil_will_stay_wet)
      JTMS.create_node(jtms, :preemptive_water)
      JTMS.create_node(jtms, :skip_watering)

      # Hot weather → soil will dry (unless cold)
      JTMS.assume_node(jtms, :hot_weather)
      JTMS.justify_node(jtms, :soil_will_dry, :heat_effect, [:hot_weather], [:cold_weather])

      # If soil will dry → water preemptively
      JTMS.justify_node(jtms, :preemptive_water, :proactive_plan, [:soil_will_dry], [])

      assert JTMS.node_in?(jtms, :soil_will_dry)
      assert JTMS.node_in?(jtms, :preemptive_water)

      # Cold front moves in
      JTMS.assume_node(jtms, :cold_weather)

      # Cold weather defeats the "soil will dry" prediction
      assert JTMS.node_out?(jtms, :soil_will_dry)
      assert JTMS.node_out?(jtms, :preemptive_water)

      # Cold means soil stays wet → skip watering
      JTMS.justify_node(jtms, :soil_will_stay_wet, :cold_effect, [:cold_weather], [])
      JTMS.justify_node(jtms, :skip_watering, :conservation, [:soil_will_stay_wet], [])

      assert JTMS.node_in?(jtms, :skip_watering)

      # Cold front passes
      JTMS.retract_assumption(jtms, :cold_weather)

      # Back to hot weather reasoning
      assert JTMS.node_in?(jtms, :soil_will_dry)
      assert JTMS.node_in?(jtms, :preemptive_water)
      assert JTMS.node_out?(jtms, :skip_watering)
    end
  end
end
