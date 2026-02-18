import Config

config :home_agent,
  ha_host: System.get_env("HA_HOST", "homeassistant.local"),
  ha_port: String.to_integer(System.get_env("HA_PORT", "8123")),
  ha_token: System.get_env("HA_TOKEN", ""),
  souffle_bin: System.get_env("SOUFFLE_BIN", "souffle"),
  # Slow-path evaluation interval (milliseconds)
  datalog_interval_ms: 5_000,
  # Confidence threshold (0–100) below which lights fade rather than snap on
  min_presence_confidence: 60,
  # Room → entity mappings: %{room_name => %{light: entity_id, sensors: [...]}}
  rooms: %{
    "kitchen" => %{
      light: "light.kitchen",
      mmwave: "binary_sensor.kitchen_mmwave_presence",
      pir: "binary_sensor.kitchen_motion",
      door: "binary_sensor.kitchen_door"
    },
    "living_room" => %{
      light: "light.living_room",
      mmwave: "binary_sensor.living_room_mmwave_presence",
      pir: "binary_sensor.living_room_motion",
      door: nil
    },
    "bedroom" => %{
      light: "light.bedroom",
      mmwave: "binary_sensor.bedroom_mmwave_presence",
      pir: "binary_sensor.bedroom_motion",
      door: "binary_sensor.bedroom_door"
    }
  }
