defmodule Propagator.Domain.Room do
  @moduledoc """
  A room model implemented as a `ValueInterface` domain.

  Models a single room with environmental sensors, comfort computation,
  and rule-driven actuator control. Designed as a test bed for the
  model-interrogation UI; the same ValueInterface makes it straightforward
  to swap this for a larger domain (e.g. a building, a garden setup).

  ## Cells

  Sensors (set externally):
    - `:temperature` — room temperature in °F
    - `:humidity`    — relative humidity %
    - `:occupancy`   — number of occupants
    - `:co2`         — CO₂ level in ppm

  Derived (computed by propagators):
    - `:comfort_index` — 0–100 comfort score; 100 = perfect (72°F, 50% RH)

  Actuators (driven by rules):
    - `:cooling_on`    — AC active when temp > 76°F
    - `:heating_on`    — Heater active when temp < 68°F
    - `:ventilation_on`— Ventilation active when CO₂ > 1000 ppm
    - `:lights_on`     — Lights active when occupancy > 0

  ## Rules

  Each rule is a Network propagator. When its condition is met it asserts
  `true` into the actuator cell under an informant named after the rule.
  When the condition is no longer met the propagator returns `:skip`, and
  the JTMS automatically retracts the derived belief because its supporting
  TMS nodes (the sensor readings) are no longer `:in`.

  ## Scaling note

  The `ValueInterface` behaviour means bigger domains (a full gardening
  setup, a building HVAC system) can expose the same API without changing
  the inspector or UI layers.
  """

  @behaviour Propagator.Domain.ValueInterface

  alias Propagator.Network

  defstruct [:net, :cells]

  @cell_specs [
    %{name: :temperature, type: :sensor, description: "Room temperature", unit: "°F"},
    %{name: :humidity, type: :sensor, description: "Relative humidity", unit: "%"},
    %{name: :occupancy, type: :sensor, description: "Number of occupants", unit: "people"},
    %{name: :co2, type: :sensor, description: "CO₂ concentration", unit: "ppm"},
    %{name: :comfort_index, type: :derived, description: "Thermal comfort score (0–100)", unit: nil},
    %{name: :cooling_on, type: :actuator, description: "Air conditioning active", unit: nil},
    %{name: :heating_on, type: :actuator, description: "Heating active", unit: nil},
    %{name: :ventilation_on, type: :actuator, description: "Ventilation active", unit: nil},
    %{name: :lights_on, type: :actuator, description: "Lights active", unit: nil}
  ]

  @rule_specs [
    %{
      name: :ac_rule,
      description: "AC on when temperature > 76°F",
      inputs: [:temperature],
      outputs: [:cooling_on]
    },
    %{
      name: :heat_rule,
      description: "Heating on when temperature < 68°F",
      inputs: [:temperature],
      outputs: [:heating_on]
    },
    %{
      name: :ventilation_rule,
      description: "Ventilation on when CO₂ > 1000 ppm",
      inputs: [:co2],
      outputs: [:ventilation_on]
    },
    %{
      name: :lights_rule,
      description: "Lights on when occupancy > 0",
      inputs: [:occupancy],
      outputs: [:lights_on]
    },
    %{
      name: :comfort_rule,
      description: "Comfort index: 100 − 1.5×|temp−72| − 0.5×|humidity−50|",
      inputs: [:temperature, :humidity],
      outputs: [:comfort_index]
    }
  ]

  @impl true
  def cell_specs, do: @cell_specs

  @impl true
  def rule_specs, do: @rule_specs

  @impl true
  def new do
    {:ok, net} = Network.new()

    cells = %{
      temperature: Network.create_cell(net),
      humidity: Network.create_cell(net),
      occupancy: Network.create_cell(net),
      co2: Network.create_cell(net),
      comfort_index: Network.create_cell(net),
      cooling_on: Network.create_cell(net),
      heating_on: Network.create_cell(net),
      ventilation_on: Network.create_cell(net),
      lights_on: Network.create_cell(net)
    }

    install_rules(net, cells)

    {:ok, %__MODULE__{net: net, cells: cells}}
  end

  @impl true
  def read(%__MODULE__{net: net, cells: cells}, cell_name) do
    Network.read_cell(net, cells[cell_name])
  end

  @impl true
  def set(%__MODULE__{net: net, cells: cells}, cell_name, value, source) do
    Network.add_content(net, cells[cell_name], value, source)
  end

  @impl true
  def retract(%__MODULE__{net: net, cells: cells}, cell_name, source) do
    Network.retract_content(net, cells[cell_name], source)
  end

  @impl true
  def network(%__MODULE__{net: net}), do: net

  @impl true
  def cell_ids(%__MODULE__{cells: cells}), do: cells

  # ── Rules (propagators) ──────────────────────────────────────────────────

  defp install_rules(net, cells) do
    # AC cooling: temperature > 76°F → cooling_on = true
    Network.create_propagator(
      net,
      [cells.temperature],
      [cells.cooling_on],
      fn [temp] ->
        if is_number(temp) and temp > 76 do
          [{cells.cooling_on, true}]
        else
          :skip
        end
      end,
      :ac_rule
    )

    # Heating: temperature < 68°F → heating_on = true
    Network.create_propagator(
      net,
      [cells.temperature],
      [cells.heating_on],
      fn [temp] ->
        if is_number(temp) and temp < 68 do
          [{cells.heating_on, true}]
        else
          :skip
        end
      end,
      :heat_rule
    )

    # Ventilation: CO₂ > 1000 ppm → ventilation_on = true
    Network.create_propagator(
      net,
      [cells.co2],
      [cells.ventilation_on],
      fn [co2] ->
        if is_number(co2) and co2 > 1000 do
          [{cells.ventilation_on, true}]
        else
          :skip
        end
      end,
      :ventilation_rule
    )

    # Lights: occupancy > 0 → lights_on = true
    Network.create_propagator(
      net,
      [cells.occupancy],
      [cells.lights_on],
      fn [occ] ->
        if is_number(occ) and occ > 0 do
          [{cells.lights_on, true}]
        else
          :skip
        end
      end,
      :lights_rule
    )

    # Comfort index: 100 − 1.5×|temp−72| − 0.5×|humidity−50|, clamped [0,100]
    Network.create_propagator(
      net,
      [cells.temperature, cells.humidity],
      [cells.comfort_index],
      fn [temp, humidity] ->
        if is_number(temp) and is_number(humidity) do
          index =
            (100.0 - 1.5 * abs(temp - 72.0) - 0.5 * abs(humidity - 50.0))
            |> max(0.0)
            |> min(100.0)
            |> Float.round(1)

          [{cells.comfort_index, index}]
        else
          :skip
        end
      end,
      :comfort_rule
    )
  end
end
