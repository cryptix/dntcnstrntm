defmodule Propagator.Application do
  @moduledoc """
  OTP Application entry point.

  Starts:
    1. `Propagator.UI.RoomServer` — the Room domain (Network + JTMS + rules)
    2. `Propagator.UI.HttpServer` — zero-dep HTTP server on port 4000

  Visit http://localhost:4000 to open the model-interrogation UI.

  The UI allows you to:
    - Inspect current cell values, beliefs, and JTMS justifications
    - Assert sensor values and watch constraints propagate in real time
    - Retract beliefs and observe the JTMS cascade
    - Try hypothetical values in hypothesis mode and discard them cleanly
    - Monitor the event log to understand backtracking and belief revision
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      Propagator.UI.RoomServer,
      Propagator.UI.HttpServer
    ]

    opts = [strategy: :one_for_one, name: Propagator.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
