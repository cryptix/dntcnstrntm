defmodule HomeAgent.Datalog.FactGeneratorTest do
  use ExUnit.Case, async: false

  alias HomeAgent.Datalog.FactGenerator
  alias HomeAgent.StateStore

  setup do
    case StateStore.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Set some sensor state for the default rooms defined in test config
    StateStore.put(%{
      "entity_id" => "binary_sensor.kitchen_mmwave_presence",
      "new_state" => %{"state" => "on", "attributes" => %{}, "last_changed" => nil}
    })

    StateStore.put(%{
      "entity_id" => "binary_sensor.kitchen_door",
      "new_state" => %{"state" => "off", "attributes" => %{}, "last_changed" => nil}
    })

    :ok
  end

  describe "build_facts/0" do
    test "includes type_period declaration" do
      facts = FactGenerator.build_facts()
      assert facts =~ ".decl time_period"
    end

    test "includes a time_period fact" do
      facts = FactGenerator.build_facts()
      assert facts =~ ~r/time_period\("[a-z_]+"\)\./
    end

    test "includes current_timestamp" do
      facts = FactGenerator.build_facts()
      assert facts =~ ~r/current_timestamp\(\d+\)\./
    end

    test "includes sensor declarations" do
      facts = FactGenerator.build_facts()
      assert facts =~ ".decl mmwave_active"
      assert facts =~ ".decl pir_active"
      assert facts =~ ".decl door_closed"
    end

    test "includes confidence declarations" do
      facts = FactGenerator.build_facts()
      assert facts =~ ".decl room_occupied_confidence"
      assert facts =~ ".decl room_epistemic_type"
    end

    test "emits mmwave_active fact when sensor is on" do
      facts = FactGenerator.build_facts()
      # kitchen mmwave is on (set in setup)
      assert facts =~ ~r/mmwave_active\("kitchen"/
    end

    test "emits door_closed when door is off (closed)" do
      facts = FactGenerator.build_facts()
      assert facts =~ ~r/door_closed\("kitchen"/
    end

    test "output is a non-empty string" do
      facts = FactGenerator.build_facts()
      assert is_binary(facts)
      assert byte_size(facts) > 50
    end
  end
end
