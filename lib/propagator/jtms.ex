defmodule Propagator.JTMS do
  @moduledoc """
  A Justification-based Truth Maintenance System (JTMS).

  Nodes carry `:in` or `:out` labels and are connected by justifications.
  A justification `{informant, in_list, out_list}` says: believe this node
  because of `informant`, provided every node in `in_list` is `:in` and every
  node in `out_list` is `:out`.

  Supports non-monotonic reasoning via out-lists — believing X because Y
  is *out* (default reasoning, closed-world assumptions, etc.).

  Based on Forbus & de Kleer, *Building Problem Solvers*, Chapter 6.
  """

  use GenServer

  # --- Data structures (internal) ---

  defmodule Justification do
    @moduledoc false
    defstruct [:informant, in_list: [], out_list: []]
  end

  # --- Public API ---

  @doc "Start a new JTMS."
  def new do
    GenServer.start_link(__MODULE__, [])
  end

  @doc "Create a node in the JTMS. Nodes start with label `:out`."
  def create_node(jtms, name) do
    GenServer.call(jtms, {:create_node, name})
  end

  @doc """
  Add a justification for `node`: believe it because of `informant`,
  given that every node in `in_list` is `:in` and every node in `out_list`
  is `:out`. Triggers label propagation.
  """
  def justify_node(jtms, node, informant, in_list, out_list \\ []) do
    GenServer.call(jtms, {:justify_node, node, informant, in_list, out_list})
  end

  @doc "Mark `node` as an assumption (immediately `:in`, retractable)."
  def assume_node(jtms, node) do
    GenServer.call(jtms, {:assume_node, node})
  end

  @doc "Retract `node` as an assumption. It may stay `:in` if other justifications support it."
  def retract_assumption(jtms, node) do
    GenServer.call(jtms, {:retract_assumption, node})
  end

  @doc "Return the current label (`:in` or `:out`) of `node`."
  def node_label(jtms, node) do
    GenServer.call(jtms, {:node_label, node})
  end

  @doc "Is this node believed?"
  def node_in?(jtms, node), do: node_label(jtms, node) == :in

  @doc "Is this node not believed?"
  def node_out?(jtms, node), do: node_label(jtms, node) == :out

  @doc "Return the supporting justification for an `:in` node, or `nil`."
  def why(jtms, node) do
    GenServer.call(jtms, {:why, node})
  end

  @doc "Is this node an assumption?"
  def assumption?(jtms, node) do
    GenServer.call(jtms, {:assumption?, node})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    {:ok, %{nodes: %{}}}
  end

  @impl true
  def handle_call({:create_node, name}, _from, state) do
    if Map.has_key?(state.nodes, name) do
      {:reply, :ok, state}
    else
      node = %{
        name: name,
        label: :out,
        justifications: [],
        support: nil,
        assumption: false,
        consequences: MapSet.new()
      }

      {:reply, :ok, %{state | nodes: Map.put(state.nodes, name, node)}}
    end
  end

  def handle_call({:justify_node, node_name, informant, in_list, out_list}, _from, state) do
    just = %Justification{informant: informant, in_list: in_list, out_list: out_list}

    # Add justification to the node
    state = update_in(state, [:nodes, node_name, :justifications], &[just | &1])

    # Register this node as a consequence of every antecedent
    state = register_consequences(state, node_name, in_list ++ out_list)

    # Propagate — the new justification might make this node (and others) :in
    state = propagate(state, [node_name])

    {:reply, :ok, state}
  end

  def handle_call({:assume_node, node_name}, _from, state) do
    just = %Justification{informant: :assumption, in_list: [], out_list: []}

    state =
      state
      |> put_in([:nodes, node_name, :assumption], true)
      |> update_in([:nodes, node_name, :justifications], &[just | &1])

    state = propagate(state, [node_name])

    {:reply, :ok, state}
  end

  def handle_call({:retract_assumption, node_name}, _from, state) do
    state =
      state
      |> put_in([:nodes, node_name, :assumption], false)
      |> update_in([:nodes, node_name, :justifications], fn justs ->
        Enum.reject(justs, &(&1.informant == :assumption))
      end)

    state = propagate(state, [node_name])

    {:reply, :ok, state}
  end

  def handle_call({:node_label, node_name}, _from, state) do
    {:reply, state.nodes[node_name].label, state}
  end

  def handle_call({:why, node_name}, _from, state) do
    {:reply, state.nodes[node_name].support, state}
  end

  def handle_call({:assumption?, node_name}, _from, state) do
    {:reply, state.nodes[node_name].assumption, state}
  end

  # --- Propagation engine ---

  defp register_consequences(state, node_name, antecedents) do
    Enum.reduce(antecedents, state, fn ant, acc ->
      update_in(acc, [:nodes, ant, :consequences], &MapSet.put(&1, node_name))
    end)
  end

  # BFS propagation: re-evaluate each node in the worklist; if its label
  # changed, enqueue all its consequences. Converges because a label can
  # only flip once per wavefront in a well-formed JTMS.
  defp propagate(state, start_nodes) do
    queue = :queue.from_list(start_nodes)
    propagate_loop(state, queue)
  end

  defp propagate_loop(state, queue) do
    case :queue.out(queue) do
      {:empty, _} ->
        state

      {{:value, node_name}, rest} ->
        node = state.nodes[node_name]
        {new_label, support} = compute_label(state, node)

        if new_label != node.label do
          state =
            state
            |> put_in([:nodes, node_name, :label], new_label)
            |> put_in([:nodes, node_name, :support], support)

          # Enqueue all consequences for re-evaluation
          rest =
            node.consequences
            |> MapSet.to_list()
            |> Enum.reduce(rest, fn c, q -> :queue.in(c, q) end)

          propagate_loop(state, rest)
        else
          propagate_loop(state, rest)
        end
    end
  end

  # A node is :in if at least one justification is valid.
  defp compute_label(state, node) do
    case Enum.find(node.justifications, &justification_valid?(state, &1)) do
      nil -> {:out, nil}
      just -> {:in, just}
    end
  end

  defp justification_valid?(state, %Justification{in_list: ins, out_list: outs}) do
    Enum.all?(ins, fn n -> state.nodes[n].label == :in end) and
      Enum.all?(outs, fn n -> state.nodes[n].label == :out end)
  end
end
