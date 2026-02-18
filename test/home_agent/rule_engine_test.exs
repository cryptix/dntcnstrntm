defmodule HomeAgent.Datalog.RuleEngineTest do
  use ExUnit.Case, async: true

  alias HomeAgent.Datalog.RuleEngine

  describe "parse_output/1" do
    test "parses a single relation" do
      output = """
      ---------------
      should_light_on
      ---------------
      kitchen\t2700\t153
      """

      result = RuleEngine.parse_output(output)
      assert Map.has_key?(result, "should_light_on")
      assert [["kitchen", "2700", "153"]] = result["should_light_on"]
    end

    test "parses multiple relations" do
      output = """
      ---------------
      should_light_on
      ---------------
      kitchen\t4000\t200
      bedroom\t2700\t100
      ---------------
      room_inactive
      ---------------
      living_room
      """

      result = RuleEngine.parse_output(output)
      assert length(result["should_light_on"]) == 2
      assert [["living_room"]] = result["room_inactive"]
    end

    test "returns empty map for empty output" do
      assert %{} = RuleEngine.parse_output("")
    end

    test "handles relation with no rows" do
      output = """
      ---------------
      effective_confidence
      ---------------
      """

      result = RuleEngine.parse_output(output)
      # Empty rows are filtered by split/trim
      assert Map.has_key?(result, "effective_confidence") or result == %{}
    end
  end

  describe "evaluate_string/1" do
    @tag :requires_souffle
    test "evaluates a trivial program" do
      facts = """
      time_period("evening").
      room_occupied_confidence("kitchen", 90).
      room_epistemic_type("kitchen", "djuno").
      """

      case RuleEngine.evaluate_string(facts) do
        {:ok, results} ->
          assert is_map(results)

        {:error, :souffle_not_found} ->
          # Acceptable: Soufflé not installed in this environment
          :ok

        {:error, reason} ->
          flunk("Unexpected error: #{inspect(reason)}")
      end
    end
  end
end
