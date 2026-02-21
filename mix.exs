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
      mod: {Propagator.Application, []},
      # :inets ships with Erlang/OTP and provides the TCP stack we use for HTTP
      extra_applications: [:logger, :inets]
    ]
  end

  # No external Hex dependencies — uses Erlang/OTP built-ins only.
  defp deps do
    []
  end
end
