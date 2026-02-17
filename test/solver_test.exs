defmodule Propagator.SolverTest do
  use ExUnit.Case, async: true
  alias Propagator.Lattice.Set
  alias Propagator.Solver.AC3

  describe "Set lattice" do
    test "creates set from list" do
      set = Set.new([1, 2, 3])
      assert Set.member?(set, 1)
      assert Set.member?(set, 2)
      assert Set.member?(set, 3)
      refute Set.member?(set, 4)
    end

    test "bottom is empty set" do
      bottom = Set.bottom()
      assert Set.size(bottom) == 0
    end

    test "merge intersects sets" do
      set1 = Set.new([1, 2, 3])
      set2 = Set.new([2, 3, 4])
      result = Set.merge(set1, set2)
      assert Set.to_list(result) |> Enum.sort() == [2, 3]
    end

    test "merge with empty set yields contradiction" do
      set1 = Set.new([1, 2, 3])
      set2 = Set.new([])
      assert Set.merge(set1, set2) == :contradiction
    end

    test "merge disjoint sets yields contradiction" do
      set1 = Set.new([1, 2])
      set2 = Set.new([3, 4])
      assert Set.merge(set1, set2) == :contradiction
    end

    test "size returns domain size" do
      set = Set.new([1, 2, 3, 4, 5])
      assert Set.size(set) == 5
    end

    test "to_list converts to list" do
      set = Set.new([3, 1, 2])
      list = Set.to_list(set) |> Enum.sort()
      assert list == [1, 2, 3]
    end
  end

  describe "AC3 solver" do
    test "solves simple binary constraint problem" do
      # Two variables, X and Y, both with domain {1, 2, 3}
      # Constraint: X < Y
      variables = %{
        x: Set.new([1, 2, 3]),
        y: Set.new([1, 2, 3])
      }

      constraint =
        {[:x, :y], fn assignment ->
          if Map.has_key?(assignment, :x) and Map.has_key?(assignment, :y) do
            assignment.x < assignment.y
          else
            true
          end
        end}

      assert {:ok, solution} = AC3.solve(variables, [constraint])
      assert solution.x < solution.y
    end

    test "detects unsatisfiable constraints" do
      # X and Y must be equal, but from disjoint domains
      variables = %{
        x: Set.new([1, 2]),
        y: Set.new([3, 4])
      }

      constraint =
        {[:x, :y], fn assignment ->
          if Map.has_key?(assignment, :x) and Map.has_key?(assignment, :y) do
            assignment.x == assignment.y
          else
            true
          end
        end}

      assert {:error, :no_solution} = AC3.solve(variables, [constraint])
    end

    test "solves three-variable constraint problem" do
      # X + Y = Z, with limited domains
      variables = %{
        x: Set.new([1, 2]),
        y: Set.new([1, 2]),
        z: Set.new([2, 3, 4])
      }

      constraint =
        {[:x, :y, :z], fn assignment ->
          if map_size(assignment) == 3 do
            assignment.x + assignment.y == assignment.z
          else
            true
          end
        end}

      assert {:ok, solution} = AC3.solve(variables, [constraint])
      assert solution.x + solution.y == solution.z
    end

    test "solves with multiple constraints" do
      # X < Y < Z
      variables = %{
        x: Set.new([1, 2, 3]),
        y: Set.new([1, 2, 3]),
        z: Set.new([1, 2, 3])
      }

      constraint1 =
        {[:x, :y], fn assignment ->
          if Map.has_key?(assignment, :x) and Map.has_key?(assignment, :y) do
            assignment.x < assignment.y
          else
            true
          end
        end}

      constraint2 =
        {[:y, :z], fn assignment ->
          if Map.has_key?(assignment, :y) and Map.has_key?(assignment, :z) do
            assignment.y < assignment.z
          else
            true
          end
        end}

      assert {:ok, solution} = AC3.solve(variables, [constraint1, constraint2])
      assert solution.x < solution.y
      assert solution.y < solution.z
    end

    test "handles alldifferent-style constraints" do
      # All three variables must have different values
      variables = %{
        a: Set.new([1, 2, 3]),
        b: Set.new([1, 2, 3]),
        c: Set.new([1, 2, 3])
      }

      # Pairwise inequality constraints
      neq_ab =
        {[:a, :b], fn assignment ->
          if Map.has_key?(assignment, :a) and Map.has_key?(assignment, :b) do
            assignment.a != assignment.b
          else
            true
          end
        end}

      neq_bc =
        {[:b, :c], fn assignment ->
          if Map.has_key?(assignment, :b) and Map.has_key?(assignment, :c) do
            assignment.b != assignment.c
          else
            true
          end
        end}

      neq_ac =
        {[:a, :c], fn assignment ->
          if Map.has_key?(assignment, :a) and Map.has_key?(assignment, :c) do
            assignment.a != assignment.c
          else
            true
          end
        end}

      assert {:ok, solution} = AC3.solve(variables, [neq_ab, neq_bc, neq_ac])
      assert solution.a != solution.b
      assert solution.b != solution.c
      assert solution.a != solution.c
    end

    test "prunes domains with AC-3" do
      # Test that AC-3 actually prunes before backtracking
      # X ∈ {1,2,3}, Y ∈ {4,5,6}, X + Y = 7
      # Only valid solutions: (1,6), (2,5), (3,4)
      variables = %{
        x: Set.new([1, 2, 3]),
        y: Set.new([4, 5, 6])
      }

      constraint =
        {[:x, :y], fn assignment ->
          if map_size(assignment) == 2 do
            assignment.x + assignment.y == 7
          else
            true
          end
        end}

      assert {:ok, solution} = AC3.solve(variables, [constraint])
      assert solution.x + solution.y == 7
      assert solution.x in [1, 2, 3]
      assert solution.y in [4, 5, 6]
    end
  end
end
