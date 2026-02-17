defmodule Propagator.Solver.MiniZinc do
  @moduledoc """
  MiniZinc adapter via the Solverl library.

  Implements the `Solver` behaviour by translating integer-domain variables
  and MiniZinc constraint strings into a MiniZinc model, delegating the
  combinatorial search to MiniZinc's industrial-strength solvers (Gecode,
  OR-Tools, Chuffed, etc.).

  ## Requirements

  1. Add `{:solverl, "~> 0.9"}` to your `mix.exs` deps and run `mix deps.get`.
  2. Install MiniZinc from https://www.minizinc.org/ and ensure `minizinc` is
     on `PATH`.

  ## Constraint format

  Unlike `Solver.AC3`, which accepts `{vars, fun}` Elixir functions, this
  adapter expects constraints tagged as `{:mzn, "constraint_text"}` where the
  constraint text is valid MiniZinc syntax referencing variable names directly.

  Mixed lists are allowed: `{:mzn, "..."}` tuples are compiled into the model;
  `{vars, fun}` Elixir function tuples are applied as a *post-solution filter*
  (useful for constraints that are hard to express in MiniZinc, or for
  cross-checking).

  ## Variable format

  Variables must be MapSets of integers. The adapter infers the tightest
  MiniZinc domain syntax:

  - Contiguous range `{1, 2, 3}` → `var 1..3: x;`
  - Sparse set `{1, 3, 7}` → `var {1, 3, 7}: x;`

  ## Example

      alias Propagator.Lattice.Set
      alias Propagator.Solver.MiniZinc

      variables = %{
        x: Set.new([1, 2, 3]),
        y: Set.new([1, 2, 3])
      }

      constraints = [{:mzn, "x < y"}]

      {:ok, %{x: x, y: y}} = MiniZinc.solve(variables, constraints)
      # x < y guaranteed

  ## Integration with TMS-backed beliefs

  Feed belief-cell values as variable domains and receive solutions as new
  beliefs with justification chains:

      domains = Network.active_domains(network)      # %{var => MapSet}
      {:ok, assignment} = MiniZinc.solve(domains, mzn_constraints)
      Network.assert_beliefs(network, assignment, justification: :solver)

  """

  @behaviour Propagator.Solver

  alias Propagator.Lattice.Set

  @impl true
  def solve(variables, constraints) do
    unless Code.ensure_loaded?(MinizincSolver) do
      raise """
      Solverl is not available. Add the following to your mix.exs deps:

          {:solverl, "~> 0.9"}

      Then run `mix deps.get` and ensure MiniZinc is installed on PATH.
      """
    end

    {mzn_constraints, elixir_constraints} = split_constraints(constraints)
    model = build_model(variables, mzn_constraints)

    case run_solver(model) do
      {:ok, solution} ->
        if valid_with_elixir_constraints?(solution, elixir_constraints) do
          {:ok, solution}
        else
          {:error, :no_solution}
        end

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Model building (public for testing without Solverl installed)
  # ---------------------------------------------------------------------------

  @doc """
  Build a MiniZinc model string from variable domains and MiniZinc constraints.

  Exposed for testing — verifying the generated model text does not require
  Solverl or MiniZinc to be installed.

  ## Parameters

  - `variables` — `%{atom => MapSet}` of integer domains
  - `mzn_constraints` — list of `{:mzn, "constraint_text"}` tuples

  ## Returns

  A string containing a complete, self-contained MiniZinc model.
  """
  def build_model(variables, mzn_constraints) do
    var_decls =
      variables
      |> Enum.sort_by(fn {name, _} -> Atom.to_string(name) end)
      |> Enum.map(fn {name, domain} ->
        values = Set.to_list(domain) |> Enum.sort()
        "var #{domain_syntax(values)}: #{name};"
      end)

    constraint_lines =
      Enum.map(mzn_constraints, fn {:mzn, text} ->
        "constraint #{text};"
      end)

    (var_decls ++ constraint_lines ++ ["solve satisfy;"])
    |> Enum.join("\n")
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Separate {:mzn, "..."} tuples from {vars, fun} Elixir tuples.
  defp split_constraints(constraints) do
    Enum.split_with(constraints, fn
      {:mzn, _text} -> true
      _ -> false
    end)
  end

  # Infer compact MiniZinc domain syntax for a sorted list of integer values.
  defp domain_syntax([]) do
    raise ArgumentError, "variable domain must be non-empty"
  end

  defp domain_syntax(values) do
    min = List.first(values)
    max = List.last(values)

    if values == Enum.to_list(min..max) do
      "#{min}..#{max}"
    else
      "{#{Enum.join(values, ", ")}}"
    end
  end

  # Call MinizincSolver.solve_sync and translate the result.
  defp run_solver(model) do
    results = MinizincSolver.solve_sync({:model_text, model}, %{}, [], [])

    case results do
      %{summary: %{status: status}} when status in [:unsatisfiable, :unknown] ->
        {:error, :no_solution}

      %{solutions: [first | _]} ->
        {:ok, parse_solution(first)}

      %{solutions: []} ->
        {:error, :no_solution}

      _ ->
        {:error, :no_solution}
    end
  end

  # Convert solution data map (string keys) to atom-keyed map.
  defp parse_solution(%{data: data}) do
    Map.new(data, fn {k, v} -> {String.to_atom(k), v} end)
  end

  # Apply any Elixir-function constraints as a post-solution filter.
  defp valid_with_elixir_constraints?(solution, constraints) do
    Enum.all?(constraints, fn {_vars, fun} ->
      try do
        fun.(solution)
      rescue
        _ -> true
      end
    end)
  end
end
