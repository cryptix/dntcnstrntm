defmodule HomeAgent.Propagator.Circadian do
  @moduledoc """
  GenServer that polls the wall clock every minute and broadcasts the
  current time period and circadian lighting target via PubSub.

  Topic: `"circadian"` — message: `{:circadian_tick, period, kelvin, max_brightness}`

  Consumers (LightingController, FactGenerator) subscribe to this topic
  so they always have fresh time context without polling DateTime themselves.
  """

  use GenServer

  alias HomeAgent.Propagator.TimePeriod

  @tick_ms 60_000

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Read the current circadian state synchronously."
  def current do
    GenServer.call(__MODULE__, :current)
  end

  @impl true
  def init([]) do
    state = compute()
    schedule_tick()
    {:ok, state}
  end

  @impl true
  def handle_call(:current, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:tick, _old_state) do
    state = compute()
    HomeAgent.PubSub.broadcast(HomeAgent.PubSub, "circadian", {:circadian_tick, state.period, state.kelvin, state.brightness})
    schedule_tick()
    {:noreply, state}
  end

  defp compute do
    now = DateTime.utc_now()
    period = TimePeriod.period_for(now)
    {kelvin, brightness} = TimePeriod.circadian_at(now)
    %{period: period, kelvin: kelvin, brightness: brightness}
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_ms)
  end
end
