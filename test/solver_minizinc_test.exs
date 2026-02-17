defmodule Propagator.Solver.MiniZincTest do
  use ExUnit.Case, async: true

  alias Propagator.Lattice.Set
  alias Propagator.Solver.MiniZinc

  # ---------------------------------------------------------------------------
  # Model-building tests — no Solverl or MiniZinc required
  # ---------------------------------------------------------------------------

  describe "build_model/2 — variable declarations" do
    test "contiguous integer range produces range syntax" do
      variables = %{x: Set.new([1, 2, 3])}
      model = MiniZinc.build_model(variables, [])
      assert model =~ "var 1..3: x;"
    end

    test "sparse integer set produces set syntax" do
      variables = %{x: Set.new([1, 3, 7])}
      model = MiniZinc.build_model(variables, [])
      assert model =~ "var {1, 3, 7}: x;"
    end

    test "single-value domain produces singleton range" do
      variables = %{x: Set.new([5])}
      model = MiniZinc.build_model(variables, [])
      assert model =~ "var 5..5: x;"
    end

    test "negative integers are included verbatim" do
      variables = %{x: Set.new([-2, -1, 0, 1, 2])}
      model = MiniZinc.build_model(variables, [])
      assert model =~ "var -2..2: x;"
    end

    test "multiple variables each get a declaration" do
      variables = %{
        x: Set.new([1, 2, 3]),
        y: Set.new([4, 5, 6])
      }

      model = MiniZinc.build_model(variables, [])
      assert model =~ "var 1..3: x;"
      assert model =~ "var 4..6: y;"
    end
  end

  describe "build_model/2 — constraint lines" do
    test "single MiniZinc constraint is emitted" do
      variables = %{x: Set.new([1, 2, 3]), y: Set.new([1, 2, 3])}
      model = MiniZinc.build_model(variables, [{:mzn, "x < y"}])
      assert model =~ "constraint x < y;"
    end

    test "multiple constraints all appear" do
      variables = %{
        x: Set.new([1, 2, 3]),
        y: Set.new([1, 2, 3]),
        z: Set.new([1, 2, 3])
      }

      constraints = [
        {:mzn, "x < y"},
        {:mzn, "y < z"}
      ]

      model = MiniZinc.build_model(variables, constraints)
      assert model =~ "constraint x < y;"
      assert model =~ "constraint y < z;"
    end

    test "no constraints emits only declarations and solve" do
      variables = %{x: Set.new([1, 2])}
      model = MiniZinc.build_model(variables, [])
      refute model =~ "constraint"
      assert model =~ "solve satisfy;"
    end
  end

  describe "build_model/2 — model structure" do
    test "model always ends with solve satisfy" do
      variables = %{x: Set.new([1, 2, 3])}
      constraints = [{:mzn, "x > 1"}]
      model = MiniZinc.build_model(variables, constraints)

      lines = String.split(model, "\n") |> Enum.map(&String.trim/1)
      assert List.last(lines) == "solve satisfy;"
    end

    test "declarations appear before constraints" do
      variables = %{x: Set.new([1, 2, 3]), y: Set.new([1, 2, 3])}
      constraints = [{:mzn, "x != y"}]
      model = MiniZinc.build_model(variables, constraints)

      lines = String.split(model, "\n")
      decl_idx = Enum.find_index(lines, &(&1 =~ "var "))
      cst_idx = Enum.find_index(lines, &(&1 =~ "constraint "))

      assert decl_idx < cst_idx
    end

    test "full model is parseable MiniZinc text" do
      # Check that the model is syntactically plausible:
      # every var line ends with ';', every constraint line ends with ';'.
      variables = %{
        a: Set.new([1, 2, 3]),
        b: Set.new([1, 3, 5])
      }

      constraints = [
        {:mzn, "a + b <= 6"},
        {:mzn, "a != b"}
      ]

      model = MiniZinc.build_model(variables, constraints)

      model
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.each(fn line ->
        assert String.ends_with?(String.trim(line), ";"),
               "Expected line to end with ';': #{inspect(line)}"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Integration tests — require Solverl and MiniZinc on PATH
  #
  # Tag: @tag :minizinc
  # Run with:  mix test --include minizinc
  # Skip with: mix test  (default, excluded)
  # ---------------------------------------------------------------------------

  @moduletag :skip

  describe "solve/2 — integration with MiniZinc" do
    @tag :minizinc
    test "solves simple binary inequality" do
      variables = %{
        x: Set.new([1, 2, 3]),
        y: Set.new([1, 2, 3])
      }

      constraints = [{:mzn, "x < y"}]

      assert {:ok, solution} = MiniZinc.solve(variables, constraints)
      assert solution.x < solution.y
    end

    @tag :minizinc
    test "detects unsatisfiable constraints" do
      variables = %{
        x: Set.new([1, 2]),
        y: Set.new([3, 4])
      }

      # x and y must be equal but have disjoint domains
      constraints = [{:mzn, "x = y"}]

      assert {:error, :no_solution} = MiniZinc.solve(variables, constraints)
    end

    @tag :minizinc
    test "solves three-variable ordering" do
      variables = %{
        x: Set.new([1, 2, 3]),
        y: Set.new([1, 2, 3]),
        z: Set.new([1, 2, 3])
      }

      constraints = [
        {:mzn, "x < y"},
        {:mzn, "y < z"}
      ]

      assert {:ok, solution} = MiniZinc.solve(variables, constraints)
      assert solution.x < solution.y
      assert solution.y < solution.z
    end

    @tag :minizinc
    test "uses sparse domain constraint" do
      variables = %{x: Set.new([1, 3, 5, 7])}
      constraints = [{:mzn, "x > 4"}]

      assert {:ok, solution} = MiniZinc.solve(variables, constraints)
      assert solution.x in [5, 7]
    end

    @tag :minizinc
    test "mixed MiniZinc and Elixir function constraints" do
      variables = %{
        x: Set.new([1, 2, 3]),
        y: Set.new([1, 2, 3])
      }

      # MiniZinc constraint: x < y
      mzn_constraint = {:mzn, "x < y"}

      # Elixir post-filter: both values must be odd
      elixir_constraint =
        {[:x, :y],
         fn assignment ->
           if Map.has_key?(assignment, :x) and Map.has_key?(assignment, :y) do
             rem(assignment.x, 2) == 1 and rem(assignment.y, 2) == 1
           else
             true
           end
         end}

      # x=1, y=3 is the only solution satisfying both
      assert {:ok, solution} = MiniZinc.solve(variables, [mzn_constraint, elixir_constraint])
      assert solution.x < solution.y
      assert rem(solution.x, 2) == 1
      assert rem(solution.y, 2) == 1
    end

    @tag :minizinc
    test "alldifferent-style problem" do
      variables = %{
        a: Set.new([1, 2, 3]),
        b: Set.new([1, 2, 3]),
        c: Set.new([1, 2, 3])
      }

      constraints = [
        {:mzn, "a != b"},
        {:mzn, "b != c"},
        {:mzn, "a != c"}
      ]

      assert {:ok, solution} = MiniZinc.solve(variables, constraints)
      assert solution.a != solution.b
      assert solution.b != solution.c
      assert solution.a != solution.c
    end

    @tag :minizinc
    test "arithmetic sum constraint" do
      variables = %{
        x: Set.new([1, 2, 3]),
        y: Set.new([1, 2, 3]),
        z: Set.new([2, 3, 4])
      }

      constraints = [{:mzn, "x + y = z"}]

      assert {:ok, solution} = MiniZinc.solve(variables, constraints)
      assert solution.x + solution.y == solution.z
    end
  end
end
