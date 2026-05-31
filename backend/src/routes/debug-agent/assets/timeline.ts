export const DEBUG_AGENT_TIMELINE_MODULE = String.raw`
import {
  compareZhText,
  escapeHtml,
  formatCostUsd,
  formatTokenCount,
  getCharacterDisplayName,
  getCharacterGroupNames,
  getCharacterGroupSortKeyByKey,
  getCharacterTimelineLabelByKey,
  isAgentRunCharacterEnabled,
  makeCharacterKey,
} from "./shared.js";
import {
  computeGameTimeTicks,
  formatDuration,
  formatGameDuration,
  formatGameTime,
  gameDayIndex,
  gameTimeTotalMinutes,
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
  const zoom = getTimelineZoom(app);
  slider.max = String(app.constants.TIMELINE_ZOOM_LEVELS.length - 1);
  slider.value = String(app.state.timelineZoomIndex);
  app.$("timeline-zoom-label").textContent = Math.round(zoom * 100) + "%";
  app.$("timeline-zoom-out").disabled = app.state.timelineZoomIndex <= 0;
  app.$("timeline-zoom-in").disabled = (
    app.state.timelineZoomIndex >= app.constants.TIMELINE_ZOOM_LEVELS.length - 1
  );
}

export function captureTimelineViewport(app, clientX) {
  const scroller = app.$("timeline-scroller");
  if (!scroller) {
    return { focusRatio: 0.5, offsetPx: 0, scrollTop: 0 };
  }
  const rect = scroller.getBoundingClientRect();
  const localX = clientX == null
    ? scroller.clientWidth / 2
    : Math.max(0, Math.min(clientX - rect.left, scroller.clientWidth));
  return {
    focusRatio: scroller.scrollWidth > 0 ? (scroller.scrollLeft + localX) / scroller.scrollWidth : 0.5,
    offsetPx: localX,
    scrollTop: scroller.scrollTop,
  };
}

export function restoreTimelineViewport(app, viewport) {
  if (!viewport) return;
  window.requestAnimationFrame(() => {
    const scroller = app.$("timeline-scroller");
    const labels = app.$("timeline-labels");
    if (!scroller) return;
    scroller.scrollTop = viewport.scrollTop || 0;
    if (labels) labels.scrollTop = scroller.scrollTop;
    const maxScroll = Math.max(0, scroller.scrollWidth - scroller.clientWidth);
    const focusPx = viewport.focusRatio * scroller.scrollWidth;
    scroller.scrollLeft = Math.max(0, Math.min(focusPx - viewport.offsetPx, maxScroll));
  });
}

export function rerenderTimelinePreserveViewport(app, renderTimelineFn, clientX) {
  const viewport = captureTimelineViewport(app, clientX);
  renderTimelineFn();
  restoreTimelineViewport(app, viewport);
}

export function setTimelineZoomIndex(app, renderTimelineFn, nextIndex, clientX) {
  const clamped = Math.max(
    0,
    Math.min(app.constants.TIMELINE_ZOOM_LEVELS.length - 1, nextIndex),
  );
  if (clamped === app.state.timelineZoomIndex) {
    updateTimelineZoomUi(app);
    return;
  }
  app.state.timelineZoomIndex = clamped;
  updateTimelineZoomUi(app);
  if (app.state.turns.length > 0) {
    rerenderTimelinePreserveViewport(app, renderTimelineFn, clientX);
  }
}

export function renderTimeline(app, handlers) {
  const wrap = app.$("timeline-wrap");
  const selectedDay = app.state.selectedGameDay || "";
  const visibleTurns = app.state.turns.filter((turn) => turnMatchesSelectedDay(turn, selectedDay));
  const visibleThinking = (app.state.thinkingTurns || []).filter((item) => thinkingMatchesSelectedDay(item, selectedDay));
  const dayFilterActive = !!selectedDay;
  const emptyMessage = dayFilterActive ? "当前游戏日期没有 turn 数据" : "没有 turn 数据";

  const rowKeySet = new Set(app.state.characters.map((character) => makeCharacterKey(character.townId, character.characterId)));
  for (const turn of visibleTurns) {
    rowKeySet.add(makeCharacterKey(turn.townId, turn.characterId));
  }
  const rowKeys = Array.from(rowKeySet).sort((a, b) => {
    const ak = getCharacterGroupSortKeyByKey(app, a);
    const bk = getCharacterGroupSortKeyByKey(app, b);
    if (ak && !bk) return -1;
    if (!ak && bk) return 1;
    const cmp = compareZhText(ak, bk);
    if (cmp !== 0) return cmp;
    return compareZhText(
      getCharacterTimelineLabelByKey(app, a),
      getCharacterTimelineLabelByKey(app, b),
    );
  });
  if (visibleTurns.length === 0) {
    if (rowKeys.length === 0) {
      wrap.innerHTML = '<div class="timeline-empty">' + escapeHtml(emptyMessage) + "</div>";
      return;
    }
    renderLabelsOnlyTimeline(app, handlers, wrap, rowKeys, emptyMessage);
    return;
  }
  const rowIndex = new Map(rowKeys.map((key, index) => [key, index]));

  let minGame = Infinity;
  let maxGame = -Infinity;
  for (const turn of visibleTurns) {
    const range = turnGameRange(turn);
    if (!range) continue;
    if (range.start < minGame) minGame = range.start;
    if (range.end > maxGame) maxGame = range.end;
  }
  for (const thinking of visibleThinking) {
    const minute = gameTimeTotalMinutes(thinking.startGameTime);
    if (minute == null) continue;
    if (minute < minGame) minGame = minute;
    if (minute > maxGame) maxGame = minute;
  }

  if (!Number.isFinite(minGame) || !Number.isFinite(maxGame)) {
    renderLabelsOnlyTimeline(app, handlers, wrap, rowKeys, "没有可用 gameTime 的 turn 数据");
    return;
  }
  if (minGame === maxGame) {
    minGame -= 1;
    maxGame += 1;
  } else {
    const pad = (maxGame - minGame) * 0.05;
    minGame -= pad;
    maxGame += pad;
  }

  const scroller = app.$("timeline-scroller");
  const availableWidth = scroller
    ? scroller.clientWidth
    : Math.max(0, (wrap.clientWidth || 0) - app.constants.LABEL_W - 1);
  const baseW = Math.max(240, availableWidth || 480);
  const width = Math.max(baseW, Math.round(baseW * getTimelineZoom(app)));
  const innerW = Math.max(1, width - app.constants.TIMELINE_PAD_X * 2);
  const rowAreaH = rowKeys.length * app.constants.ROW_HEIGHT;
  const height = rowAreaH + app.constants.AXIS_H;

  const gameToX = (value) => {
    if (!Number.isFinite(value)) return app.constants.TIMELINE_PAD_X;
    return app.constants.TIMELINE_PAD_X
      + ((value - minGame) / (maxGame - minGame)) * innerW;
  };

  const turnsByNpc = new Map();
  for (const turn of visibleTurns) {
    const rowKey = makeCharacterKey(turn.townId, turn.characterId);
    if (!turnsByNpc.has(rowKey)) turnsByNpc.set(rowKey, []);
    turnsByNpc.get(rowKey).push(turn);
  }

  const colorIndex = new Map();
  const sessionLinks = [];
  for (const list of turnsByNpc.values()) {
    list.sort(compareTurnGameStart);
    let altIndex = 0;
    for (let index = 0; index < list.length; index += 1) {
      const turn = list[index];
      const prev = index > 0 ? list[index - 1] : null;
      const continuesPrevious = !!prev
        && turn.isInterruptContinuation
        && prev.sessionId === turn.sessionId;
      if (index > 0 && !continuesPrevious) {
        altIndex = (altIndex + 1) % 2;
      }
      colorIndex.set(turn.sessionId + "#" + turn.startSeq, altIndex);
      if (continuesPrevious) {
        sessionLinks.push({ from: prev, to: turn, altIndex });
      }
    }
  }

  const parts = [];
  parts.push('<div class="timeline-shell" style="--timeline-label-w:' + app.constants.LABEL_W + 'px">');
  parts.push(buildTimelineLabelsHtml(app, rowKeys, height));
  parts.push('<div id="timeline-scroller" class="timeline-scroller">');
  parts.push('<svg class="timeline-svg" width="' + width + '" height="' + height + '" xmlns="http://www.w3.org/2000/svg">');

  for (let index = 0; index < rowKeys.length; index += 1) {
    const y = index * app.constants.ROW_HEIGHT;
    parts.push('<rect class="row-bg" x="0" y="' + y + '" width="' + width + '" height="' + app.constants.ROW_HEIGHT + '" />');
    parts.push('<line class="row-divider" x1="0" y1="' + (y + app.constants.ROW_HEIGHT)
      + '" x2="' + width + '" y2="' + (y + app.constants.ROW_HEIGHT) + '" />');
  }

  const ticks = computeGameTimeTicks(minGame, maxGame, Math.max(4, Math.floor(innerW / app.constants.TIMELINE_TICK_PX)));
  for (const tick of ticks) {
    const x = gameToX(tick.gameMinutes);
    parts.push('<line class="grid" x1="' + x + '" y1="0" x2="' + x + '" y2="' + rowAreaH + '" stroke-dasharray="2 3" />');
    parts.push('<line class="axis-tick" x1="' + x + '" y1="' + rowAreaH + '" x2="' + x + '" y2="' + (rowAreaH + 4) + '" />');
    parts.push('<text class="axis-text" x="' + (x + 2) + '" y="' + (rowAreaH + 14) + '">' + escapeHtml(tick.label) + "</text>");
  }

  for (const link of sessionLinks) {
    const rowI = rowIndex.get(makeCharacterKey(link.from.townId, link.from.characterId));
    if (rowI == null) continue;
    const fromRange = turnGameRange(link.from);
    const toRange = turnGameRange(link.to);
    if (!fromRange || !toRange) continue;
    const x1 = gameToX(fromRange.end);
    const x2 = gameToX(toRange.start);
    if (!(x2 > x1)) continue;
    const y = rowI * app.constants.ROW_HEIGHT + app.constants.ROW_HEIGHT / 2;
    const isSelected = app.state.selectedTurn
      && app.state.selectedTurn.sessionId === link.to.sessionId
      && (
        app.state.selectedTurn.startSeq === link.from.startSeq
        || app.state.selectedTurn.startSeq === link.to.startSeq
      );
    parts.push(
      '<line class="session-link' + (isSelected ? " selected" : "") + '"'
      + ' x1="' + Math.max(0, x1 - 1) + '" y1="' + y + '"'
      + ' x2="' + (x2 + 1) + '" y2="' + y + '"'
      + ' stroke="' + turnColor(link.to, link.altIndex) + '"></line>',
    );
  }

  for (const turn of visibleTurns) {
    const rowI = rowIndex.get(makeCharacterKey(turn.townId, turn.characterId));
    if (rowI == null) continue;
    const range = turnGameRange(turn);
    if (!range) continue;
    const y = rowI * app.constants.ROW_HEIGHT + 2;
    const x1 = gameToX(range.start);
    const x2 = gameToX(range.end);
    const rectWidth = Math.max(2, x2 - x1);
    const idx = colorIndex.get(turn.sessionId + "#" + turn.startSeq) || 0;
    const fill = turnColor(turn, idx);
    const isSelected = app.state.selectedTurn
      && app.state.selectedTurn.sessionId === turn.sessionId
      && app.state.selectedTurn.startSeq === turn.startSeq;
    const className = "turn-bar" + (turn.hasError ? " error" : "") + (isSelected ? " selected" : "");
    parts.push(
      '<rect class="' + className + '"'
      + ' data-session="' + escapeHtml(turn.sessionId) + '"'
      + ' data-start="' + turn.startSeq + '"'
      + ' data-end="' + turn.endSeq + '"'
      + ' x="' + x1 + '" y="' + y + '"'
      + ' width="' + rectWidth + '" height="' + (app.constants.ROW_HEIGHT - 4) + '"'
      + ' fill="' + fill + '" stroke="' + fill + '"></rect>',
    );
  }

  const thinkingMarkers = [];
  for (const thinking of visibleThinking) {
    const rowI = rowIndex.get(makeCharacterKey(thinking.townId, thinking.characterId));
    if (rowI == null) continue;
    const minute = gameTimeTotalMinutes(thinking.startGameTime);
    if (minute == null) continue;
    const cx = gameToX(minute);
    const cy = rowI * app.constants.ROW_HEIGHT + app.constants.ROW_HEIGHT / 2;
    const halfSize = Math.max(3, Math.floor((app.constants.ROW_HEIGHT - 6) / 2));
    const isSelected = app.state.selectedThinking && app.state.selectedThinking.id === thinking.id;
    const className = "thinking-marker"
      + (thinking.hasError ? " error" : "")
      + (isSelected ? " selected" : "");
    const points = ""
      + cx + "," + (cy - halfSize) + " "
      + (cx + halfSize) + "," + cy + " "
      + cx + "," + (cy + halfSize) + " "
      + (cx - halfSize) + "," + cy;
    parts.push(
      '<polygon class="' + className + '"'
      + ' data-thinking-id="' + escapeHtml(thinking.id) + '"'
      + ' points="' + points + '"></polygon>',
    );
    thinkingMarkers.push(thinking);
  }

  parts.push("</svg>");
  parts.push("</div>");
  parts.push("</div>");
  wrap.innerHTML = parts.join("");

  const labels = app.$("timeline-labels");
  const timelineScroller = app.$("timeline-scroller");
  if (!timelineScroller) return;
  bindTimelineScrollSync(app, labels, timelineScroller);
  bindAgentRunCheckboxes(labels, handlers);
  for (const rect of timelineScroller.querySelectorAll(".turn-bar")) {
    const sessionId = rect.dataset.session;
    const startSeq = Number(rect.dataset.start);
    const turn = app.state.turns.find((item) => item.sessionId === sessionId && item.startSeq === startSeq);
    if (!turn) continue;
    rect.addEventListener("click", () => { void handlers.onSelectTurn(turn); });
    rect.addEventListener("mousemove", (event) => showOuterTooltip(app, event, turn));
    rect.addEventListener("mouseleave", () => hideTooltip(app));
  }
  for (const node of timelineScroller.querySelectorAll(".thinking-marker")) {
    const thinkingId = node.dataset.thinkingId;
    const thinking = (app.state.thinkingTurns || []).find((item) => item.id === thinkingId);
    if (!thinking || !handlers.onSelectThinking) continue;
    node.addEventListener("click", () => { void handlers.onSelectThinking(thinking); });
    node.addEventListener("mousemove", (event) => showThinkingTooltip(app, event, thinking));
    node.addEventListener("mouseleave", () => hideTooltip(app));
  }
}

export function showTooltip(app, event, html) {
  const tt = app.$("tt");
  tt.innerHTML = html;
  tt.classList.add("show");
  const x = Math.min(window.innerWidth - 380, event.clientX + 14);
  const y = Math.min(window.innerHeight - tt.offsetHeight - 10, event.clientY + 14);
  tt.style.left = x + "px";
  tt.style.top = y + "px";
}

export function hideTooltip(app) {
  app.$("tt").classList.remove("show");
}

function renderLabelsOnlyTimeline(app, handlers, wrap, rowKeys, message) {
  const rowAreaH = rowKeys.length * app.constants.ROW_HEIGHT;
  const height = rowAreaH + app.constants.AXIS_H;
  const parts = [];
  parts.push('<div class="timeline-shell" style="--timeline-label-w:' + app.constants.LABEL_W + 'px">');
  parts.push(buildTimelineLabelsHtml(app, rowKeys, height));
  parts.push('<div id="timeline-scroller" class="timeline-scroller"><div class="timeline-empty" style="min-height:' + height + 'px">' + escapeHtml(message) + "</div></div>");
  parts.push("</div>");
  wrap.innerHTML = parts.join("");
  const labels = app.$("timeline-labels");
  const timelineScroller = app.$("timeline-scroller");
  bindTimelineScrollSync(app, labels, timelineScroller);
  bindAgentRunCheckboxes(labels, handlers);
}

function buildTimelineLabelsHtml(app, rowKeys, height) {
  const parts = [];
  parts.push('<div id="timeline-labels" class="timeline-labels">');
  parts.push('<div class="timeline-label-list" style="height:' + height + 'px">');
  for (let index = 0; index < rowKeys.length; index += 1) {
    const characterId = characterIdFromRowKey(rowKeys[index]);
    const checked = isAgentRunCharacterEnabled(app, characterId) ? " checked" : "";
    parts.push('<div class="timeline-label-row" style="height:' + app.constants.ROW_HEIGHT + 'px">'
      + '<input class="agent-run-checkbox" type="checkbox" data-character="' + escapeHtml(characterId) + '"'
      + ' title="勾选后允许该角色运行 Agent"' + checked + ' />'
      + '<span class="timeline-label-text">' + escapeHtml(getCharacterTimelineLabelByKey(app, rowKeys[index])) + "</span>"
      + "</div>");
  }
  parts.push('<div class="timeline-label-axis" style="height:' + app.constants.AXIS_H + 'px"></div>');
  parts.push("</div>");
  parts.push("</div>");
  return parts.join("");
}

function bindAgentRunCheckboxes(labels, handlers) {
  if (!labels) return;
  for (const checkbox of labels.querySelectorAll(".agent-run-checkbox")) {
    checkbox.addEventListener("click", (event) => event.stopPropagation());
    checkbox.addEventListener("change", (event) => {
      const characterId = event.target.dataset.character;
      if (!characterId || !handlers.onAgentRunToggle) return;
      handlers.onAgentRunToggle(characterId, event.target.checked);
    });
  }
}

function bindTimelineScrollSync(app, labels, timelineScroller) {
  if (!timelineScroller) return;
  if (labels) {
    labels.scrollTop = timelineScroller.scrollTop;
    labels.addEventListener("wheel", (event) => {
      if (event.ctrlKey || event.metaKey) return;
      const deltaY = normalizeWheelDelta(
        event.deltaY,
        event.deltaMode,
        app.constants.ROW_HEIGHT,
        timelineScroller.clientHeight,
      );
      const deltaX = normalizeWheelDelta(
        event.deltaX,
        event.deltaMode,
        app.constants.ROW_HEIGHT,
        timelineScroller.clientWidth,
      );
      if (deltaY === 0 && deltaX === 0) return;
      timelineScroller.scrollTop += deltaY;
      timelineScroller.scrollLeft += deltaX;
      labels.scrollTop = timelineScroller.scrollTop;
      event.preventDefault();
    }, { passive: false });

    let touchX = null;
    let touchY = null;
    labels.addEventListener("touchstart", (event) => {
      if (event.touches.length !== 1) return;
      touchX = event.touches[0].clientX;
      touchY = event.touches[0].clientY;
    }, { passive: true });
    labels.addEventListener("touchmove", (event) => {
      if (event.touches.length !== 1 || touchX == null || touchY == null) return;
      const touch = event.touches[0];
      timelineScroller.scrollTop += touchY - touch.clientY;
      timelineScroller.scrollLeft += touchX - touch.clientX;
      labels.scrollTop = timelineScroller.scrollTop;
      touchX = touch.clientX;
      touchY = touch.clientY;
      event.preventDefault();
    }, { passive: false });
    labels.addEventListener("touchend", () => {
      touchX = null;
      touchY = null;
    }, { passive: true });
    labels.addEventListener("touchcancel", () => {
      touchX = null;
      touchY = null;
    }, { passive: true });
  }

  timelineScroller.addEventListener("scroll", () => {
    if (labels) labels.scrollTop = timelineScroller.scrollTop;
  }, { passive: true });
}

function normalizeWheelDelta(delta, mode, lineSize, viewportSize) {
  if (!delta) return 0;
  if (mode === 1) return delta * lineSize;
  if (mode === 2) return delta * viewportSize;
  return delta;
}

function getTimelineZoom(app) {
  return app.constants.TIMELINE_ZOOM_LEVELS[app.state.timelineZoomIndex] || 1;
}

function characterIdFromRowKey(rowKey) {
  const separatorIndex = rowKey.indexOf("\u0000");
  return separatorIndex >= 0 ? rowKey.slice(separatorIndex + 1) : rowKey;
}

function turnGameRange(turn) {
  const start = gameTimeTotalMinutes(turn.startGameTime);
  if (start == null) return null;
  const end = gameTimeTotalMinutes(turn.endGameTime) ?? start;
  return { start, end: Math.max(start, end) };
}

function compareTurnGameStart(a, b) {
  const aRange = turnGameRange(a);
  const bRange = turnGameRange(b);
  if (aRange && bRange && aRange.start !== bRange.start) return aRange.start - bRange.start;
  if (aRange && !bRange) return -1;
  if (!aRange && bRange) return 1;
  const realCompare = Date.parse(a.startedAt) - Date.parse(b.startedAt);
  if (Number.isFinite(realCompare) && realCompare !== 0) return realCompare;
  return a.startSeq - b.startSeq;
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
  const sessionToolSummary = renderToolCallSummary(summarizeSessionToolCalls(app, turn.sessionId));
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
    + '<div>' + escapeHtml(thinking.triggerReason || "—") + "</div>"
    + (thinking.intent ? '<div class="tt-meta">intent: ' + escapeHtml(thinking.intent) + "</div>" : "")
    + '<div class="tt-meta">' + escapeHtml(formatGameTime(thinking.startGameTime)) + "</div>"
    + '<div class="tt-meta">' + escapeHtml(tokens) + " · " + escapeHtml(cost) + " · " + status + "</div>";
  showTooltip(app, event, html);
}

function renderToolCallSummary(toolCallSummary) {
  const list = Array.isArray(toolCallSummary) ? toolCallSummary : [];
  if (list.length === 0) return "—";
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

function turnColor(turn, altIndex) {
  if (turn.hasError) return "var(--turn-error)";
  const reason = (turn.turnReason || "").toLowerCase();
  if (reason.includes("interrupt")) return altIndex === 0 ? "#8c6d4a" : "#b08960";
  if (reason.includes("player")) return altIndex === 0 ? "#6d4a8c" : "#8a60b0";
  return altIndex === 0 ? "#4a6d8c" : "#6090b3";
}
`;
