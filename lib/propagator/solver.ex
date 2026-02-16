defmodule Propagator.Solver do
  @moduledoc """
  A behaviour for constraint solvers.

  Phase 4: pluggable solving strategy. Implementations can be simple (AC-3 + backtracking)
  or delegate to external industrial-strength solvers (MiniZinc via Solverl).

  The interesting part isn't the CSP algorithm itself — it's the *integration* with
  TMS-backed beliefs, feeding constraints to the solver and flowing results back
  as new beliefs with justification chains.
  """

  @doc """
  Solve a constraint satisfaction problem.

  ## Parameters
  - `variables` — map of `%{var_name => domain}` where domain is a set of possible values
  - `constraints` — list of constraint functions, each taking an assignment map
                    and returning `true` if satisfied

  ## Returns
  - `{:ok, assignment}` — a map of `%{var_name => value}` satisfying all constraints
  - `{:error, :no_solution}` — if no assignment satisfies the constraints
  """
  @callback solve(variables :: map(), constraints :: list()) ::
              {:ok, map()} | {:error, :no_solution}
end
