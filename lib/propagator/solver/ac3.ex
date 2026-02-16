defmodule Propagator.Solver.AC3 do
  @moduledoc """
  AC-3 arc consistency algorithm with backtracking search.

  A learning implementation — simple, ~100 lines total, good for understanding
  the algorithm. For production CSPs with >50 variables or global constraints,
  delegate to MiniZinc via Solverl instead.

  AC-3 enforces arc consistency: for every constraint between variables X and Y,
  every value in X's domain has at least one supporting value in Y's domain.
  Prune unsupported values until fixpoint.

  Then backtrack through domain assignments to find a solution.
  """

  @behaviour Propagator.Solver
  alias Propagator.Lattice.Set

  @impl true
  def solve(variables, constraints) do
    # Start with arc consistency
    case enforce_ac3(variables, constraints) do
      {:ok, pruned_domains} ->
        # Then backtrack to find a complete assignment
        backtrack(pruned_domains, constraints, %{})

      {:error, :no_solution} ->
        {:error, :no_solution}
    end
  end

  # --- AC-3 Algorithm ---

  @doc """
  Enforce arc consistency on the variable domains.

  Returns `{:ok, pruned_domains}` or `{:error, :no_solution}` if a domain becomes empty.
  """
  def enforce_ac3(domains, constraints) do
    # Build initial arc queue: for each constraint, add arcs in both directions
    arcs = build_arc_queue(domains, constraints)
    process_arcs(arcs, domains, constraints)
  end

  # Build queue of arcs (var_x, var_y, constraint) for all binary constraints
  defp build_arc_queue(domains, constraints) do
    var_names = Map.keys(domains)

    Enum.flat_map(constraints, fn constraint ->
      # For each pair of variables, add bidirectional arcs
      for x <- var_names, y <- var_names, x != y do
        {x, y, constraint}
      end
    end)
  end

  # Process arcs until fixpoint or contradiction
  defp process_arcs([], domains, _constraints), do: {:ok, domains}

  defp process_arcs([{x, y, constraint} | rest], domains, constraints) do
    case revise(domains, x, y, constraint) do
      {:unchanged, _} ->
        # No change, continue with remaining arcs
        process_arcs(rest, domains, constraints)

      {:revised, new_domains} ->
        # Domain of X was pruned
        if MapSet.size(new_domains[x]) == 0 do
          # Empty domain = no solution
          {:error, :no_solution}
        else
          # Re-enqueue arcs: for all neighbors Z of X (except Y), add (Z, X, constraint)
          var_names = Map.keys(domains)
          new_arcs = for z <- var_names, z != x, z != y, do: {z, x, constraint}

          process_arcs(rest ++ new_arcs, new_domains, constraints)
        end
    end
  end

  # Revise domain of X by removing values that have no support in Y's domain
  defp revise(domains, x, y, constraint) do
    domain_x = domains[x]
    domain_y = domains[y]

    # Keep only values in X that have at least one supporting value in Y
    new_domain_x =
      domain_x
      |> Set.to_list()
      |> Enum.filter(fn vx ->
        Enum.any?(Set.to_list(domain_y), fn vy ->
          # Test if assignment {x => vx, y => vy} satisfies the constraint
          satisfies_constraint?(constraint, %{x => vx, y => vy})
        end)
      end)
      |> Set.new()

    if MapSet.equal?(domain_x, new_domain_x) do
      {:unchanged, domains}
    else
      {:revised, Map.put(domains, x, new_domain_x)}
    end
  end

  # Check if a partial assignment satisfies a constraint
  defp satisfies_constraint?(constraint, assignment) do
    # Constraint is a function that takes an assignment and returns true/false
    # If the constraint references variables not in the assignment, treat as satisfied
    # (we can't check yet)
    try do
      constraint.(assignment)
    rescue
      # If constraint can't be evaluated (missing vars), assume satisfied for now
      _ -> true
    end
  end

  # --- Backtracking Search ---

  @doc """
  Backtracking search to find a complete assignment.

  Returns `{:ok, assignment}` or `{:error, :no_solution}`.
  """
  def backtrack(domains, constraints, assignment) do
    if assignment_complete?(domains, assignment) do
      # All variables assigned
      {:ok, assignment}
    else
      # Pick next unassigned variable (use minimum remaining values heuristic)
      var = select_unassigned_variable(domains, assignment)
      domain = domains[var]

      # Try each value in the domain
      try_values(Set.to_list(domain), var, domains, constraints, assignment)
    end
  end

  defp try_values([], _var, _domains, _constraints, _assignment) do
    # No values left to try
    {:error, :no_solution}
  end

  defp try_values([value | rest], var, domains, constraints, assignment) do
    new_assignment = Map.put(assignment, var, value)

    if consistent?(new_assignment, constraints) do
      case backtrack(domains, constraints, new_assignment) do
        {:ok, solution} ->
          {:ok, solution}

        {:error, :no_solution} ->
          # This value didn't work, try next
          try_values(rest, var, domains, constraints, assignment)
      end
    else
      # Assignment violates constraints, try next value
      try_values(rest, var, domains, constraints, assignment)
    end
  end

  defp assignment_complete?(domains, assignment) do
    map_size(assignment) == map_size(domains)
  end

  # Select unassigned variable with smallest domain (MRV heuristic)
  defp select_unassigned_variable(domains, assignment) do
    domains
    |> Enum.reject(fn {var, _domain} -> Map.has_key?(assignment, var) end)
    |> Enum.min_by(fn {_var, domain} -> MapSet.size(domain) end)
    |> elem(0)
  end

  # Check if assignment is consistent with all constraints
  defp consistent?(assignment, constraints) do
    Enum.all?(constraints, fn constraint ->
      try do
        constraint.(assignment)
      rescue
        # If we can't evaluate (missing vars), treat as consistent for now
        _ -> true
      end
    end)
  end
end
