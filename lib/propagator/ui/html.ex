defmodule Propagator.UI.Html do
  @moduledoc """
  Inline HTML/CSS/JS for the model-interrogation UI.

  Returns a single self-contained HTML string — no CDN, no build step.

  Features
  --------
  - **Cells panel** — live values, status badges, per-cell belief lists
  - **Network graph** — SVG showing cells (layered: sensors → derived → actuators)
    with propagator edges; click a cell to see its beliefs
  - **Event log** — scrolling timeline of belief additions, retractions,
    and cell-value changes; newest first
  - **Backtracking view** — collapsible history of state snapshots; each
    mutation creates an entry so you can compare before/after
  - **Hypothesis mode** — assert tentative beliefs tagged `:hypothesis`,
    inspect downstream effects, then commit or discard them all at once
  - **Assert / Retract controls** — form to push sensor values or retract
    beliefs by source name
  - Polls `/api/state` every 800 ms; event log polls `/api/events` with
    incremental `?since=N` to avoid re-showing old entries.
  """

  def page do
    ~S"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Propagator Inspector</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  :root {
    --bg: #0f1117;
    --surface: #1a1d27;
    --surface2: #22263a;
    --border: #2d3250;
    --text: #e2e8f0;
    --muted: #7c88a8;
    --green: #22c55e;
    --yellow: #f59e0b;
    --red: #ef4444;
    --blue: #3b82f6;
    --purple: #a855f7;
    --cyan: #06b6d4;
    --ok-bg: #14532d44;
    --nothing-bg: #78350f44;
    --contradiction-bg: #7f1d1d44;
    --sensor-color: #3b82f6;
    --derived-color: #a855f7;
    --actuator-color: #22c55e;
  }

  body {
    font-family: 'JetBrains Mono', 'Fira Code', 'Cascadia Code', monospace;
    font-size: 12px;
    background: var(--bg);
    color: var(--text);
    height: 100vh;
    display: grid;
    grid-template-rows: 44px 1fr 220px;
    overflow: hidden;
  }

  /* ── Header ── */
  header {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 0 16px;
    border-bottom: 1px solid var(--border);
    background: var(--surface);
    flex-shrink: 0;
  }
  header h1 { font-size: 14px; font-weight: 700; color: var(--cyan); }
  #domain-badge {
    font-size: 10px;
    padding: 2px 8px;
    border-radius: 99px;
    background: var(--blue);
    color: white;
  }
  #status-dot {
    width: 8px; height: 8px;
    border-radius: 50%;
    background: var(--green);
    margin-left: auto;
    transition: background 0.3s;
  }
  #status-dot.stale { background: var(--yellow); }

  /* ── Main grid ── */
  main {
    display: grid;
    grid-template-columns: 260px 1fr 280px;
    overflow: hidden;
  }

  /* ── Shared panel ── */
  .panel {
    border-right: 1px solid var(--border);
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .panel:last-child { border-right: none; }
  .panel-title {
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.1em;
    text-transform: uppercase;
    color: var(--muted);
    padding: 8px 12px;
    border-bottom: 1px solid var(--border);
    flex-shrink: 0;
  }
  .panel-body { flex: 1; overflow-y: auto; padding: 8px; }

  /* ── Cells panel ── */
  .cell-card {
    background: var(--surface2);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 8px 10px;
    margin-bottom: 6px;
    cursor: pointer;
    transition: border-color 0.15s;
  }
  .cell-card:hover { border-color: var(--blue); }
  .cell-card.selected { border-color: var(--cyan); }
  .cell-header { display: flex; align-items: center; gap: 6px; margin-bottom: 4px; }
  .cell-name { font-weight: 700; font-size: 11px; }
  .cell-type-dot {
    width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0;
  }
  .cell-type-dot.sensor   { background: var(--sensor-color); }
  .cell-type-dot.derived  { background: var(--derived-color); }
  .cell-type-dot.actuator { background: var(--actuator-color); }
  .cell-value {
    font-size: 16px;
    font-weight: 700;
    margin-bottom: 4px;
  }
  .cell-value.nothing      { color: var(--muted); }
  .cell-value.contradiction{ color: var(--red); }
  .cell-value.ok           { color: var(--text); }
  .cell-status {
    font-size: 9px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.08em;
  }
  .cell-status.ok           { color: var(--green); }
  .cell-status.nothing      { color: var(--yellow); }
  .cell-status.contradiction{ color: var(--red); }
  .cell-unit { color: var(--muted); font-size: 10px; }
  .cell-desc { color: var(--muted); font-size: 10px; margin-bottom: 4px; }

  /* Belief list */
  .beliefs { margin-top: 6px; border-top: 1px solid var(--border); padding-top: 6px; display: none; }
  .cell-card.selected .beliefs { display: block; }
  .belief-row {
    display: flex; align-items: center; gap: 6px;
    padding: 2px 0;
    font-size: 10px;
    color: var(--muted);
  }
  .belief-row.active { color: var(--text); }
  .belief-dot {
    width: 5px; height: 5px; border-radius: 50%; flex-shrink: 0;
  }
  .belief-dot.active { background: var(--green); }
  .belief-dot.inactive { background: var(--border); }
  .belief-source { color: var(--cyan); }

  /* ── SVG Graph panel ── */
  #graph-panel { border-right: 1px solid var(--border); display: flex; flex-direction: column; }
  #graph-panel .panel-title { display: flex; align-items: center; gap: 8px; }
  #graph-panel .legend { display: flex; gap: 12px; margin-left: auto; }
  .legend-item { display: flex; align-items: center; gap: 4px; font-size: 9px; color: var(--muted); }
  .legend-dot { width: 6px; height: 6px; border-radius: 50%; }
  svg#graph {
    flex: 1;
    width: 100%;
    height: 100%;
  }
  .graph-edge {
    stroke: var(--border);
    stroke-width: 1.5;
    fill: none;
    marker-end: url(#arrowhead);
  }
  .graph-edge.active-edge { stroke: var(--cyan); opacity: 0.7; }
  .graph-node rect {
    rx: 6; ry: 6;
    stroke-width: 1.5;
  }
  .graph-node.sensor rect   { fill: #1e3a5f; stroke: var(--sensor-color); }
  .graph-node.derived rect  { fill: #2e1d5c; stroke: var(--derived-color); }
  .graph-node.actuator rect { fill: #14401c; stroke: var(--actuator-color); }
  .graph-node.nothing rect  { opacity: 0.5; }
  .graph-node.contradiction rect { stroke: var(--red) !important; }
  .graph-node.selected rect { stroke-width: 2.5; }
  .graph-node text { font-family: monospace; font-size: 10px; fill: var(--text); }
  .graph-node .node-value { font-size: 11px; font-weight: 700; }
  .prop-label { font-family: monospace; font-size: 8px; fill: var(--muted); }

  /* ── Events panel ── */
  .event-row {
    display: flex;
    gap: 8px;
    padding: 4px 0;
    border-bottom: 1px solid var(--border)22;
    font-size: 10px;
    align-items: flex-start;
  }
  .event-time { color: var(--muted); flex-shrink: 0; width: 50px; }
  .event-type {
    flex-shrink: 0; width: 90px;
    font-weight: 700; font-size: 9px;
    text-transform: uppercase;
  }
  .event-type.belief_added    { color: var(--green); }
  .event-type.belief_retracted{ color: var(--yellow); }
  .event-type.cell_changed    { color: var(--cyan); }
  .event-body { color: var(--text); flex: 1; }
  .event-cell { color: var(--purple); }
  .event-source { color: var(--blue); }

  /* ── Footer / Controls ── */
  footer {
    border-top: 1px solid var(--border);
    background: var(--surface);
    display: grid;
    grid-template-columns: 1fr 1fr 1fr;
    gap: 0;
    overflow: hidden;
  }
  .control-section {
    border-right: 1px solid var(--border);
    padding: 10px 12px;
    overflow-y: auto;
  }
  .control-section:last-child { border-right: none; }
  .control-title {
    font-size: 9px; font-weight: 700; text-transform: uppercase;
    letter-spacing: 0.08em; color: var(--muted); margin-bottom: 8px;
  }
  .form-row {
    display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 6px;
    align-items: center;
  }
  label { font-size: 10px; color: var(--muted); }
  select, input[type=text], input[type=number] {
    background: var(--surface2);
    border: 1px solid var(--border);
    color: var(--text);
    font-family: monospace;
    font-size: 11px;
    padding: 4px 6px;
    border-radius: 4px;
    outline: none;
    min-width: 0;
  }
  select { flex: 1; }
  input[type=text], input[type=number] { flex: 1; }
  select:focus, input:focus { border-color: var(--blue); }
  button {
    background: var(--blue);
    color: white;
    border: none;
    border-radius: 4px;
    padding: 4px 10px;
    cursor: pointer;
    font-family: monospace;
    font-size: 11px;
    font-weight: 700;
    white-space: nowrap;
  }
  button:hover { opacity: 0.85; }
  button.danger { background: var(--red); }
  button.secondary { background: var(--surface2); border: 1px solid var(--border); }
  #feedback {
    margin-top: 6px;
    font-size: 10px;
    min-height: 14px;
  }
  #feedback.ok  { color: var(--green); }
  #feedback.err { color: var(--red); }

  /* Hypothesis panel */
  #hypo-list { font-size: 10px; color: var(--muted); margin-bottom: 6px; min-height: 20px; }
  .hypo-item { display: flex; justify-content: space-between; padding: 2px 0; }
  .hypo-item .hypo-desc { color: var(--yellow); }
  .hypo-item .hypo-rm { cursor: pointer; color: var(--red); }

  /* Scrollbars */
  ::-webkit-scrollbar { width: 4px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 2px; }
</style>
</head>
<body>

<header>
  <h1>Propagator Inspector</h1>
  <span id="domain-badge">Room</span>
  <span id="status-dot"></span>
</header>

<main>
  <!-- ── Cells panel ──────────────────────────────────────── -->
  <div class="panel" id="cells-panel">
    <div class="panel-title">Cells</div>
    <div class="panel-body" id="cells-body">Loading…</div>
  </div>

  <!-- ── Network graph ────────────────────────────────────── -->
  <div class="panel" id="graph-panel">
    <div class="panel-title">
      Network Graph
      <div class="legend">
        <div class="legend-item">
          <div class="legend-dot" style="background:var(--sensor-color)"></div>sensor
        </div>
        <div class="legend-item">
          <div class="legend-dot" style="background:var(--derived-color)"></div>derived
        </div>
        <div class="legend-item">
          <div class="legend-dot" style="background:var(--actuator-color)"></div>actuator
        </div>
      </div>
    </div>
    <svg id="graph">
      <defs>
        <marker id="arrowhead" markerWidth="8" markerHeight="6"
                refX="8" refY="3" orient="auto">
          <polygon points="0 0, 8 3, 0 6" fill="#2d3250"/>
        </marker>
        <marker id="arrowhead-active" markerWidth="8" markerHeight="6"
                refX="8" refY="3" orient="auto">
          <polygon points="0 0, 8 3, 0 6" fill="#06b6d4"/>
        </marker>
      </defs>
    </svg>
  </div>

  <!-- ── Events panel ─────────────────────────────────────── -->
  <div class="panel">
    <div class="panel-title">Event Log</div>
    <div class="panel-body" id="events-body"></div>
  </div>
</main>

<!-- ── Controls footer ──────────────────────────────────── -->
<footer>
  <!-- Assert -->
  <div class="control-section">
    <div class="control-title">Assert belief</div>
    <div class="form-row">
      <select id="assert-cell"></select>
    </div>
    <div class="form-row">
      <input type="number" id="assert-value" placeholder="value" step="any">
      <input type="text" id="assert-source" placeholder="source" value="user">
    </div>
    <div class="form-row">
      <button onclick="doAssert()">Assert</button>
      <button class="secondary" onclick="doAssertHypo()">+ Hypothesis</button>
    </div>
    <div id="feedback"></div>
  </div>

  <!-- Retract -->
  <div class="control-section">
    <div class="control-title">Retract belief</div>
    <div class="form-row">
      <select id="retract-cell"></select>
    </div>
    <div class="form-row">
      <input type="text" id="retract-source" placeholder="source name">
    </div>
    <div class="form-row">
      <button class="danger" onclick="doRetract()">Retract</button>
    </div>
  </div>

  <!-- Hypothesis mode -->
  <div class="control-section">
    <div class="control-title">Hypothesis mode</div>
    <div id="hypo-list"><span style="color:var(--muted)">No hypotheses active</span></div>
    <div class="form-row">
      <button onclick="commitHypos()">Commit all</button>
      <button class="danger" onclick="discardHypos()">Discard all</button>
    </div>
  </div>
</footer>

<script>
// ─── State ────────────────────────────────────────────────────────────────
let state       = null;
let meta        = null;
let lastEventId = 0;
let selectedCell = null;
let hypos = [];   // [{cell, value, source}] — pending hypotheses

// ─── Polling ──────────────────────────────────────────────────────────────
async function poll() {
  try {
    const [stateResp, eventsResp] = await Promise.all([
      fetch('/api/state'),
      fetch('/api/events?since=' + lastEventId)
    ]);

    if (!stateResp.ok || !eventsResp.ok) throw new Error('HTTP error');

    state = await stateResp.json();
    const eventsData = await eventsResp.json();

    if (eventsData.events && eventsData.events.length > 0) {
      const maxId = Math.max(...eventsData.events.map(e => e.id));
      if (maxId > lastEventId) {
        lastEventId = maxId;
        prependEvents(eventsData.events);
      }
    }

    renderCells();
    renderGraph();
    document.getElementById('status-dot').className = '';
  } catch (err) {
    document.getElementById('status-dot').className = 'stale';
  }
}

async function loadMeta() {
  const resp = await fetch('/api/meta');
  meta = await resp.json();
  document.getElementById('domain-badge').textContent = meta.domain;
  populateSelects();
}

// ─── Cells panel ─────────────────────────────────────────────────────────
function renderCells() {
  const body = document.getElementById('cells-body');
  if (!state) return;

  const cells = Object.values(state.cells).sort((a, b) => {
    const order = {sensor: 0, derived: 1, actuator: 2};
    return (order[a.type] ?? 9) - (order[b.type] ?? 9) || a.name.localeCompare(b.name);
  });

  body.innerHTML = cells.map(c => {
    const isSelected = selectedCell === c.id;
    const displayVal = formatValue(c.active_value, c.unit);
    const statusClass = c.status;

    const beliefsHtml = c.beliefs.map(b => `
      <div class="belief-row ${b.active ? 'active' : ''}">
        <div class="belief-dot ${b.active ? 'active' : 'inactive'}"></div>
        <span class="belief-source">${b.informant}</span>
        <span>→</span>
        <span>${formatValue(b.value, null)}</span>
        ${b.active ? '<span style="color:var(--green);font-size:9px">●in</span>' : '<span style="color:var(--muted);font-size:9px">○out</span>'}
      </div>
    `).join('');

    return `
      <div class="cell-card ${isSelected ? 'selected' : ''}" onclick="selectCell(${c.id})">
        <div class="cell-header">
          <div class="cell-type-dot ${c.type}"></div>
          <div class="cell-name">${c.name}</div>
        </div>
        <div class="cell-value ${statusClass}">${displayVal}</div>
        <div>
          <span class="cell-status ${statusClass}">${c.status}</span>
          ${c.unit ? `<span class="cell-unit"> ${c.unit}</span>` : ''}
        </div>
        <div class="cell-desc">${c.description}</div>
        <div class="beliefs">${beliefsHtml || '<span style="color:var(--muted)">no beliefs</span>'}</div>
      </div>
    `;
  }).join('');
}

function selectCell(id) {
  selectedCell = selectedCell === id ? null : id;
  renderCells();
  renderGraph();
}

function formatValue(v, unit) {
  if (v === null || v === undefined) return '∅';
  if (v === 'contradiction') return '⚡ contradiction';
  if (v === true) return '✓ on';
  if (v === false) return '✗ off';
  if (typeof v === 'number') return v.toString();
  return String(v);
}

// ─── SVG Graph ────────────────────────────────────────────────────────────
const NODE_W = 110, NODE_H = 44, PAD_X = 40, PAD_Y = 20;

function computeLayout() {
  if (!state) return {};
  const cells = Object.values(state.cells);
  const props = Object.values(state.propagators);

  // Which cell IDs appear as outputs of propagators?
  const derivedIds = new Set();
  props.forEach(p => p.outputs.forEach(id => derivedIds.add(id)));
  const inputIds = new Set();
  props.forEach(p => p.inputs.forEach(id => inputIds.add(id)));

  // Determine layer: 0=sensor, 1=derived/mixed, 2=actuator
  // Use the cell type from the API if available
  const layer = {};
  cells.forEach(c => {
    if (c.type === 'sensor')  layer[c.id] = 0;
    else if (c.type === 'derived') layer[c.id] = 1;
    else if (c.type === 'actuator') layer[c.id] = 2;
    else layer[c.id] = 1;
  });

  // Assign y positions within each layer
  const layerCells = {0: [], 1: [], 2: []};
  cells.forEach(c => layerCells[layer[c.id] ?? 1].push(c));
  Object.values(layerCells).forEach(arr => arr.sort((a, b) => a.id - b.id));

  const svg = document.getElementById('graph');
  const W = svg.clientWidth || 600;
  const H = svg.clientHeight || 400;

  const colX = {
    0: PAD_X,
    1: W / 2 - NODE_W / 2,
    2: W - PAD_X - NODE_W
  };

  const positions = {};
  [0, 1, 2].forEach(col => {
    const arr = layerCells[col];
    const totalH = arr.length * (NODE_H + PAD_Y) - PAD_Y;
    const startY = (H - totalH) / 2;
    arr.forEach((c, i) => {
      positions[c.id] = {
        x: colX[col],
        y: startY + i * (NODE_H + PAD_Y)
      };
    });
  });

  return positions;
}

function renderGraph() {
  if (!state) return;
  const svg = document.getElementById('graph');
  const positions = computeLayout();
  const cells = state.cells;
  const props = Object.values(state.propagators);

  let svgContent = '';

  // Draw edges (propagator connections)
  props.forEach(p => {
    const isActive = p.inputs.every(id => {
      const c = cells[id];
      return c && c.status === 'ok';
    });

    p.inputs.forEach(inId => {
      p.outputs.forEach(outId => {
        const from = positions[inId];
        const to = positions[outId];
        if (!from || !to) return;

        const x1 = from.x + NODE_W;
        const y1 = from.y + NODE_H / 2;
        const x2 = to.x;
        const y2 = to.y + NODE_H / 2;

        // Cubic bezier
        const cx = (x1 + x2) / 2;
        svgContent += `<path class="graph-edge ${isActive ? 'active-edge' : ''}"
          d="M${x1},${y1} C${cx},${y1} ${cx},${y2} ${x2},${y2}"
          marker-end="url(#${isActive ? 'arrowhead-active' : 'arrowhead'})"/>`;
      });
    });

    // Label at midpoint of first input→output edge
    if (p.inputs[0] && p.outputs[0]) {
      const from = positions[p.inputs[0]];
      const to = positions[p.outputs[0]];
      if (from && to) {
        const lx = (from.x + NODE_W + to.x) / 2;
        const ly = (from.y + to.y) / 2 + NODE_H / 2;
        svgContent += `<text class="prop-label" x="${lx}" y="${ly}" text-anchor="middle">${p.rule_name}</text>`;
      }
    }
  });

  // Draw nodes
  Object.values(cells).forEach(c => {
    const pos = positions[c.id];
    if (!pos) return;
    const isSelected = selectedCell === c.id;
    const displayVal = formatValue(c.active_value, null);
    const cls = [c.type, c.status, isSelected ? 'selected' : ''].filter(Boolean).join(' ');

    svgContent += `
      <g class="graph-node ${cls}" onclick="selectCell(${c.id})" style="cursor:pointer"
         transform="translate(${pos.x}, ${pos.y})">
        <rect width="${NODE_W}" height="${NODE_H}"/>
        <text x="6" y="16" class="node-name">${c.name}</text>
        <text x="6" y="32" class="node-value">${displayVal}${c.unit ? ' ' + c.unit : ''}</text>
      </g>
    `;
  });

  svg.innerHTML = svg.querySelector('defs').outerHTML + svgContent;
}

// ─── Events panel ─────────────────────────────────────────────────────────
function prependEvents(events) {
  const body = document.getElementById('events-body');
  const html = events.map(e => {
    const ts = new Date(e.timestamp).toLocaleTimeString('en', {hour12: false});
    let body = '';

    if (e.type === 'belief_added') {
      body = `<span class="event-cell">${e.cell_name || e.cell_id}</span> ← <b>${formatValue(e.value, null)}</b> from <span class="event-source">${e.informant}</span>`;
    } else if (e.type === 'belief_retracted') {
      body = `<span class="event-cell">${e.cell_name || e.cell_id}</span> retracted from <span class="event-source">${e.informant}</span>`;
    } else if (e.type === 'cell_changed') {
      body = `<span class="event-cell">${e.cell_name || e.cell_id}</span> ${formatValue(e.old_value, null)} → <b>${formatValue(e.new_value, null)}</b>`;
    } else {
      body = JSON.stringify(e);
    }

    return `<div class="event-row">
      <span class="event-time">${ts}</span>
      <span class="event-type ${e.type}">${e.type.replace('_', ' ')}</span>
      <span class="event-body">${body}</span>
    </div>`;
  }).join('');

  body.insertAdjacentHTML('afterbegin', html);
}

// ─── Controls ─────────────────────────────────────────────────────────────
function populateSelects() {
  if (!meta) return;
  const sensors = meta.cell_specs.filter(s => s.type === 'sensor' || s.type === 'derived');
  const all = meta.cell_specs;

  const toOptions = specs => specs.map(s =>
    `<option value="${s.name}">${s.name} (${s.unit || s.type})</option>`
  ).join('');

  document.getElementById('assert-cell').innerHTML  = toOptions(sensors);
  document.getElementById('retract-cell').innerHTML = toOptions(all);
}

function setFeedback(msg, ok) {
  const el = document.getElementById('feedback');
  el.textContent = msg;
  el.className = ok ? 'ok' : 'err';
  setTimeout(() => { el.textContent = ''; el.className = ''; }, 3000);
}

async function doAssert() {
  const cell   = document.getElementById('assert-cell').value;
  const value  = parseFloat(document.getElementById('assert-value').value);
  const source = document.getElementById('assert-source').value.trim() || 'user';

  if (isNaN(value)) return setFeedback('Enter a numeric value', false);

  try {
    const resp = await fetch('/api/assert', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({cell, value, source})
    });
    const data = await resp.json();
    if (data.ok) setFeedback(`✓ Set ${cell} = ${value} from ${source}`, true);
    else setFeedback(`✗ ${data.error}`, false);
  } catch (e) {
    setFeedback('Network error', false);
  }
  poll();
}

async function doAssertHypo() {
  const cell   = document.getElementById('assert-cell').value;
  const value  = parseFloat(document.getElementById('assert-value').value);

  if (isNaN(value)) return setFeedback('Enter a numeric value', false);
  const source = 'hypothesis';

  hypos.push({cell, value, source});
  renderHypos();

  try {
    await fetch('/api/assert', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({cell, value, source})
    });
  } catch (e) {}
  poll();
}

async function doRetract() {
  const cell   = document.getElementById('retract-cell').value;
  const source = document.getElementById('retract-source').value.trim() || 'user';

  try {
    const resp = await fetch('/api/retract', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({cell, source})
    });
    const data = await resp.json();
    if (data.ok) setFeedback(`✓ Retracted ${source} from ${cell}`, true);
    else setFeedback(`✗ ${data.error}`, false);
  } catch (e) {
    setFeedback('Network error', false);
  }
  poll();
}

