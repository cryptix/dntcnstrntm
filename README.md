# Propagator

A constraint propagation network in Elixir/OTP. Cells hold lattice values, propagators wire them together, and information flows in all directions automatically. The long-term goal is a belief-tracking agent that can reason about *why* it believes things and retract gracefully when assumptions break.

Built on ideas from Radul & Sussman's propagator model and Forbus & de Kleer's *Building Problem Solvers*.

## Quick Start

```bash
# Install Erlang/OTP and Elixir (Ubuntu / Debian / apt)
apt-get update && apt-get install -y erlang elixir

# Start the server (runs until you Ctrl-C)
mix run --no-halt
```

Open **http://localhost:4000** — the **Propagator Inspector** loads with a live Room HVAC model. A quick tour launches automatically on your first visit; you can relaunch it any time via the **? tour** button in the header.

**Try it:**

1. **Assert a sensor value** — pick a cell in the footer, enter a number (e.g. set `temperature_c` to `30`), click *Assert*. Watch derived cells (like `comfort_index`) and actuators update instantly.
2. **Click a cell** in the left panel to expand its belief list and see which sources are `:in` or `:out` in the JTMS.
3. **Add a hypothesis** — click *+ Hypothesis*, explore downstream effects, then *Discard all* to roll back the entire belief chain automatically.

For an interactive Elixir session:

```bash
iex -S mix      # REPL with the application loaded
mix test        # Run the full test suite
```

## Roadmap

### Phase 1: Cells & Propagators
The foundation. Cells are GenServers holding lattice values; propagators subscribe to cells and push derived values when inputs change. A `Lattice` behaviour makes cells polymorphic over value types.

- [x] `Lattice` behaviour with `merge/2`, `bottom/0`, `top/0`
- [x] `Number` lattice with contradiction detection
- [x] `Cell` GenServer — `read/1`, `add_content/2`, subscriber notifications
- [x] `Propagator` — subscribes to inputs, runs function, writes to outputs
- [x] `adder/3` and `multiplier/3` with bidirectional inference
- [x] Fahrenheit/Celsius converter (bidirectional, the classic test)
- [ ] Additional lattice types (booleans, intervals, sets with union)

### Phase 2: JTMS (Belief Tracking)
A Truth Maintenance System as its own GenServer. Nodes carry `:in`/`:out` labels and point to justifications `{informant, antecedents}`. Supports non-monotonic reasoning — believing X because Y is *out*.

- [x] JTMS GenServer with node/justification graph
- [x] `justify_node/3`, `assume_node/1`, `retract_assumption/1`
- [x] Label propagation (`:in` → check consequences, `:out` → check dependents)
- [x] Non-monotonic justifications (out-list support)

### Phase 3: TMS-backed Cells
Connect belief tracking to the propagator network. Cells hold `{value, node_ref}` pairs so every derived value carries a dependency chain. Retracting an assumption automatically "forgets" downstream values.

**Design note — the monotonicity tension.** Lattice cells only merge upward (values grow, never shrink). But real beliefs change: you stop caring about a topic, a source becomes unreliable. This phase has to resolve that tension head-on. The approach: `BeliefCell` does *not* use the lattice merge for its primary value. Instead it holds a set of `{value, tms_node}` pairs. The "current" value is derived from whichever pairs have their TMS node `:in`. When a belief is retracted, the pair's node goes `:out` and the value simply disappears from the active set — no downward merge needed. If all pairs go `:out`, the cell reverts to `:nothing`. This sidesteps the monotonicity conflict rather than fighting it.

**Design note — process topology.** Phases 1–2 use one GenServer per cell and one spawned process per propagator. That's clean for learning, but Phase 3 doubles the process count (TMS + cells + propagators). At hundreds of cells the message-passing overhead will thrash with cascading notifications before settling. The pragmatic fix: introduce a `Network` GenServer that holds all cells and propagators in plain maps, running the core propagation loop in a single process with in-memory data structures. The public API (`Cell.new/1`, `Cell.read/1`, etc.) stays the same. Reserve separate OTP processes for the outer agent layer only (perception, action, the BDI cycle in Phase 5). This sacrifices architectural purity but actually works at scale.

