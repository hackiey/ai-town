export const DEBUG_AGENT_CHARACTER_TIMELINE_MODULE = String.raw`
import {
  compareZhText,
  escapeHtml,
  formatCostUsd,
  formatGroupNames,
  formatTokenCount,
  getCharacterDisplayName,
  getCharacterGroupNames,
  isAgentRunCharacterEnabled,
  makeCharacterKey,
} from "./shared.js";
import {
  formatDuration,
  formatGameDuration,
  formatGameTime,
  gameDayIndex,
} from "./time.js";

function turnMatchesSelectedDay(item, selectedDay) {
  if (!selectedDay) return true;
  const target = Number(selectedDay);
  if (!Number.isFinite(target)) return true;
  const start = gameDayIndex(item.startGameTime);
  if (start === target) return true;
  const end = gameDayIndex(item.endGameTime);
  if (end == null) return false;
  return start != null && start <= target && end >= target;
}

function thinkingMatchesSelectedDay(item, selectedDay) {
  if (!selectedDay) return true;
  const target = Number(selectedDay);
  if (!Number.isFinite(target)) return true;
  return gameDayIndex(item.startGameTime) === target;
}

export function updateTimelineZoomUi(app) {
  const slider = app.$("timeline-zoom");
  const label = app.$("timeline-zoom-label");
  if (slider) slider.value = String(app.state.timelineZoomIndex || 0);
  if (label) label.textContent = "竖向";
  const out = app.$("timeline-zoom-out");
  const input = app.$("timeline-zoom");
  const inc = app.$("timeline-zoom-in");
  const reset = app.$("timeline-zoom-reset");
  if (out) out.disabled = true;
  if (input) input.disabled = true;
  if (inc) inc.disabled = true;
  if (reset) reset.disabled = true;
}

export function captureTimelineViewport(app) {
  const timeline = app.$("timeline-scroller");
  const characters = app.$("character-list");
  return {
    timelineScrollTop: timeline ? timeline.scrollTop : 0,
    characterScrollTop: characters ? characters.scrollTop : 0,
  };
}

export function restoreTimelineViewport(app, viewport) {
  if (!viewport) return;
  window.requestAnimationFrame(() => {
    const timeline = app.$("timeline-scroller");
    const characters = app.$("character-list");
    if (timeline) timeline.scrollTop = viewport.timelineScrollTop || 0;
    if (characters) characters.scrollTop = viewport.characterScrollTop || 0;
  });
}

export function rerenderTimelinePreserveViewport(app, renderTimelineFn) {
  const viewport = captureTimelineViewport(app);
  renderTimelineFn();
  restoreTimelineViewport(app, viewport);
}

export function setTimelineZoomIndex(app, renderTimelineFn, nextIndex) {
  app.state.timelineZoomIndex = Number.isFinite(nextIndex) ? nextIndex : 0;
  updateTimelineZoomUi(app);
  rerenderTimelinePreserveViewport(app, renderTimelineFn);
}

export function renderTimeline(app, handlers) {
  const characters = visibleCharacters(app);
  ensureSelectedCharacter(app, characters);
  renderCharacterList(app, handlers, characters);
  renderSelectedCharacterTimeline(app, handlers, characters);
}

export function showTooltip(app, event, html) {
  const tt = app.$("tt");
  if (!tt) return;
  tt.innerHTML = html;
  tt.classList.add("show");
  const x = Math.min(window.innerWidth - 380, event.clientX + 14);
  const y = Math.min(window.innerHeight - tt.offsetHeight - 10, event.clientY + 14);
  tt.style.left = x + "px";
  tt.style.top = y + "px";
}

export function hideTooltip(app) {
  const tt = app.$("tt");
  if (tt) tt.classList.remove("show");
}

function visibleCharacters(app) {
  const selectedGroupIds = app.state.selectedGroupIds || new Set();
  const byKey = new Map();
  for (const character of app.state.characters || []) {
    if (!characterMatchesGroups(character, selectedGroupIds)) continue;
    byKey.set(makeCharacterKey(character.townId, character.characterId), character);
  }

  for (const turn of app.state.turns || []) {
    const key = makeCharacterKey(turn.townId, turn.characterId);
    if (!byKey.has(key) && turnMatchesSelectedGroups(app, turn)) {
      byKey.set(key, fallbackCharacter(app, turn));
    }
  }

  for (const thinking of app.state.thinkingTurns || []) {
    const key = makeCharacterKey(thinking.townId, thinking.characterId);
    if (!byKey.has(key) && thinkingMatchesSelectedGroups(app, thinking)) {
      byKey.set(key, fallbackCharacter(app, thinking));
    }
  }

  return Array.from(byKey.values()).sort(compareCharacters);
}

function fallbackCharacter(app, item) {
  return {
    townId: item.townId || "",
    characterId: item.characterId || "",
    agentKind: item.agentKind || "npc",
    displayName: getCharacterDisplayName(app, item.characterId, item.townId),
    turnCount: 0,
    llmCallCount: 0,
    toolCallCount: 0,
    totalTokens: null,
    totalCostUsd: null,
    groups: [],
  };
}

function characterMatchesGroups(character, selectedGroupIds) {
  if (!selectedGroupIds || selectedGroupIds.size === 0) return true;
  const groups = Array.isArray(character.groups) ? character.groups : [];
  return groups.some((group) => selectedGroupIds.has(group.groupId));
}

function turnMatchesSelectedGroups(app, item) {
  const selectedGroupIds = app.state.selectedGroupIds || new Set();
  if (selectedGroupIds.size === 0) return true;
  const meta = app.state.characterMetaByKey.get(makeCharacterKey(item.townId, item.characterId))
    || app.state.characterMetaById.get(item.characterId);
  const groups = Array.isArray(meta && meta.groups) ? meta.groups : [];
  return groups.some((group) => selectedGroupIds.has(group.groupId));
}

function thinkingMatchesSelectedGroups(app, item) {
  return turnMatchesSelectedGroups(app, item);
}

function compareCharacters(a, b) {
  const groupCompare = compareZhText(groupSortText(a.groups), groupSortText(b.groups));
  if (groupCompare !== 0) return groupCompare;
  return compareZhText(a.displayName || a.characterId, b.displayName || b.characterId);
}

function groupSortText(groups) {
  return formatGroupNames(groups || []);
}

function ensureSelectedCharacter(app, characters) {
  if (!app.state.selectedCharacterKey) return;
  if (characters.some((character) => characterKey(character) === app.state.selectedCharacterKey)) return;
  app.state.selectedCharacterKey = "";
  app.state.selectedTurn = null;
  app.state.selectedThinking = null;
}

function renderCharacterList(app, handlers, characters) {
  const wrap = app.$("character-list");
  const meta = app.$("character-list-meta");
  if (!wrap) return;
  if (meta) {
    meta.textContent = characters.length + " 个角色";
  }
  if (characters.length === 0) {
    wrap.innerHTML = '<div class="empty">没有角色</div>';
    return;
  }

  const parts = [];
  for (let index = 0; index < characters.length; index += 1) {
    const character = characters[index];
    const key = characterKey(character);
    const selected = key === app.state.selectedCharacterKey;
    const checked = isAgentRunCharacterEnabled(app, character.characterId) ? " checked" : "";
    const stats = characterStatsText(character);
    const groups = formatGroupNames(character.groups);
    const secondary = [character.characterId, character.agentKind, character.townId, groups].filter(Boolean).join(" · ");
    parts.push(''
      + '<button class="character-row' + (selected ? " selected" : "") + '" type="button"'
      + ' data-character-index="' + index + '">'
      + '<input class="agent-run-checkbox" type="checkbox" data-character="' + escapeHtml(character.characterId) + '"'
      + ' title="勾选后允许该角色运行 Agent"' + checked + ' />'
      + '<span class="character-row-main">'
      + '<span class="character-name">' + escapeHtml(character.displayName || character.characterId) + '</span>'
      + '<span class="character-stats">' + escapeHtml(stats || "暂无 turn") + '</span>'
      + '<span class="character-secondary">' + escapeHtml(secondary) + '</span>'
      + '</span>'
      + '</button>');
  }
  wrap.innerHTML = parts.join("");

  for (const row of wrap.querySelectorAll(".character-row")) {
    row.addEventListener("click", () => {
      const index = Number(row.dataset.characterIndex);
      const character = Number.isInteger(index) ? characters[index] : null;
      if (character && handlers.onSelectCharacter) handlers.onSelectCharacter(character);
    });
  }
  for (const checkbox of wrap.querySelectorAll(".agent-run-checkbox")) {
    checkbox.addEventListener("click", (event) => event.stopPropagation());
    checkbox.addEventListener("change", (event) => {
      const characterId = event.target.dataset.character;
      if (!characterId || !handlers.onAgentRunToggle) return;
      handlers.onAgentRunToggle(characterId, event.target.checked);
    });
  }
}

function characterStatsText(character) {
  const parts = [];
  if (character.turnCount > 0) parts.push(character.turnCount + " turns");
  if (character.llmCallCount > 0) parts.push(character.llmCallCount + " LLM");
  if (character.toolCallCount > 0) parts.push(character.toolCallCount + " tool");
  if (Number.isFinite(character.totalTokens)) parts.push(formatTokenCount(character.totalTokens));
  if (Number.isFinite(character.totalCostUsd)) parts.push(formatCostUsd(character.totalCostUsd));
  return parts.join(" · ");
}

function renderSelectedCharacterTimeline(app, handlers, characters) {
  const wrap = app.$("timeline-wrap");
  const meta = app.$("timeline-selected-meta");
  if (!wrap) return;
  const selected = characters.find((character) => characterKey(character) === app.state.selectedCharacterKey) || null;
  if (!selected) {
    if (meta) meta.textContent = "";
    wrap.innerHTML = '<div class="timeline-empty">请选择左侧角色</div>';
    return;
  }

  const entries = selectedTimelineEntries(app, selected);
  if (meta) {
    const thinkingCount = entries.filter((entry) => entry.kind === "thinking").length;
    const turnCount = entries.length - thinkingCount;
    meta.textContent = (selected.displayName || selected.characterId) + " · " + turnCount + " turns · " + thinkingCount + " thinking";
  }
  if (entries.length === 0) {
    wrap.innerHTML = '<div class="timeline-empty">这个角色在当前过滤条件下没有 turn 数据</div>';
    return;
  }

  const parts = ['<div id="timeline-scroller" class="timeline-scroller vertical-timeline">'];
  for (const entry of entries) {
    parts.push(entry.kind === "turn" ? buildTurnEntry(app, entry.item) : buildThinkingEntry(app, entry.item));
  }
  parts.push('</div>');
  wrap.innerHTML = parts.join("");

  const scroller = app.$("timeline-scroller");
  if (!scroller) return;
  bindTurnEntries(app, handlers, scroller);
  bindThinkingEntries(app, handlers, scroller);
}

function selectedTimelineEntries(app, character) {
  const selectedDay = app.state.selectedGameDay || "";
  const key = characterKey(character);
  const entries = [];
  for (const turn of app.state.turns || []) {
    if (makeCharacterKey(turn.townId, turn.characterId) !== key) continue;
    if (!turnMatchesSelectedDay(turn, selectedDay)) continue;
    entries.push({ kind: "turn", item: turn, sortTime: sortableTime(turn.startedAt, turn.startSeq) });
  }
  for (const thinking of app.state.thinkingTurns || []) {
    if (makeCharacterKey(thinking.townId, thinking.characterId) !== key) continue;
    if (!thinkingMatchesSelectedDay(thinking, selectedDay)) continue;
    entries.push({ kind: "thinking", item: thinking, sortTime: sortableTime(thinking.startedAt, 0) });
  }
  entries.sort((a, b) => b.sortTime - a.sortTime);
  return entries;
}

function sortableTime(iso, fallback) {
  const ms = Date.parse(iso || "");
  return Number.isFinite(ms) ? ms : fallback;
}

function buildTurnEntry(app, turn) {
  const selected = app.state.selectedTurn
    && app.state.selectedTurn.sessionId === turn.sessionId
    && app.state.selectedTurn.startSeq === turn.startSeq;
  const tokenInfo = turn.totalTokens != null ? formatTokenCount(turn.totalTokens) : "—";
  const costInfo = turn.totalCostUsd != null ? formatCostUsd(turn.totalCostUsd) : "—";
  const timeText = formatGameTime(turn.startGameTime)
    + (turn.endGameTime ? " → " + formatGameTime(turn.endGameTime) : "");
  const toolSummary = renderToolCallSummary(turn.toolCallSummary);
  return ''
    + '<button class="timeline-event turn-event turn-bar' + (turn.hasError ? " error" : "") + (selected ? " selected" : "") + '" type="button"'
    + ' data-session="' + escapeHtml(turn.sessionId) + '"'
    + ' data-start="' + turn.startSeq + '"'
    + ' data-end="' + turn.endSeq + '">'
    + '<span class="event-marker"></span>'
    + '<span class="event-content">'
    + '<span class="event-head">'
    + '<span class="event-title">' + escapeHtml(turn.turnReason || "turn") + '</span>'
    + '<span class="event-kind">ACTION</span>'
    + '</span>'
    + '<span class="event-time">' + escapeHtml(timeText) + '</span>'
    + '<span class="event-meta">#' + turn.startSeq + "–#" + turn.endSeq
    + " · " + turn.msgCount + " msg · " + turn.llmCallCount + " LLM · " + turn.toolCallCount + " tool" + '</span>'
    + '<span class="event-meta">' + escapeHtml(tokenInfo) + " · " + escapeHtml(costInfo)
    + (toolSummary ? " · 工具 " + toolSummary : "") + '</span>'
    + '<span class="event-session">session=' + escapeHtml(shortSessionId(turn.sessionId)) + '</span>'
    + '</span>'
    + '</button>';
}

function buildThinkingEntry(app, thinking) {
  const selected = app.state.selectedThinking && app.state.selectedThinking.id === thinking.id;
  const tokenInfo = thinking.totalTokens != null ? formatTokenCount(thinking.totalTokens) : "—";
  const costInfo = thinking.costUsd != null ? formatCostUsd(thinking.costUsd) : "—";
  const timeText = formatGameTime(thinking.startGameTime);
  const status = thinking.hasError ? "error" : (thinking.hasWritten ? "wrote memory" : "no write");
  return ''
    + '<button class="timeline-event thinking-event thinking-marker' + (thinking.hasError ? " error" : "") + (selected ? " selected" : "") + '" type="button"'
    + ' data-thinking-id="' + escapeHtml(thinking.id) + '">'
    + '<span class="event-marker"></span>'
    + '<span class="event-content">'
    + '<span class="event-head">'
    + '<span class="event-title">' + escapeHtml(thinking.triggerReason || "thinking") + '</span>'
    + '<span class="event-kind">THINKING</span>'
    + '</span>'
    + '<span class="event-time">' + escapeHtml(timeText) + '</span>'
    + (thinking.intent ? '<span class="event-meta">intent=' + escapeHtml(thinking.intent) + '</span>' : '')
    + '<span class="event-meta">' + escapeHtml(tokenInfo) + " · " + escapeHtml(costInfo)
    + " · " + escapeHtml(status) + '</span>'
    + '<span class="event-session">id=' + escapeHtml(shortSessionId(thinking.id)) + '</span>'
    + '</span>'
    + '</button>';
}

function bindTurnEntries(app, handlers, scroller) {
  for (const node of scroller.querySelectorAll(".turn-event")) {
    const sessionId = node.dataset.session;
    const startSeq = Number(node.dataset.start);
    const turn = (app.state.turns || []).find((item) => item.sessionId === sessionId && item.startSeq === startSeq);
    if (!turn) continue;
    node.addEventListener("click", () => { void handlers.onSelectTurn(turn); });
    node.addEventListener("mousemove", (event) => showOuterTooltip(app, event, turn));
    node.addEventListener("mouseleave", () => hideTooltip(app));
  }
}

function bindThinkingEntries(app, handlers, scroller) {
  for (const node of scroller.querySelectorAll(".thinking-event")) {
    const thinkingId = node.dataset.thinkingId;
    const thinking = (app.state.thinkingTurns || []).find((item) => item.id === thinkingId);
    if (!thinking || !handlers.onSelectThinking) continue;
    node.addEventListener("click", () => { void handlers.onSelectThinking(thinking); });
    node.addEventListener("mousemove", (event) => showThinkingTooltip(app, event, thinking));
    node.addEventListener("mouseleave", () => hideTooltip(app));
  }
}

function characterKey(character) {
  return makeCharacterKey(character.townId, character.characterId);
}

function shortSessionId(value) {
  const text = String(value || "");
  return text.length > 42 ? text.slice(0, 18) + "…" + text.slice(-18) : text;
}

function showOuterTooltip(app, event, turn) {
  const startMs = Date.parse(turn.startedAt);
  const endMs = Date.parse(turn.endedAt);
  const displayName = getCharacterDisplayName(app, turn.characterId, turn.townId);
  const groups = getCharacterGroupNames(app, turn.characterId, turn.townId).join("、");
  const turnTokens = turn.totalTokens != null ? formatTokenCount(turn.totalTokens) : "—";
  const turnCost = turn.totalCostUsd != null ? formatCostUsd(turn.totalCostUsd) : "—";
  const npcTokens = turn.npcCumulativeTokens != null ? formatTokenCount(turn.npcCumulativeTokens) : "—";
  const npcTokensAtTurn = turn.npcCumulativeTokensAtTurn != null
    ? formatTokenCount(turn.npcCumulativeTokensAtTurn)
    : "—";
  const npcCost = turn.npcCumulativeCostUsd != null ? formatCostUsd(turn.npcCumulativeCostUsd) : "—";
  const npcCostAtTurn = turn.npcCumulativeCostUsdAtTurn != null
    ? formatCostUsd(turn.npcCumulativeCostUsdAtTurn)
    : "—";
  const sessionToolSummary = renderToolCallSummary(summarizeSessionToolCalls(app, turn.sessionId)) || "—";
  let html = ""
    + '<div class="tt-name">' + escapeHtml(displayName) + "</div>"
    + '<div class="tt-meta">' + escapeHtml(turn.characterId)
    + (groups ? " · " + escapeHtml(groups) : "") + "</div>"
    + "<div>" + escapeHtml(turn.turnReason || "—") + "</div>"
    + '<div class="tt-meta">' + escapeHtml(formatGameTime(turn.startGameTime))
    + " → " + escapeHtml(formatGameTime(turn.endGameTime)) + "</div>"
    + '<div class="tt-meta">游戏时长 ' + escapeHtml(formatGameDuration(turn.startGameTime, turn.endGameTime))
    + " (实际 " + escapeHtml(formatDuration(endMs - startMs)) + ")</div>"
    + '<div class="tt-meta">' + turn.msgCount + " msg · " + turn.llmCallCount + " LLM · "
    + turn.toolCallCount + " tool"
    + (turn.hasError ? ' · <span style="color:var(--error)">error</span>' : "")
    + "</div>"
    + '<div class="tt-meta">同 session 工具：' + sessionToolSummary + "</div>"
    + '<div class="tt-meta">tokens: 本 turn ' + escapeHtml(turnTokens)
    + " · NPC累计 " + escapeHtml(npcTokens)
    + " · 截至此 turn " + escapeHtml(npcTokensAtTurn)
    + (turn.npcTurnIndex > 0 && turn.npcTurnCount > 0 ? " · turn " + turn.npcTurnIndex + "/" + turn.npcTurnCount : "")
    + "</div>"
    + '<div class="tt-meta">cost: 本 turn ' + escapeHtml(turnCost)
    + " · NPC累计 " + escapeHtml(npcCost)
    + " · 截至此 turn " + escapeHtml(npcCostAtTurn)
    + "</div>";
  if (turn.isInterruptContinuation) {
    html += '<div class="tt-meta">由打断插入，已连回上一段 turn</div>';
  }
  showTooltip(app, event, html);
}

function showThinkingTooltip(app, event, thinking) {
  const displayName = getCharacterDisplayName(app, thinking.characterId, thinking.townId);
  const tokens = thinking.totalTokens != null ? formatTokenCount(thinking.totalTokens) : "—";
  const cost = thinking.costUsd != null ? formatCostUsd(thinking.costUsd) : "—";
  const status = thinking.hasError
    ? '<span style="color:var(--error)">error</span>'
    : (thinking.hasWritten ? "wrote working_memory" : "no write");
  const html = ""
    + '<div class="tt-name">[思考] ' + escapeHtml(displayName) + "</div>"
    + '<div class="tt-meta">' + escapeHtml(thinking.characterId) + " · " + escapeHtml(thinking.modelId || "—") + "</div>"
    + "<div>" + escapeHtml(thinking.triggerReason || "—") + "</div>"
    + (thinking.intent ? '<div class="tt-meta">intent: ' + escapeHtml(thinking.intent) + "</div>" : "")
    + '<div class="tt-meta">' + escapeHtml(formatGameTime(thinking.startGameTime)) + "</div>"
    + '<div class="tt-meta">' + escapeHtml(tokens) + " · " + escapeHtml(cost) + " · " + status + "</div>";
  showTooltip(app, event, html);
}

function renderToolCallSummary(toolCallSummary) {
  const list = Array.isArray(toolCallSummary) ? toolCallSummary : [];
  if (list.length === 0) return "";
  return list.map((item) => {
    const name = item && item.name ? String(item.name) : "unknown";
    const count = Number.isFinite(item && item.count) ? item.count : 0;
    const errorCount = Number.isFinite(item && item.errorCount) ? item.errorCount : 0;
    let text = name + (count > 1 ? " x" + count : "");
    if (errorCount > 0) text += " (error " + errorCount + ")";
    return escapeHtml(text);
  }).join("、");
}

function summarizeSessionToolCalls(app, sessionId) {
  const totals = new Map();
  for (const turn of app.state.turns || []) {
    if (turn.sessionId !== sessionId || !Array.isArray(turn.toolCallSummary)) continue;
    for (const item of turn.toolCallSummary) {
      const name = item && item.name ? String(item.name) : "unknown";
      const count = Number.isFinite(item && item.count) ? item.count : 0;
      const errorCount = Number.isFinite(item && item.errorCount) ? item.errorCount : 0;
      const existing = totals.get(name) || { name, count: 0, errorCount: 0 };
      existing.count += count;
      existing.errorCount += errorCount;
      totals.set(name, existing);
    }
  }
  return Array.from(totals.values()).sort((a, b) => {
    if (b.count !== a.count) return b.count - a.count;
    return a.name.localeCompare(b.name);
  });
}
`;
