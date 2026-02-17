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

  Each constraint must be a `{vars, fun}` tuple where `vars` is the list of variable
  names the constraint involves, and `fun` is a function taking an assignment map.
  """
  def enforce_ac3(domains, constraints) do
    arcs = build_arc_queue(constraints)
    process_arcs(arcs, domains, constraints)
  end

  # Build the initial arc queue using only the variables each constraint declares.
  # A constraint {[x, y], fun} produces arcs {x, y, constraint} and {y, x, constraint}.
  # This avoids the O(N²) explosion of creating arcs for every variable pair.
  defp build_arc_queue(constraints) do
    Enum.flat_map(constraints, fn {vars, _fun} = constraint ->
      for x <- vars, y <- vars, x != y do
        {x, y, constraint}
      end
    end)
  end

  # Process arcs until fixpoint or contradiction
  defp process_arcs([], domains, _constraints), do: {:ok, domains}

  defp process_arcs([{x, y, constraint} | rest], domains, constraints) do
    case revise(domains, x, y, constraint) do
      {:unchanged, _} ->
        process_arcs(rest, domains, constraints)

      {:revised, new_domains} ->
        if MapSet.size(new_domains[x]) == 0 do
          {:error, :no_solution}
        else
          # Re-enqueue arcs: for every constraint that involves x, add (z, x, c)
          # for each other variable z in that constraint (except y).
          new_arcs =
            for {vars, _fun} = c <- constraints,
                x in vars,
                z <- vars,
                z != x,
                z != y,
                do: {z, x, c}

          process_arcs(rest ++ new_arcs, new_domains, constraints)
        end
    end
  end

  # Revise domain of X by removing values that have no support in Y's domain
  defp revise(domains, x, y, constraint) do
    domain_x = domains[x]
    domain_y = domains[y]

    new_domain_x =
      domain_x
      |> Set.to_list()
      |> Enum.filter(fn vx ->
        Enum.any?(Set.to_list(domain_y), fn vy ->
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
  defp satisfies_constraint?({_vars, fun}, assignment) do
    try do
      fun.(assignment)
    rescue
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
    Enum.all?(constraints, fn {_vars, fun} ->
      try do
        fun.(assignment)
      rescue
        _ -> true
      end
    end)
  end
end
