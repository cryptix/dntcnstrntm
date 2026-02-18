defmodule HomeAgent.RoomConfigTest do
  use ExUnit.Case, async: true

  alias HomeAgent.RoomConfig

  # Tests rely on the rooms defined in config/config.exs being loaded.
  # If none are loaded (e.g. bare test run), rooms() returns [].

  describe "rooms/0" do
    test "returns a list" do
      assert is_list(RoomConfig.rooms())
    end
  end

  describe "get/1" do
    test "returns nil for unknown room" do
      assert nil == RoomConfig.get("no_such_room_#{System.unique_integer()}")
    end
  end

  describe "entity_to_room/1" do
    test "returns nil for unknown entity" do
      assert nil == RoomConfig.entity_to_room("sensor.unknown_#{System.unique_integer()}")
    end

    test "maps known entity back to room when config is present" do
      rooms = Application.get_env(:home_agent, :rooms, %{})

      Enum.each(rooms, fn {room, cfg} ->
        if cfg[:mmwave] do
          assert {^room, :mmwave} = RoomConfig.entity_to_room(cfg[:mmwave])
        end

        if cfg[:pir] do
          assert {^room, :pir} = RoomConfig.entity_to_room(cfg[:pir])
        end

        if cfg[:door] do
          assert {^room, :door} = RoomConfig.entity_to_room(cfg[:door])
        end
      end)
    end
  end

  describe "light_entity/1" do
    test "returns nil for unknown room" do
      assert nil == RoomConfig.light_entity("no_such_room")
    end

    test "returns entity string for known room when config is present" do
      Enum.each(RoomConfig.rooms(), fn room ->
        entity = RoomConfig.light_entity(room)
        assert is_binary(entity) or is_nil(entity)
      end)
    end
  end
end
