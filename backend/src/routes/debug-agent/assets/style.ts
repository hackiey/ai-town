export const DEBUG_AGENT_PAGE_STYLE = String.raw`
  :root {
    color-scheme: dark;
    --bg: #0f1115;
    --bg-2: #161a22;
    --bg-3: #1f2530;
    --border: #2a3242;
    --text: #d6dbe6;
    --muted: #8a93a6;
    --accent: #6aa2ff;
    --user: #4ea0ff;
    --assistant: #6bd58a;
    --tool: #d6a76a;
    --tool-result: #68d2c8;
    --error: #ff7676;
    --chip: #2a3242;
    --turn-idle: #4a6d8c;
    --turn-interrupt: #8c6d4a;
    --turn-player: #6d4a8c;
    --turn-error: #8c3a3a;
    --surface-user: rgba(78, 160, 255, 0.08);
    --surface-user-strong: rgba(78, 160, 255, 0.16);
    --surface-assistant: rgba(107, 213, 138, 0.06);
    --surface-assistant-strong: rgba(107, 213, 138, 0.14);
    --surface-reasoning: rgba(182, 157, 255, 0.10);
    --surface-reasoning-strong: rgba(182, 157, 255, 0.18);
    --surface-tool-call: rgba(214, 167, 106, 0.10);
    --surface-tool-call-strong: rgba(214, 167, 106, 0.18);
    --surface-tool-result: rgba(104, 210, 200, 0.10);
    --surface-tool-result-strong: rgba(104, 210, 200, 0.18);
    --surface-meta: rgba(138, 147, 166, 0.08);
    --border-user: rgba(78, 160, 255, 0.38);
    --border-assistant: rgba(107, 213, 138, 0.34);
    --border-reasoning: rgba(182, 157, 255, 0.36);
    --border-tool-call: rgba(214, 167, 106, 0.36);
    --border-tool-result: rgba(104, 210, 200, 0.36);
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; height: 100%; background: var(--bg); color: var(--text); font: 13px/1.5 ui-monospace, "SF Mono", Menlo, Consolas, monospace; }
  a { color: var(--accent); }
  button { background: var(--bg-3); color: var(--text); border: 1px solid var(--border); padding: 4px 10px; border-radius: 4px; cursor: pointer; font: inherit; }
  button:hover { border-color: var(--accent); }
  button.danger { border-color: #5a2222; color: #ffb0b0; }
  button.danger:hover { background: #3a1818; border-color: var(--error); color: #fff; }
  input, select { background: var(--bg-3); color: var(--text); border: 1px solid var(--border); padding: 4px 8px; border-radius: 4px; font: inherit; }
  .layout { display: flex; flex-direction: column; height: 100vh; }
  .topbar { padding: 8px 12px; border-bottom: 1px solid var(--border); display: flex; gap: 10px; align-items: center; flex-wrap: wrap; background: var(--bg-2); }
  .topbar label { color: var(--muted); font-size: 11px; display: flex; gap: 4px; align-items: center; }
  .topbar .grow { flex: 1; }
  .topbar .meta { color: var(--muted); font-size: 11px; }
  .npc-filter { position: relative; }
  .npc-filter-btn { min-width: 140px; text-align: left; }
  .npc-filter-pop { position: absolute; top: 100%; left: 0; margin-top: 4px; background: var(--bg-3); border: 1px solid var(--border); border-radius: 4px; padding: 6px; max-height: 360px; overflow-y: auto; z-index: 50; display: none; min-width: 220px; box-shadow: 0 6px 20px rgba(0,0,0,0.6); }
  .npc-filter-pop.open { display: block; }
  .npc-filter-pop label { display: flex; gap: 6px; padding: 3px 4px; cursor: pointer; color: var(--text); font-size: 12px; align-items: flex-start; }
  .npc-filter-pop label:hover { background: var(--bg-2); }
  .npc-filter-pop .row { display: flex; gap: 4px; padding-bottom: 4px; border-bottom: 1px solid var(--border); margin-bottom: 4px; }
  .npc-filter-pop .row button { padding: 2px 6px; font-size: 11px; }
  .filter-text { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .filter-text .primary { color: var(--text); }
  .filter-text .secondary { color: var(--muted); font-size: 10px; }
  .timeline-zoom { display: flex; align-items: center; gap: 6px; color: var(--muted); font-size: 11px; }
  .timeline-zoom button { padding: 2px 8px; min-width: 30px; }
  .timeline-zoom input[type="range"] { width: 128px; padding: 0; }
  .timeline-zoom .zoom-value { min-width: 48px; text-align: right; color: var(--text); }

  .timeline-wrap {
    border-bottom: 1px solid var(--border);
    background: var(--bg);
    overflow: hidden;
  }
  .timeline-shell {
    display: grid;
    grid-template-columns: var(--timeline-label-w) minmax(0, 1fr);
    min-width: 100%;
    align-items: start;
  }
  .timeline-labels {
    position: sticky;
    left: 0;
    z-index: 1;
    background: var(--bg);
    border-right: 1px solid var(--border);
    overflow: hidden;
    touch-action: none;
    max-height: 28vh;
    min-height: 80px;
  }
  .timeline-scroller {
    min-width: 0;
    overflow: auto;
    max-height: 28vh;
    min-height: 80px;
  }
  .tt {
    position: fixed; pointer-events: none; z-index: 1000;
    background: #0a0c10; color: var(--text); border: 1px solid var(--accent);
    border-radius: 4px; padding: 6px 8px; font-size: 11px;
    box-shadow: 0 4px 14px rgba(0,0,0,0.6); max-width: 360px; white-space: pre-wrap;
    display: none;
  }
  .tt.show { display: block; }
  .tt .tt-name { color: var(--tool); font-weight: 700; }
  .tt .tt-meta { color: var(--muted); margin-top: 2px; }
  .timeline-empty { padding: 30px; text-align: center; color: var(--muted); }
  .timeline-label-list { min-width: 0; }
  .timeline-label-row { display: flex; align-items: center; gap: 6px; padding: 0 6px; border-bottom: 1px solid var(--border); color: var(--text); font: 11px ui-monospace, monospace; white-space: nowrap; overflow: hidden; }
  .timeline-label-row:nth-child(odd) { background: var(--bg-2); }
  .timeline-label-row:nth-child(even) { background: var(--bg); }
  .timeline-label-row .agent-run-checkbox { flex: 0 0 auto; width: 13px; height: 13px; margin: 0; padding: 0; accent-color: var(--accent); cursor: pointer; }
  .timeline-label-text { min-width: 0; overflow: hidden; text-overflow: ellipsis; }
  .timeline-label-axis { background: var(--bg); }
  .timeline-label-svg,
  .timeline-svg { display: block; }
  .timeline-label-svg .row-bg,
  .timeline-svg .row-bg { fill: var(--bg-2); }
  .timeline-label-svg .row-bg:nth-child(even),
  .timeline-svg .row-bg:nth-child(even) { fill: var(--bg); }
  .timeline-svg .grid { stroke: var(--border); stroke-width: 1; shape-rendering: crispEdges; }
  .timeline-svg .axis-tick { stroke: var(--border); stroke-width: 1; }
  .timeline-svg .axis-text { fill: var(--muted); font: 10px ui-monospace, monospace; }
  .timeline-label-svg .row-label { fill: var(--text); font: 11px ui-monospace, monospace; dominant-baseline: middle; }
  .timeline-svg .session-link { fill: none; stroke-width: 5; stroke-linecap: round; stroke-dasharray: 6 5; opacity: 0.34; pointer-events: none; }
  .timeline-svg .session-link.selected { opacity: 0.56; stroke-width: 6; }
  .timeline-svg .turn-bar { cursor: pointer; stroke-width: 1; }
  .timeline-svg .turn-bar:hover { stroke: var(--accent); stroke-width: 2; }
  .timeline-svg .turn-bar.selected { stroke: var(--accent); stroke-width: 2; }
  .timeline-svg .turn-bar.error { stroke: var(--error); }
  .timeline-svg .thinking-marker { cursor: pointer; fill: #c084fc; stroke: #a855f7; stroke-width: 1; }
  .timeline-svg .thinking-marker:hover { stroke: #fff; stroke-width: 2; }
  .timeline-svg .thinking-marker.selected { stroke: #fff; stroke-width: 2; }
  .timeline-svg .thinking-marker.error { fill: #ff7676; stroke: #c33; }
  .timeline-label-svg .row-divider,
  .timeline-svg .row-divider { stroke: var(--border); stroke-width: 1; shape-rendering: crispEdges; }

  .detail { flex: 1; min-height: 0; display: flex; flex-direction: column; overflow: hidden; }
  .detail-header { padding: 8px 14px; border-bottom: 1px solid var(--border); display: flex; align-items: center; gap: 8px; flex-wrap: wrap; background: var(--bg-2); }
  .detail-header .title { font-weight: 600; }
  .detail-header .meta { color: var(--muted); font-size: 12px; }
  .detail-body { flex: 1; overflow-y: auto; padding: 12px 14px; }

  .inner-timeline { background: var(--bg-2); border: 1px solid var(--border); border-radius: 6px; padding: 10px; margin-bottom: 12px; }
  .inner-timeline .legend { display: flex; gap: 12px; margin-bottom: 6px; font-size: 11px; color: var(--muted); }
  .inner-timeline .swatch { display: inline-block; width: 10px; height: 10px; vertical-align: middle; margin-right: 4px; border-radius: 2px; }
  .inner-svg .row-label { fill: var(--muted); font: 10px ui-monospace, monospace; dominant-baseline: middle; }
  .inner-svg .seg { stroke-width: 1; cursor: pointer; }
  .inner-svg .seg:hover,
  .inner-svg .seg.selected { stroke: var(--accent); stroke-width: 2; }
  .inner-svg .axis-text { fill: var(--muted); font: 10px ui-monospace, monospace; }
  .inner-svg .axis-tick { stroke: var(--border); stroke-width: 1; }

  details { background: var(--bg-2); border: 1px solid var(--border); border-radius: 6px; margin-bottom: 8px; }
  details > summary { padding: 8px 12px; cursor: pointer; user-select: none; }
  details[open] > summary { border-bottom: 1px solid var(--border); }
  details .body { padding: 10px 12px; }
  .turn { background: var(--bg-2); border: 1px solid var(--border); border-radius: 8px; margin-bottom: 14px; overflow: hidden; }
  .turn.selected { border-color: var(--accent); box-shadow: 0 0 0 1px rgba(106, 162, 255, 0.18); }
  .turn.selected .turn-header { background: rgba(106, 162, 255, 0.12); }
  .turn.collapsed .turn-body { display: none; }
  .turn-header { padding: 8px 12px; background: var(--bg-3); border-bottom: 1px solid var(--border); display: flex; align-items: center; gap: 8px; flex-wrap: wrap; cursor: pointer; }
  .turn-header .turn-no { font-weight: 700; color: var(--accent); }
  .turn-header .turn-toggle { color: var(--muted); font-size: 11px; }
  .turn-header .reason { color: var(--text); }
  .turn-header .time { color: var(--muted); font-size: 11px; margin-left: auto; }
  .turn-body { padding: 12px; display: flex; flex-direction: column; gap: 12px; }
  .msg {
    padding: 12px;
    border: 1px solid var(--border);
    border-left-width: 4px;
    border-radius: 10px;
    background: var(--bg-3);
    box-shadow: inset 0 1px 0 rgba(255,255,255,0.02);
  }
  .msg.user {
    background: linear-gradient(180deg, var(--surface-user-strong), var(--surface-user));
    border-color: var(--border-user);
  }
  .msg.assistant {
    background: linear-gradient(180deg, var(--surface-assistant-strong), var(--surface-assistant));
    border-color: var(--border-assistant);
  }
  .msg.toolResult {
    background: linear-gradient(180deg, var(--surface-tool-result-strong), var(--surface-tool-result));
    border-color: var(--border-tool-result);
  }
  .turn, .msg, .toolcall { scroll-margin-top: 14px; }
  .jump-target { outline: 2px solid rgba(110, 168, 255, 0.78); outline-offset: 2px; }
  .msg .role-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    margin-bottom: 10px;
    padding-bottom: 8px;
    border-bottom: 1px dashed rgba(255,255,255,0.10);
    font-size: 11px;
  }
  .msg .role { font-weight: 700; text-transform: uppercase; letter-spacing: 0.4px; }
  .msg.user .role { color: var(--user); }
  .msg.assistant .role { color: var(--assistant); }
  .msg.toolResult .role { color: var(--tool-result); }
  .msg .seq, .msg .ts { color: var(--muted); }
  .msg .role-meta {
    margin-left: auto;
    display: inline-flex;
    gap: 6px;
    align-items: center;
    justify-content: flex-end;
    flex-wrap: wrap;
  }
  .msg pre { white-space: pre-wrap; word-break: break-word; margin: 0; font: inherit; color: var(--text); }
  .section + .section { margin-top: 10px; }
  .section h4 { margin: 4px 0 4px; color: var(--muted); font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.4px; }
  .assistant-section + .assistant-section {
    margin-top: 10px;
    padding-top: 10px;
    border-top: 1px solid rgba(255,255,255,0.08);
  }
  .assistant-section-head {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    margin-bottom: 6px;
    font-size: 10px;
    letter-spacing: 0.2px;
    text-transform: none;
    color: var(--muted);
  }
  .assistant-section-title { font-weight: 700; }
  .assistant-section-meta { margin-left: auto; display: flex; gap: 6px; align-items: center; flex-wrap: wrap; }
  .assistant-section-body {
    min-width: 0;
    margin-left: 6px;
    padding-left: 10px;
    border-left: 1px solid rgba(255,255,255,0.08);
  }
  .assistant-section.assistant-content .assistant-section-title { color: var(--assistant); }
  .assistant-section.reasoning .assistant-section-title { color: #d1b8ff; }
  .assistant-section.tool-calls .assistant-section-title { color: var(--tool); }
  .assistant-section.llm-messages .assistant-section-title { color: var(--accent); }
  .assistant-section.tools-snapshot .assistant-section-title { color: var(--muted); }
  .assistant-section.error-block .assistant-section-title { color: var(--error); }
  details.assistant-section > summary {
    list-style: none;
    cursor: pointer;
    user-select: none;
  }
  details.assistant-section:not([open]) > summary { margin-bottom: 0; }
  details.assistant-section > summary::-webkit-details-marker { display: none; }
  details.assistant-section > summary::after {
    content: "展开";
    margin-left: 8px;
    color: var(--muted);
    font-size: 10px;
    text-transform: none;
  }
  details.assistant-section[open] > summary::after { content: "收起"; }
  details.assistant-section:not([open]) > .assistant-section-body { display: none; }
  .section-card {
    border: 1px solid var(--border);
    border-radius: 8px;
    overflow: hidden;
    background: rgba(10, 12, 16, 0.38);
  }
  .section-card .section-head {
    padding: 7px 10px;
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    border-bottom: 1px solid rgba(255,255,255,0.08);
    font-size: 11px;
    letter-spacing: 0.4px;
    text-transform: uppercase;
  }
  .section-card .section-title { font-weight: 700; }
  .section-card .section-meta { margin-left: auto; display: flex; gap: 6px; align-items: center; flex-wrap: wrap; }
  .section-card .section-body { padding: 10px; }
  .section-card.user-input { border-color: var(--border-user); background: rgba(10, 18, 30, 0.35); }
  .section-card.user-input .section-head { background: var(--surface-user-strong); color: var(--user); }
  .section-card.assistant-content { border-color: var(--border-assistant); background: rgba(12, 24, 18, 0.32); }
  .section-card.assistant-content .section-head { background: var(--surface-assistant-strong); color: var(--assistant); }
  .section-card.reasoning { border-color: var(--border-reasoning); background: rgba(28, 18, 42, 0.35); }
  .section-card.reasoning .section-head { background: var(--surface-reasoning-strong); color: #d1b8ff; }
  .section-card.tool-calls { border-color: var(--border-tool-call); background: rgba(33, 22, 12, 0.30); }
  .section-card.tool-calls .section-head { background: var(--surface-tool-call-strong); color: var(--tool); }
  .section-card.tool-response { border-color: var(--border-tool-result); background: rgba(11, 26, 28, 0.30); }
  .section-card.tool-response .section-head { background: var(--surface-tool-result-strong); color: var(--tool-result); }
  .section-card.tools-snapshot { border-color: var(--border); background: var(--surface-meta); }
  .section-card.tools-snapshot .section-head { background: rgba(138, 147, 166, 0.12); color: var(--muted); }
  .section-card.meta-block { border-color: rgba(138, 147, 166, 0.28); background: rgba(138, 147, 166, 0.05); }
  .section-card.meta-block .section-head { background: rgba(138, 147, 166, 0.10); color: var(--muted); }
  .section-card.error-block { border-color: rgba(255, 118, 118, 0.42); background: rgba(58, 18, 18, 0.40); }
  .section-card.error-block .section-head { background: rgba(255, 118, 118, 0.12); color: var(--error); }
  .toolcall {
    border: 1px solid var(--border-tool-call);
    border-left: 3px solid var(--tool);
    border-radius: 6px;
    padding: 8px 10px;
    margin-bottom: 8px;
    background: rgba(10, 12, 16, 0.40);
  }
  .toolcall:last-child { margin-bottom: 0; }
  .toolcall .head {
    display: flex;
    gap: 8px;
    align-items: center;
    margin-bottom: 6px;
    padding-bottom: 6px;
    border-bottom: 1px dashed rgba(255,255,255,0.10);
  }
  .toolcall .name { color: var(--tool); font-weight: 700; }
  .toolcall .id { color: var(--muted); font-size: 11px; }
  .toolcall pre {
    background: rgba(0,0,0,0.22);
    padding: 8px;
    border-radius: 4px;
    border: 1px solid rgba(255,255,255,0.04);
    max-height: 280px;
    overflow-y: auto;
  }
  details.tool-snapshot { background: var(--bg-3); border: 1px solid var(--border); border-radius: 4px; margin-bottom: 4px; }
  details.tool-snapshot > summary { padding: 4px 8px; }
  details.tool-snapshot .body { padding: 6px 10px; }
  details.tool-snapshot .name { color: var(--tool); font-weight: 700; }
  details.tool-snapshot .id { color: var(--muted); font-size: 11px; }
  details.tool-snapshot .tool-desc { color: var(--text); margin-bottom: 6px; }
  details.tool-snapshot pre { background: var(--bg); padding: 6px; border-radius: 4px; max-height: 320px; overflow-y: auto; }
  details.llm-message-card { background: var(--bg-3); border: 1px solid var(--border); border-radius: 4px; margin-bottom: 6px; }
  details.llm-message-card > summary { padding: 5px 8px; display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  details.llm-message-card .role { color: var(--accent); font-weight: 700; text-transform: uppercase; }
  details.llm-message-card .seq { color: var(--muted); font-size: 11px; }
  details.llm-message-card .preview { color: var(--muted); font-size: 11px; }
  details.llm-message-card pre { background: var(--bg); padding: 8px; border-radius: 4px; max-height: 420px; overflow-y: auto; }
  details.llm-call-card { background: var(--bg-2); border: 1px solid var(--border); border-radius: 8px; margin-bottom: 10px; overflow: hidden; }
  details.llm-call-card.selected { border-color: var(--accent); box-shadow: 0 0 0 1px rgba(106, 162, 255, 0.16); }
  details.llm-call-card > summary { padding: 8px 10px; display: flex; gap: 8px; align-items: center; flex-wrap: wrap; background: var(--bg-3); }
  details.llm-call-card .name { color: var(--accent); font-weight: 700; }
  details.llm-call-card .meta { color: var(--muted); font-size: 11px; }
  details.llm-call-card > .body { padding: 10px; }
  details.llm-request-message { background: var(--bg-3); border: 1px solid var(--border); border-radius: 5px; margin-bottom: 6px; }
  details.llm-request-message > summary { padding: 6px 8px; display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  details.llm-request-message .role { color: var(--accent); font-weight: 700; text-transform: uppercase; }
  details.llm-request-message .seq,
  details.llm-request-message .preview { color: var(--muted); font-size: 11px; }
  details.llm-request-message pre { background: var(--bg); padding: 8px; border-radius: 4px; max-height: 520px; overflow-y: auto; }
  .prompt-memory-meta { color: var(--muted); margin-bottom: 10px; }
  .memory-list { display: flex; flex-direction: column; gap: 8px; }
  .memory-card { border: 1px solid var(--border); border-radius: 6px; padding: 8px 10px; background: var(--bg-3); }
  .memory-card .head { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; margin-bottom: 6px; }
  .memory-card .kind { color: var(--assistant); font-weight: 700; }
  .memory-card .meta { color: var(--muted); font-size: 11px; }
  .top-tabs { background: var(--bg-2); border: 1px solid var(--border); border-radius: 8px; margin-bottom: 12px; overflow: hidden; }
  .top-tabs .tab-bar { display: flex; gap: 0; border-bottom: 1px solid var(--border); flex-wrap: wrap; background: var(--bg-3); }
  .top-tabs .tab-btn { border: 0; border-right: 1px solid var(--border); border-radius: 0; background: transparent; padding: 10px 12px; color: var(--muted); }
  .top-tabs .tab-btn:last-child { border-right: 0; }
  .top-tabs .tab-btn:hover { background: rgba(255,255,255,0.03); border-color: var(--border); }
  .top-tabs .tab-btn.active { color: var(--text); background: var(--bg-2); }
  .top-tabs .tab-panel { padding: 12px; }
  .top-tabs .tab-panel pre { margin: 0; white-space: pre-wrap; word-break: break-word; }
  .reasoning pre { color: #b69dff; }
  .error { color: var(--error); }
  .empty { color: var(--muted); padding: 20px; text-align: center; }
  .truncate-wrap { position: relative; }
  .truncate-wrap.collapsed pre { max-height: 240px; overflow: hidden; }
  .truncate-wrap.collapsed::after { content: ""; position: absolute; left: 0; right: 0; bottom: 28px; height: 32px; background: linear-gradient(transparent, rgba(15,17,21,0.96)); pointer-events: none; }
  .truncate-toggle { display: inline-block; margin-top: 6px; color: var(--accent); cursor: pointer; font-size: 11px; }
  .pill { display: inline-block; padding: 1px 6px; background: var(--chip); border-radius: 8px; color: var(--muted); font-size: 10px; }
  .badge-error { background: #4a1f1f; color: var(--error); padding: 1px 6px; border-radius: 3px; font-size: 11px; }

  /* === view tabs (topbar) === */
  .view-tabs { display: flex; gap: 0; background: var(--bg-3); border: 1px solid var(--border); border-radius: 6px; overflow: hidden; }
  .view-tabs .view-tab { border: 0; border-radius: 0; background: transparent; color: var(--muted); padding: 4px 12px; font-weight: 600; }
  .view-tabs .view-tab + .view-tab { border-left: 1px solid var(--border); }
  .view-tabs .view-tab:hover { background: rgba(255,255,255,0.04); }
  .view-tabs .view-tab.active { color: var(--text); background: var(--bg-2); }

  /* === view panes === */
  .view-pane { display: none; flex-direction: column; flex: 1; min-height: 0; }
  .view-pane.active { display: flex; }
  #view-timeline.active { display: flex; }
  .analytics-pane.active { display: flex; }

  /* === analytics toolbar === */
  .analytics-toolbar { padding: 8px 12px; border-bottom: 1px solid var(--border); display: flex; gap: 10px; align-items: center; flex-wrap: wrap; background: var(--bg-2); }
  .analytics-toolbar label { color: var(--muted); font-size: 11px; display: flex; gap: 4px; align-items: center; }
  .analytics-toolbar .grow { flex: 1; }
  .analytics-toolbar .meta { color: var(--muted); font-size: 11px; }
  .analytics-focus { display: inline-flex; gap: 6px; align-items: center; padding: 2px 8px; background: var(--bg-3); border: 1px solid var(--accent); border-radius: 4px; font-size: 11px; color: var(--text); }
  .analytics-focus strong { color: var(--accent); }
  .analytics-focus button { padding: 0 6px; font-size: 11px; }

  /* === analytics body === */
  .analytics-body { flex: 1; overflow: auto; padding: 12px; }
  .analytics-section { background: var(--bg-2); border: 1px solid var(--border); border-radius: 6px; padding: 12px; margin-bottom: 12px; }
  .analytics-section h3 { margin: 0 0 10px; font-size: 12px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; font-weight: 700; }
  .analytics-section .empty { padding: 10px; }

  /* === kpis === */
  .kpi-row { display: flex; gap: 10px; flex-wrap: wrap; }
  .kpi-card { flex: 1 1 140px; min-width: 140px; background: var(--bg-3); border: 1px solid var(--border); border-radius: 6px; padding: 8px 12px; }
  .kpi-card.kpi-error { border-color: rgba(255, 118, 118, 0.5); }
  .kpi-card.kpi-error .kpi-value { color: var(--error); }
  .kpi-label { color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em; }
  .kpi-value { color: var(--text); font-size: 18px; font-weight: 700; margin-top: 4px; }

  /* === tables === */
  .analytics-table { width: 100%; border-collapse: collapse; font-size: 12px; }
  .analytics-table th, .analytics-table td { padding: 5px 8px; border-bottom: 1px solid var(--border); text-align: left; vertical-align: middle; }
  .analytics-table th { color: var(--muted); font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; background: var(--bg-3); position: sticky; top: 0; }
  .analytics-table .cell-num { text-align: right; font-variant-numeric: tabular-nums; }
  .analytics-table .cell-error { color: var(--error); font-weight: 600; }
  .analytics-table .cell-bar { width: 160px; }
  .analytics-table .cell-name { color: var(--text); }
  .analytics-table .cell-id { color: var(--muted); font-size: 10px; }
  .analytics-table .cell-excerpt { color: var(--muted); font-size: 11px; max-width: 600px; }
  .analytics-table .cell-excerpt pre { margin: 0; white-space: pre-wrap; word-break: break-word; max-height: 60px; overflow: hidden; font: inherit; }
  .analytics-table .cell-action { width: 60px; text-align: right; }

  /* === tool table interactivity === */
  .analytics-tool-row { cursor: pointer; }
  .analytics-tool-row:hover { background: rgba(255,255,255,0.03); }
  .analytics-tool-row.focused { background: rgba(106, 162, 255, 0.10); }
  .analytics-tool-row.focused td { border-bottom-color: var(--accent); }
  .tool-link { color: var(--accent); }

  /* === bar inside tool row === */
  .bar-track { display: flex; height: 12px; background: rgba(255,255,255,0.04); border-radius: 2px; overflow: hidden; }
  .bar-fill-success { background: var(--assistant); height: 100%; }
  .bar-fill-error { background: var(--error); height: 100%; }

  /* === error row === */
  .analytics-error-row:hover { background: rgba(255,255,255,0.03); }
  .error-jump { padding: 2px 8px; font-size: 11px; }

  /* === time buckets === */
  .time-buckets { display: flex; gap: 2px; align-items: flex-end; height: 140px; overflow-x: auto; padding: 4px 0; }
  .time-bucket { display: flex; flex-direction: column; align-items: center; min-width: 24px; flex: 0 0 auto; }
  .time-bucket-bar { width: 18px; min-height: 1px; background: rgba(255,255,255,0.04); display: flex; flex-direction: column-reverse; border-radius: 2px; overflow: hidden; margin-top: auto; }
  .time-bucket-success { background: var(--assistant); width: 100%; }
  .time-bucket-error { background: var(--error); width: 100%; }
  .time-bucket-label { color: var(--muted); font-size: 9px; margin-top: 3px; transform: rotate(-45deg); transform-origin: top left; white-space: nowrap; height: 30px; }
  .legend { display: flex; gap: 12px; color: var(--muted); font-size: 11px; margin-top: 18px; }
  .legend-swatch { display: inline-block; width: 10px; height: 10px; border-radius: 2px; vertical-align: middle; margin-right: 4px; }
  .legend-success { background: var(--assistant); }
  .legend-error { background: var(--error); }
`;
