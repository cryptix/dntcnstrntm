defmodule HomeAgent.StateStoreTest do
  use ExUnit.Case, async: false

  alias HomeAgent.StateStore

  setup do
    # Start a fresh StateStore for each test group.
    # Since the ETS table is named and global we start it once; tests share it.
    case StateStore.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "put/1 and get/1" do
    test "stores and retrieves entity state" do
      data = %{
        "entity_id" => "light.kitchen",
        "new_state" => %{
          "state" => "on",
          "attributes" => %{"brightness" => 200},
          "last_changed" => "2026-01-01T12:00:00+00:00"
        }
      }

      assert :ok = StateStore.put(data)
      assert {"on", %{"brightness" => 200}, _ts} = StateStore.get("light.kitchen")
    end

    test "returns :not_found for unknown entity" do
      assert :not_found = StateStore.get("sensor.nonexistent_#{System.unique_integer()}")
    end

    test "last write wins on update" do
      entity = "binary_sensor.test_#{System.unique_integer()}"

      StateStore.put(%{
        "entity_id" => entity,
        "new_state" => %{"state" => "on", "attributes" => %{}, "last_changed" => nil}
      })

      StateStore.put(%{
        "entity_id" => entity,
        "new_state" => %{"state" => "off", "attributes" => %{}, "last_changed" => nil}
      })

      assert {"off", _, _} = StateStore.get(entity)
    end

    test "ignores malformed data" do
      assert :ok = StateStore.put(%{"entity_id" => "x"})
      assert :ok = StateStore.put("not a map")
    end
  end

  describe "state/1" do
    test "returns the state string" do
      entity = "sensor.temp_#{System.unique_integer()}"
      StateStore.put(%{"entity_id" => entity, "new_state" => %{"state" => "23.5", "attributes" => %{}, "last_changed" => nil}})
      assert StateStore.state(entity) == "23.5"
    end

    test "returns nil for unknown entity" do
      assert nil == StateStore.state("sensor.not_here_#{System.unique_integer()}")
    end
  end

  describe "on?/1" do
    test "returns true for 'on'" do
      entity = "light.test_#{System.unique_integer()}"
      StateStore.put(%{"entity_id" => entity, "new_state" => %{"state" => "on", "attributes" => %{}, "last_changed" => nil}})
      assert StateStore.on?(entity)
    end

    test "returns false for 'off'" do
      entity = "light.test2_#{System.unique_integer()}"
      StateStore.put(%{"entity_id" => entity, "new_state" => %{"state" => "off", "attributes" => %{}, "last_changed" => nil}})
      refute StateStore.on?(entity)
    end

    test "returns true for 'home'" do
      entity = "person.test_#{System.unique_integer()}"
      StateStore.put(%{"entity_id" => entity, "new_state" => %{"state" => "home", "attributes" => %{}, "last_changed" => nil}})
      assert StateStore.on?(entity)
    end

    test "returns false for unknown entity" do
      refute StateStore.on?("sensor.unknown_#{System.unique_integer()}")
    end
  end
end
