defmodule Propagator.MixProject do
  use Mix.Project

  def project do
    [
      app: :propagator,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Uncomment to enable Solver.MiniZinc (also requires MiniZinc on PATH).
      # See lib/propagator/solver/minizinc.ex for details.
      # {:solverl, "~> 0.9"}
    ]
  end
end
