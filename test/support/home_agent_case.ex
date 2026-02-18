defmodule HomeAgent.Case do
  @moduledoc """
  ExUnit case template for HomeAgent integration tests.

  Starts the shared infrastructure (PubSub, CellRegistry, StateStore) once
  per test run in an idempotent way, so individual test modules do not need
  to repeat the boilerplate `setup` block.

  Usage:

      defmodule MyTest do
        use HomeAgent.Case, async: false
        ...
      end

  All tests using this template must be `async: false` because they share
  global state (Application config, ETS tables, Registry names).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias HomeAgent.{StateStore, VirtualRoom}
      import HomeAgent.Case
    end
  end

  setup _tags do
    start_infra()
    :ok
  end

  @doc """
  Start all shared GenServers required by HomeAgent tests.
  Safe to call multiple times — already-started processes are ignored.
  """
  def start_infra do
    for {mod, opts} <- [
          {HomeAgent.PubSub, [name: HomeAgent.PubSub]},
          {HomeAgent.StateStore, []},
          {Registry, [keys: :unique, name: HomeAgent.CellRegistry]}
        ] do
      case mod.start_link(opts) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end

    :ok
  end
end