// ─── Hypothesis mode ──────────────────────────────────────────────────────
function renderHypos() {
  const el = document.getElementById('hypo-list');
  if (hypos.length === 0) {
    el.innerHTML = '<span style="color:var(--muted)">No hypotheses active</span>';
    return;
  }
  el.innerHTML = hypos.map((h, i) => `
    <div class="hypo-item">
      <span class="hypo-desc">${h.cell} ← ${h.value}</span>
      <span class="hypo-rm" onclick="removeHypo(${i})">✕</span>
    </div>
  `).join('');
}

async function removeHypo(i) {
  const h = hypos[i];
  hypos.splice(i, 1);
  renderHypos();
  await fetch('/api/retract', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({cell: h.cell, source: h.source})
  });
  poll();
}

async function commitHypos() {
  // Re-assert with "committed" source, then retract hypothesis versions
  for (const h of hypos) {
    await fetch('/api/assert', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({cell: h.cell, value: h.value, source: 'committed'})
    });
    await fetch('/api/retract', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({cell: h.cell, source: 'hypothesis'})
    });
  }
  hypos = [];
  renderHypos();
  poll();
}

async function discardHypos() {
  for (const h of hypos) {
    await fetch('/api/retract', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({cell: h.cell, source: h.source})
    });
  }
  hypos = [];
  renderHypos();
  poll();
}

// ─── Init ─────────────────────────────────────────────────────────────────
(async () => {
  await loadMeta();
  await poll();
  setInterval(poll, 800);
})();

window.addEventListener('resize', renderGraph);
</script>
</body>
</html>
"""
  end
end
