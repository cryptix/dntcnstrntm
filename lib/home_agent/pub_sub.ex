defmodule HomeAgent.PubSub do
  @moduledoc """
  Minimal in-process pub/sub backed by a Registry and ETS.

  Mirrors the Phoenix.PubSub API (`subscribe/2`, `broadcast/3`) so the
  rest of the codebase can be trivially migrated to Phoenix.PubSub once
  external packages are available.

  Each topic is stored as a key in the `:home_agent_pubsub` Registry.
  Subscribers register under `{HomeAgent.PubSub, topic}`.  Broadcast
  sends the message to all registered pids.
  """

  use Supervisor

  # --- Supervisor API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, name, name: name)
  end

  @impl Supervisor
  def init(name) do
    children = [
      {Registry, keys: :duplicate, name: registry_name(name)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # --- Public API ---

  @doc "Subscribe the calling process to a topic."
  def subscribe(pubsub \\ __MODULE__, topic) do
    Registry.register(registry_name(pubsub), topic, nil)
    :ok
  end

  @doc "Broadcast a message to all subscribers of a topic."
  def broadcast(pubsub \\ __MODULE__, topic, message) do
    Registry.dispatch(registry_name(pubsub), topic, fn entries ->
      for {pid, _value} <- entries, do: send(pid, message)
    end)

    :ok
  end

  defp registry_name(name), do: :"#{name}.Registry"
end
