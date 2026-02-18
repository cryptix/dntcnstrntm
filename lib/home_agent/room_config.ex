defmodule HomeAgent.RoomConfig do
  @moduledoc """
  Helpers for accessing per-room configuration from `config :home_agent, rooms: …`.

  Room config shape (see config/config.exs):

      %{
        "kitchen" => %{
          light:  "light.kitchen",
          mmwave: "binary_sensor.kitchen_mmwave_presence",
          pir:    "binary_sensor.kitchen_motion",
          door:   "binary_sensor.kitchen_door"   # nil if no door sensor
        }
      }
  """

  @doc "Return the list of configured room names."
  def rooms do
    Application.get_env(:home_agent, :rooms, %{}) |> Map.keys()
  end

  @doc "Return the full config map for a room, or nil."
  def get(room) do
    Application.get_env(:home_agent, :rooms, %{}) |> Map.get(room)
  end

  @doc "Return the HA entity ID for a room's light."
  def light_entity(room) do
    case get(room) do
      %{light: id} -> id
      _ -> nil
    end
  end

  @doc "Return the mmWave sensor entity ID for a room, or nil."
  def mmwave_entity(room) do
    case get(room) do
      %{mmwave: id} -> id
      _ -> nil
    end
  end

  @doc "Return the PIR motion sensor entity ID for a room, or nil."
  def pir_entity(room) do
    case get(room) do
      %{pir: id} -> id
      _ -> nil
    end
  end

  @doc "Return the door sensor entity ID for a room, or nil."
  def door_entity(room) do
    case get(room) do
      %{door: id} -> id
      _ -> nil
    end
  end

  @doc "Map a sensor entity ID back to its room name and sensor type."
  def entity_to_room(entity_id) do
    Enum.find_value(
      Application.get_env(:home_agent, :rooms, %{}),
      fn {room, cfg} ->
        cond do
          cfg[:mmwave] == entity_id -> {room, :mmwave}
          cfg[:pir] == entity_id -> {room, :pir}
          cfg[:door] == entity_id -> {room, :door}
          true -> nil
        end
      end
    )
  end
end
