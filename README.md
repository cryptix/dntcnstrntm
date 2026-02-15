# Propagator

A constraint propagation network in Elixir/OTP. Cells hold lattice values, propagators wire them together, and information flows in all directions automatically. The long-term goal is a belief-tracking agent that can reason about *why* it believes things and retract gracefully when assumptions break.

Built on ideas from Radul & Sussman's propagator model and Forbus & de Kleer's *Building Problem Solvers*.

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

- [ ] JTMS GenServer with node/justification graph
- [ ] `justify_node/3`, `assume_node/1`, `retract_assumption/1`
- [ ] Label propagation (`:in` → check consequences, `:out` → check dependents)
- [ ] Non-monotonic justifications (out-list support)

### Phase 3: TMS-backed Cells
Connect belief tracking to the propagator network. Cells hold `{value, node_ref}` pairs so every derived value carries a dependency chain. Retracting an assumption automatically "forgets" downstream values.

- [ ] `BeliefCell` — cell content tagged with TMS node references
- [ ] Propagators create JTMS justifications alongside values
- [ ] Retraction cascades through network via TMS `:out` labels
- [ ] Dependency-directed backtracking

### Phase 4: Constraint Solver
Lightweight backtracking + AC-3 arc consistency. Variables are cells with set-valued domains; constraints are propagators that prune domains.

- [ ] Set-domain lattice type
- [ ] AC-3 arc consistency (~30 lines: queue arcs, prune unsupported values, re-enqueue)
- [ ] Backtracking search over domain assignments
- [ ] Example constraints: resource limits, topic caps, time budgets

### Phase 5: Agent Loop
A BDI (Belief-Desire-Intention) cycle wired to the propagator network.

- [ ] **Perceive** — ingest external info as TMS assumptions
- [ ] **Propagate** — let the network settle to fixpoint
- [ ] **Deliberate** — run constraint solver to select goals
- [ ] **Act** — spawn supervised tasks to pursue goals
- [ ] **Reflect** — retract weakest assumptions on contradiction
- [ ] Interactive interface (LiveView or CLI) for querying beliefs

## References

- Radul, *Propagation Networks* (MIT thesis)
- Forbus & de Kleer, [*Building Problem Solvers*](https://qrg.northwestern.edu/BPS/readme.html) — Ch. 6 for JTMS

## Installation

```elixir
def deps do
  [
    {:propagator, "~> 0.1.0"}
  ]
end
```