- [x] Consolidate cells + propagators behind a single `Network` GenServer
- [x] `BeliefCell` — cell content as `{value, tms_node}` pairs, active set derived from TMS labels
- [x] Propagators create JTMS justifications alongside values
- [x] Retraction cascades through network via TMS `:out` labels
- [x] Dependency-directed backtracking

### Phase 4: Constraint Solver
Define a `Solver` behaviour so the solving strategy is pluggable. Build AC-3 behind it as a learning exercise (~30 lines), then move on. A hand-rolled backtracker with AC-3 falls over at ~50 variables or with global constraints (alldifferent, cumulative scheduling). The production path is Solverl bridging to MiniZinc — model constraints declaratively, MiniZinc compiles to Gecode/OR-Tools/Chuffed, and you get industrial-strength propagation and search for free. This split clarifies the architecture: OTP handles the reactive belief layer, the external solver handles combinatorial search.

The novel and interesting part is the *integration* — TMS-backed beliefs feeding constraints to a solver, with results flowing back as new beliefs carrying justification chains. That's where time is best spent.

- [x] `Solver` behaviour with `solve/1` returning assignments
- [x] Set-domain lattice type
- [x] AC-3 arc consistency (~30 lines: queue arcs, prune unsupported values, re-enqueue)
- [x] `Solver.AC3` — learning implementation behind the behaviour
- [x] Backtracking search over domain assignments
- [x] Example constraints: resource limits, topic caps, time budgets
- [ ] (Stretch) Solverl/MiniZinc adapter behind the same `Solver` behaviour

### Phase 5: Agent Loop
A BDI (Belief-Desire-Intention) cycle wired to the propagator network.

**Design note — JTMS is single-context.** The JTMS maintains one coherent worldview at a time. To compare "what if I pursue interest A vs B," you retract/reassert assumptions and wait for re-propagation each time. An ATMS handles multiple contexts simultaneously but is substantially harder to implement and the label management gets expensive. For this project, JTMS + retract/reassert is sufficient. If you hit the ceiling, consider snapshot/restore of the JTMS state before reaching for a full ATMS.

- [ ] **Perceive** — ingest external info as TMS assumptions
- [ ] **Propagate** — let the network settle to fixpoint
- [ ] **Deliberate** — call `Solver` to select goals
- [ ] **Act** — spawn supervised tasks to pursue goals
- [ ] **Reflect** — retract weakest assumptions on contradiction
- [ ] Interactive interface (LiveView or CLI) for querying beliefs

## Design Decisions

A record of known trade-offs, so future contributors understand why things are the way they are.

| Decision | Trade-off | Revisit when… |
|---|---|---|
| JTMS, not ATMS | Single worldview; must retract/reassert to compare alternatives | The agent loop needs simultaneous "what-if" comparison and snapshot/restore is too slow |
| `Network` GenServer (Phase 3) | Loses one-process-per-cell elegance; gains throughput | You need cells distributed across nodes, or fault-isolation per cell matters |
| `Solver` behaviour (Phase 4) | AC-3 for learning, external solver for production | Never — the behaviour abstraction costs nothing and keeps options open |
| `BeliefCell` as `{value, tms_node}` pairs | Sidesteps monotonicity; active set is a derived view | You need true lattice merge semantics on belief values (unlikely) |

## References

- Radul, *Propagation Networks* (MIT thesis)
- Forbus & de Kleer, [*Building Problem Solvers*](https://qrg.northwestern.edu/BPS/readme.html) — Ch. 6 for JTMS
- [Solverl](https://github.com/bokner/solverl) — Elixir bridge to MiniZinc

## Installation

To run locally:

```bash
apt-get update && apt-get install -y erlang elixir
mix run --no-halt   # start server → open http://localhost:4000
mix test            # run the test suite
iex -S mix          # interactive REPL with the app loaded
```

To add as a library dependency (once published to Hex):

```elixir
def deps do
  [{:propagator, "~> 0.1.0"}]
end
```
