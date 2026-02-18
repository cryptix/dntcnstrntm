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

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {HomeAgent.Application, []}
    ]
  end

  # No external dependencies — all primitives are from Erlang/OTP:
  #   PubSub  → HomeAgent.PubSub  (Registry + GenServer)
  #   JSON    → HomeAgent.Json    (:json_encoder built on term_to_binary patterns)
  #   WS      → HomeAgent.HaClient (gen_tcp + HTTP upgrade)
  defp deps do
    []
  end
end
