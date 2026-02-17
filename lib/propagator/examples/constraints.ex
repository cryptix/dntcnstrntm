defmodule Propagator.Examples.Constraints do
  @moduledoc """
  Example constraint problems demonstrating the Solver.

  These show typical belief-tracking agent scenarios:
  - Resource allocation (time, attention, energy)
  - Topic selection with caps
  - Scheduling with budget limits
  """

  alias Propagator.Lattice.Set
  alias Propagator.Solver.AC3

  @doc """
  Example: Allocate limited attention across topics.

  Variables: topic assignments (e.g., :coding, :reading, :exercise)
  Domains: hours per day (0..5)
  Constraints:
  - Total hours <= daily_budget
  - Each topic gets at least min_hours if assigned
  - No more than max_topics active simultaneously
  """
  def attention_allocation do
    # Variables: how many hours to spend on each topic
    variables = %{
      coding: Set.new([0, 1, 2, 3, 4, 5]),
      reading: Set.new([0, 1, 2, 3, 4, 5]),
      exercise: Set.new([0, 1, 2, 3, 4, 5]),
      social: Set.new([0, 1, 2, 3, 4, 5])
    }

    # Constraint: total hours <= 8 per day
    total_budget =
      {[:coding, :reading, :exercise, :social], fn assignment ->
        if map_size(assignment) < 4 do
          true
        else
          total = assignment.coding + assignment.reading + assignment.exercise + assignment.social
          total <= 8
        end
      end}

    # Constraint: if you do a topic, spend at least 1 hour on it (no micro-tasks)
    # This is implicitly encoded in the domain (no 0.5 values)

    # Constraint: at most 3 topics active (non-zero) at once
    max_active_topics =
      {[:coding, :reading, :exercise, :social], fn assignment ->
        if map_size(assignment) < 4 do
          true
        else
          active_count =
            assignment
            |> Map.values()
            |> Enum.count(&(&1 > 0))

          active_count <= 3
        end
      end}

    constraints = [total_budget, max_active_topics]

    case AC3.solve(variables, constraints) do
      {:ok, solution} ->
        IO.puts("Attention allocation solution:")
        Enum.each(solution, fn {topic, hours} ->
          IO.puts("  #{topic}: #{hours} hours")
        end)
        {:ok, solution}

      {:error, :no_solution} ->
        IO.puts("No valid attention allocation found.")
        {:error, :no_solution}
    end
  end

  @doc """
  Example: Schedule tasks with dependencies and time windows.

  Variables: start times for tasks
  Domains: time slots (0..5)
  Constraints:
  - Task B must start after Task A finishes (dependencies)
  - Some tasks have deadline constraints
  - Limited resource availability in each time slot
  """
  def task_scheduling do
    # Variables: start time for each task (task_a has duration 2; task_b and task_c have duration 1)
    variables = %{
      task_a: Set.new([0, 1, 2, 3, 4, 5]),
      task_b: Set.new([0, 1, 2, 3, 4, 5]),
      task_c: Set.new([0, 1, 2, 3, 4, 5])
    }

    # Constraint: task_b must start after task_a finishes (task_a takes 2 time units)
    dependency_a_b =
      {[:task_a, :task_b], fn assignment ->
        if Map.has_key?(assignment, :task_a) and Map.has_key?(assignment, :task_b) do
          assignment.task_b >= assignment.task_a + 2
        else
          true
        end
      end}

    # Constraint: task_c must start after task_a finishes
    dependency_a_c =
      {[:task_a, :task_c], fn assignment ->
        if Map.has_key?(assignment, :task_a) and Map.has_key?(assignment, :task_c) do
          assignment.task_c >= assignment.task_a + 2
        else
          true
        end
      end}

    # Constraint: task_b and task_c can't run simultaneously (resource conflict)
    no_overlap_b_c =
      {[:task_b, :task_c], fn assignment ->
        if Map.has_key?(assignment, :task_b) and Map.has_key?(assignment, :task_c) do
          # task_b and task_c each have duration 1, so non-equal start times means no overlap
          assignment.task_b != assignment.task_c
        else
          true
        end
      end}

    constraints = [dependency_a_b, dependency_a_c, no_overlap_b_c]

    case AC3.solve(variables, constraints) do
      {:ok, solution} ->
        IO.puts("\nTask scheduling solution:")
        Enum.each(solution, fn {task, start_time} ->
          IO.puts("  #{task}: starts at t=#{start_time}")
        end)
        {:ok, solution}

      {:error, :no_solution} ->
        IO.puts("No valid schedule found.")
        {:error, :no_solution}
    end
  end

  @doc """
  Example: Resource limits with must-have vs nice-to-have features.

  Variables: which features to include in next sprint
  Domains: {true, false} (binary decision)
  Constraints:
  - Core features must be included
  - Total cost <= budget
  - Some features require others (dependencies)
  """
  def feature_selection do
    # Variables: include feature? (1 = yes, 0 = no)
    variables = %{
      core_auth: Set.new([0, 1]),
      core_db: Set.new([0, 1]),
      nice_ui: Set.new([0, 1]),
      nice_export: Set.new([0, 1])
    }

    # Constraint: core features must be included
    must_have_auth =
      {[:core_auth], fn assignment ->
        if Map.has_key?(assignment, :core_auth) do
          assignment.core_auth == 1
        else
          true
        end
      end}

    must_have_db =
      {[:core_db], fn assignment ->
        if Map.has_key?(assignment, :core_db) do
          assignment.core_db == 1
        else
          true
        end
      end}

    # Constraint: total cost <= 10 points
    # (core_auth=3, core_db=4, nice_ui=2, nice_export=3)
    budget_limit =
      {[:core_auth, :core_db, :nice_ui, :nice_export], fn assignment ->
        if map_size(assignment) < 4 do
          true
        else
          cost =
            assignment.core_auth * 3 +
              assignment.core_db * 4 +
              assignment.nice_ui * 2 +
              assignment.nice_export * 3

          cost <= 10
        end
      end}

    # Constraint: nice_export requires core_db (dependency)
    export_requires_db =
      {[:nice_export, :core_db], fn assignment ->
        if Map.has_key?(assignment, :nice_export) and Map.has_key?(assignment, :core_db) do
          assignment.nice_export == 0 or assignment.core_db == 1
        else
          true
        end
      end}

    constraints = [must_have_auth, must_have_db, budget_limit, export_requires_db]

    case AC3.solve(variables, constraints) do
      {:ok, solution} ->
        IO.puts("\nFeature selection solution:")

        Enum.each(solution, fn {feature, included} ->
          status = if included == 1, do: "✓ INCLUDE", else: "✗ skip"
          IO.puts("  #{feature}: #{status}")
        end)

        {:ok, solution}

      {:error, :no_solution} ->
        IO.puts("No valid feature set found within budget.")
        {:error, :no_solution}
    end
  end

  @doc """
  Run all examples.
  """
  def run_all do
    IO.puts("=== Constraint Solver Examples ===\n")
    attention_allocation()
    task_scheduling()
    feature_selection()
    IO.puts("\n=== All examples complete ===")
  end
end
