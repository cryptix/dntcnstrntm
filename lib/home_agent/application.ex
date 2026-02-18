defmodule HomeAgent.Application do
  @moduledoc """
  OTP Application for the home automation reasoning agent.

  Supervision tree (startup order):
    1. HomeAgent.PubSub          — in-process event bus (Registry-backed)
    2. Registry (CellRegistry)   — named registry for propagator cells
    3. HomeAgent.StateStore       — ETS-backed entity state cache
    4. HomeAgent.HaClient         — WebSocket connection to Home Assistant
    5. HomeAgent.Propagator.Circadian     — clock → circadian ticks
    6. HomeAgent.Datalog.FactGenerator   — periodic Soufflé fact writer
    7. HomeAgent.Datalog.Reconciler      — feeds derived facts back into PubSub
    8. HomeAgent.LightingController      — confidence-aware light actuator
    9. DynamicSupervisor                 — per-room PresenceFusion propagators
  """

  use Application

  @impl true
  def start(_type, _args) do
    rooms = Application.get_env(:home_agent, :rooms, %{})

    children = [
      {HomeAgent.PubSub, name: HomeAgent.PubSub},
      {Registry, keys: :unique, name: HomeAgent.CellRegistry},
      HomeAgent.StateStore,
      ha_client_spec(),
      HomeAgent.Propagator.Circadian,
      HomeAgent.Datalog.FactGenerator,
      HomeAgent.Datalog.Reconciler,
      HomeAgent.LightingController,
      {DynamicSupervisor, name: HomeAgent.RoomSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: HomeAgent.Supervisor]
    {:ok, sup} = Supervisor.start_link(children, opts)

    # Start per-room PresenceFusion under the DynamicSupervisor
    Enum.each(rooms, fn {room, _config} ->
      DynamicSupervisor.start_child(
        HomeAgent.RoomSupervisor,
        {HomeAgent.Propagator.PresenceFusion, room}
      )
    end)

    {:ok, sup}
  end

  defp ha_client_spec do
    host = Application.get_env(:home_agent, :ha_host, "homeassistant.local")
    port = Application.get_env(:home_agent, :ha_port, 8123)
    token = Application.get_env(:home_agent, :ha_token, "")

    %{
      id: HomeAgent.HaClient,
      start: {HomeAgent.HaClient, :start_link, [[host: host, port: port, token: token]]},
      restart: :permanent,
      type: :worker
    }
  end
end
