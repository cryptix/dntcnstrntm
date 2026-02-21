defmodule Propagator.Domain.ValueInterface do
  @moduledoc """
  Behaviour for domain-specific constraint networks.

  A domain (e.g. Room, Garden, Circuit) exposes named sensors, actuators,
  and computed cells. Implementations wrap a `Propagator.Network` with
  domain-meaningful names and pre-wired propagator rules.

  The abstraction lets the UI and inspector work with any domain without
  knowing its internals. Swap `Room` for `Garden` or `Circuit` and the
  same interrogation UI applies.

  ## Cell types

  - `:sensor`   — external input; set by callers with `set/4`
  - `:actuator` — derived output; reflects rule conclusions
  - `:derived`  — intermediate computed value (neither raw input nor final output)
  """

  @type cell_name :: atom()
  @type cell_type :: :sensor | :actuator | :derived
  @type source :: atom()
  @type value :: number() | boolean() | :nothing | :contradiction

  @type cell_spec :: %{
    name: cell_name(),
    type: cell_type(),
    description: String.t(),
    unit: String.t() | nil
  }

  @type rule_spec :: %{
    name: atom(),
    description: String.t(),
    inputs: [cell_name()],
    outputs: [cell_name()]
  }

  @doc "Return specs for all cells in this domain."
  @callback cell_specs() :: [cell_spec()]

  @doc "Return specs for all rules (propagators) in this domain."
  @callback rule_specs() :: [rule_spec()]

  @doc "Start the domain; returns a domain instance (opaque term)."
  @callback new() :: {:ok, term()} | {:error, term()}

  @doc "Read the active value of a named cell."
  @callback read(domain :: term(), cell_name()) :: value()

  @doc "Assert a value for a named sensor cell from a named source."
  @callback set(domain :: term(), cell_name(), value(), source()) :: :ok | {:error, term()}

  @doc "Retract all beliefs from a named source in a named cell."
  @callback retract(domain :: term(), cell_name(), source()) :: :ok | {:error, term()}

  @doc "Get the underlying Network PID for low-level inspection."
  @callback network(domain :: term()) :: pid()

  @doc "Get a map of cell_name => cell_id for this domain."
  @callback cell_ids(domain :: term()) :: %{cell_name() => pos_integer()}
end
