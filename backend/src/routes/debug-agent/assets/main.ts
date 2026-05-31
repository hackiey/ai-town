export const DEBUG_AGENT_MAIN_MODULE = String.raw`
import { createAnalyticsView } from "./analytics.js";
import { renderDetailBody, renderDetailError, renderDetailHeader, renderDetailLoading, renderDetailPlaceholder, renderThinkingDetail } from "./detail.js";
import { renderGroupFilterPop, renderNpcFilterPop, renderTopbarInfo } from "./filters.js";
import { applyAgentRunFilterPayload, createDebugAgentApp, rebuildMetadataIndex, pruneSelectionSet, saveAgentRunFilter, setAgentRunCharacterEnabled } from "./shared.js";
import {
  captureTimelineViewport,
  hideTooltip,
  renderTimeline,
  restoreTimelineViewport,
  rerenderTimelinePreserveViewport,
  setTimelineZoomIndex,
  showTooltip,
  updateTimelineZoomUi,
} from "./timeline.js";
import { formatGameDayLabel, gameDayIndex } from "./time.js";

function renderGameDayFilterOptions(app) {
  const select = app.$("game-day-filter");
  if (!select) return;
  const days = new Map();
  for (const turn of app.state.turns) {
    const day = gameDayIndex(turn.startGameTime);
    if (day != null && !days.has(day)) days.set(day, formatGameDayLabel(day));
  }
  for (const thinking of (app.state.thinkingTurns || [])) {
    const day = gameDayIndex(thinking.startGameTime);
    if (day != null && !days.has(day)) days.set(day, formatGameDayLabel(day));
  }
  const sorted = Array.from(days.entries()).sort((a, b) => b[0] - a[0]);
  const current = app.state.selectedGameDay || "";
  const hasCurrent = sorted.some(([day]) => String(day) === current);
  if (current && !hasCurrent) app.state.selectedGameDay = "";

  let html = '<option value="">全部</option>';
  for (const [day, label] of sorted) {
    const selected = String(day) === (app.state.selectedGameDay || "") ? " selected" : "";
    html += '<option value="' + day + '"' + selected + ">" + label + "</option>";
  }
  select.innerHTML = html;
}

const app = createDebugAgentApp();
const analytics = createAnalyticsView(app);
let currentView = "timeline";

analytics.setJumpHandler((payload) => {
  const sessionId = typeof payload === "string" ? payload : (payload && payload.sessionId) || "";
  const seq = payload && typeof payload === "object" && Number.isFinite(payload.seq) ? payload.seq : null;
  switchView("timeline");
  app.state.pinnedSessionId = sessionId || "";
  app.state.pinnedMessageSeq = seq;
  void restorePinnedSessionSelection({ scrollIntoView: true });
});

function switchView(view) {
  if (currentView === view) return;
  currentView = view;
  const timelinePane = app.$("view-timeline");
  const analyticsPane = app.$("view-analytics");
  const tabTimeline = app.$("tab-timeline");
  const tabAnalytics = app.$("tab-analytics");
  if (timelinePane) timelinePane.classList.toggle("active", view === "timeline");
  if (analyticsPane) analyticsPane.classList.toggle("active", view === "analytics");
  if (tabTimeline) tabTimeline.classList.toggle("active", view === "timeline");
  if (tabAnalytics) tabAnalytics.classList.toggle("active", view === "analytics");
  if (view === "analytics") {
    void analytics.load();
  }
}

function renderTimelineWithSelection() {
  renderTimeline(app, {
    onSelectTurn: selectTurn,
    onSelectThinking: selectThinking,
    onAgentRunToggle: (characterId, enabled) => {
      setAgentRunCharacterEnabled(app, characterId, enabled);
      void saveAgentRunFilter(app);
    },
  });
}

function buildFilterParams() {
  const params = new URLSearchParams();
  if (app.state.townFilter) params.set("townId", app.state.townFilter);
  if (app.state.selectedCharacterIds.size > 0) {
    params.set("characterIds", Array.from(app.state.selectedCharacterIds).join(","));
  }
  if (app.state.selectedGroupIds.size > 0) {
    params.set("groupIds", Array.from(app.state.selectedGroupIds).join(","));
  }
  const since = computeSince();
  if (since) params.set("since", since);
  return params;
}

function buildTurnsUrl() {
  const params = buildFilterParams();
  params.set("limit", "2000");
  return "/debug/api/turns?" + params.toString();
}

function buildThinkingTurnsUrl() {
  const params = buildFilterParams();
  params.set("limit", "2000");
  return "/debug/api/thinking-turns?" + params.toString();
}

function computeSince() {
  const preset = app.state.timeRangePreset;
  if (preset === "all") return null;
  const ms = {
    "1h": 3600e3,
    "6h": 6 * 3600e3,
    "24h": 24 * 3600e3,
    "7d": 7 * 24 * 3600e3,
  }[preset];
  if (!ms) return null;
  return new Date(Date.now() - ms).toISOString();
}

async function loadTurns(options) {
  const preserveViewport = !!(options && options.preserveViewport);
  const viewport = preserveViewport ? captureTimelineViewport(app) : null;
  const [turnsRes, thinkingRes] = await Promise.all([
    fetch(buildTurnsUrl()).then((response) => response.json()),
    fetch(buildThinkingTurnsUrl()).then((response) => response.json()).catch(() => ({ thinkingTurns: [] })),
  ]);
  app.state.turns = turnsRes.turns || [];
  app.state.characters = turnsRes.characters || [];
  app.state.groups = turnsRes.groups || [];
  app.state.truncated = !!turnsRes.truncated;
  app.state.thinkingTurns = Array.isArray(thinkingRes.thinkingTurns) ? thinkingRes.thinkingTurns : [];

  rebuildMetadataIndex(app);
  pruneSelectionSet(app.state.selectedCharacterIds, app.state.characters.map((item) => item.characterId));
  pruneSelectionSet(app.state.selectedGroupIds, app.state.groups.map((item) => item.groupId));

  renderTopbarInfo(app);
  renderNpcFilterPop(app, { onChange: () => { void loadTurns(); } });
  renderGroupFilterPop(app, { onChange: () => { void loadTurns(); } });
  renderGameDayFilterOptions(app);
  renderTimelineWithSelection();
  restoreTimelineViewport(app, viewport);
  if (currentView === "analytics") void analytics.load();
}

async function loadAgentRunFilter() {
  const payload = await fetch("/debug/api/agent-run-filter").then((response) => response.json());
  applyAgentRunFilterPayload(app, payload);
}

function updatePinnedSession(sessionId, seq) {
  app.state.pinnedSessionId = sessionId || "";
  const pinnedSeq = Number.isFinite(seq) ? seq : null;
  app.state.pinnedMessageSeq = pinnedSeq;
  const params = new URLSearchParams(window.location.hash.replace(/^#/, ""));
  if (app.state.pinnedSessionId) params.set("session", app.state.pinnedSessionId);
  else params.delete("session");
  if (pinnedSeq != null) params.set("seq", String(pinnedSeq));
  else params.delete("seq");
  const nextHash = params.toString();
  const nextUrl = window.location.pathname + window.location.search + (nextHash ? "#" + nextHash : "");
  window.history.replaceState(null, "", nextUrl);
}

function clearPinnedSession() {
  updatePinnedSession("", null);
}

function findLatestTurnInSession(sessionId) {
  let latest = null;
  for (const turn of app.state.turns) {
    if (turn.sessionId !== sessionId) continue;
    if (!latest) {
      latest = turn;
      continue;
    }
    const turnMs = Date.parse(turn.endedAt) || 0;
    const latestMs = Date.parse(latest.endedAt) || 0;
    if (turnMs > latestMs || (turnMs === latestMs && turn.startSeq > latest.startSeq)) {
      latest = turn;
    }
  }
  return latest;
}

function findTurnContainingSeq(sessionId, seq) {
  if (!Number.isFinite(seq)) return null;
  for (const turn of app.state.turns) {
    if (turn.sessionId !== sessionId) continue;
    if (turn.startSeq <= seq && seq <= turn.endSeq) return turn;
  }
  return null;
}

function scrollMessageIntoView(seq) {
  if (!Number.isFinite(seq)) return;
  window.requestAnimationFrame(() => {
    const body = app.$("detail-body");
    if (!body) return;
    const el = body.querySelector('.msg[data-message-seq="' + seq + '"]');
    if (!el) return;
    for (const node of body.querySelectorAll(".jump-target")) {
      node.classList.remove("jump-target");
    }
    el.classList.add("jump-target");
    el.scrollIntoView({ behavior: "smooth", block: "center", inline: "nearest" });
    window.setTimeout(() => {
      if (el.isConnected) el.classList.remove("jump-target");
    }, 1800);
  });
}

async function restorePinnedSessionSelection(options) {
  if (!app.state.pinnedSessionId) return false;
  const pinnedSeq = Number.isFinite(app.state.pinnedMessageSeq) ? app.state.pinnedMessageSeq : null;
  const turn = (pinnedSeq != null && findTurnContainingSeq(app.state.pinnedSessionId, pinnedSeq))
    || findLatestTurnInSession(app.state.pinnedSessionId);
  if (!turn) return false;
  await selectTurn(turn);
  if (options && options.scrollIntoView) scrollTurnIntoView(turn);
  if (pinnedSeq != null) scrollMessageIntoView(pinnedSeq);
  return true;
}

function scrollTurnIntoView(turn) {
  window.requestAnimationFrame(() => {
    const scroller = app.$("timeline-scroller");
    if (!scroller) return;
    for (const rect of scroller.querySelectorAll(".turn-bar")) {
      if (rect.dataset.session === turn.sessionId && Number(rect.dataset.start) === turn.startSeq) {
        rect.scrollIntoView({ block: "nearest", inline: "center" });
        break;
      }
    }
  });
}

async function loadAllSessionMessages(sessionId, session) {
  let beforeSeq = typeof (session && session.messageSeq) === "number"
    ? session.messageSeq + 1
    : Number.MAX_SAFE_INTEGER;
  let messages = [];
  let pageCount = 0;

  while (true) {
    const params = new URLSearchParams();
    params.set("limit", String(app.constants.SESSION_MESSAGE_PAGE_LIMIT));
    if (Number.isFinite(beforeSeq)) {
      params.set("beforeSeq", String(beforeSeq));
    }

    const page = await fetch(
      "/debug/api/sessions/" + encodeURIComponent(sessionId) + "/messages?" + params.toString(),
    ).then((response) => response.json());

    if (page.error) {
      return {
        error: page.error,
        messages,
        minSeq: messages.length > 0 ? messages[0].seq : undefined,
        maxSeq: messages.length > 0 ? messages[messages.length - 1].seq : undefined,
        pageCount,
      };
    }

    const chunk = Array.isArray(page.messages) ? page.messages : [];
    if (chunk.length === 0) {
      return {
        messages,
        minSeq: messages.length > 0 ? messages[0].seq : undefined,
        maxSeq: messages.length > 0 ? messages[messages.length - 1].seq : undefined,
        pageCount,
      };
    }

    messages = chunk.concat(messages);
    pageCount += 1;

    if (!page.hasMore || page.minSeq == null) {
      return {
        messages,
        minSeq: messages[0].seq,
        maxSeq: messages[messages.length - 1].seq,
        pageCount,
      };
    }

    beforeSeq = page.minSeq;
  }
}

async function selectTurn(turn) {
  app.state.selectedTurn = turn;
  app.state.selectedThinking = null;
  // 若已 pin 了一个 seq 且这个 turn 包含它，保留；否则清掉，避免把上一次的 seq 带到无关 turn 上
  const existingSeq = Number.isFinite(app.state.pinnedMessageSeq) ? app.state.pinnedMessageSeq : null;
  const preserveSeq = existingSeq != null
    && turn.sessionId === app.state.pinnedSessionId
    && turn.startSeq <= existingSeq
    && existingSeq <= turn.endSeq
    ? existingSeq
    : null;
  updatePinnedSession(turn.sessionId, preserveSeq);
  rerenderTimelinePreserveViewport(app, renderTimelineWithSelection);
  renderDetailHeader(app, turn, { onDelete: () => deleteSession(turn) });
  renderDetailLoading(app, "加载 turn 消息与 session 索引…");

  const [sessionRes, promptMemoryRes, memoryRes] = await Promise.all([
    fetch("/debug/api/sessions/" + encodeURIComponent(turn.sessionId)).then((response) => response.json()),
    fetch("/debug/api/sessions/" + encodeURIComponent(turn.sessionId) + "/prompt-memory").then((response) => response.json()),
    fetch("/debug/api/sessions/" + encodeURIComponent(turn.sessionId) + "/memory")
      .then((response) => response.json())
      .catch((error) => ({ error: String(error) })),
  ]);

  if (sessionRes.error) {
    renderDetailError(app, sessionRes.error);
    return;
  }

  const session = sessionRes.session;
  const messagesRes = await loadAllSessionMessages(turn.sessionId, session);
  if (messagesRes.error) {
    renderDetailError(app, messagesRes.error);
    return;
  }

  renderDetailBody(app, turn, session, messagesRes, promptMemoryRes, {
    showTooltip: (event, html) => showTooltip(app, event, html),
    hideTooltip: () => hideTooltip(app),
  }, {
    memory: memoryRes,
  });
}

async function selectThinking(thinking) {
  app.state.selectedTurn = null;
  app.state.selectedThinking = thinking;
  clearPinnedSession();
  rerenderTimelinePreserveViewport(app, renderTimelineWithSelection);
  renderDetailLoading(app, "加载 thinking 详情…");
  const detailRes = await fetch("/debug/api/thinking-turns/" + encodeURIComponent(thinking.id))
    .then((response) => response.json())
    .catch((error) => ({ error: String(error) }));
  if (detailRes.error) {
    renderDetailError(app, detailRes.error);
    return;
  }
  renderThinkingDetail(app, thinking, detailRes.thinkingTurn);
}

async function deleteSession(turn) {
  const ok = confirm(
    "将删除 session 「" + turn.characterId + "」(" + turn.agentKind + ")\\n"
    + "包含全部 agent_session_messages 行 + 1 行 agent_sessions。\\n\\n"
    + "注意：如果后端进程仍在运行，对应角色的 in-memory 思考队列不会清空，下次 think 会重新建表。要彻底重置请先重启 backend。\\n\\n确认删除？",
  );
  if (!ok) return;

  const result = await fetch(
    "/debug/api/sessions/" + encodeURIComponent(turn.sessionId) + "/delete",
    { method: "POST" },
  ).then((response) => response.json());

  if (result.error) {
    alert("删除失败: " + result.error);
    return;
  }

  app.state.selectedTurn = null;
  clearPinnedSession();
  renderDetailPlaceholder(app, "已删除：messages=" + result.deletedMessages + " session=" + result.deletedSession);
  await loadTurns();
}

async function clearAllAgentData() {
  const ok = confirm(
    "将 truncate 三张表：\\n"
    + "  - agent_sessions\\n"
    + "  - agent_session_messages\\n"
    + "  - runtime_storage(memory:*)\\n\\n"
    + "保留：action_log / world_events / character_groups。\\n\\n"
    + "注意：后端进程内存里 PiAgentRuntime 仍持有 in-memory session map，下次 think 会重新建行。要彻底重置请重启 backend。\\n\\n确认清空？",
  );
  if (!ok) return;

  const result = await fetch("/debug/api/agent-data/clear", { method: "POST" }).then((response) => response.json());
  app.state.selectedTurn = null;
  clearPinnedSession();
  renderDetailPlaceholder(
    app,
    "已清空：messages=" + result.deletedMessages
      + " sessions=" + result.deletedSessions
      + " memories=" + result.deletedMemories,
  );
  await loadTurns();
}

app.$("refresh-btn").addEventListener("click", async () => {
  await loadTurns({ preserveViewport: true });
  await restorePinnedSessionSelection();
  if (currentView === "analytics") void analytics.refresh();
});

app.$("tab-timeline").addEventListener("click", () => switchView("timeline"));
app.$("tab-analytics").addEventListener("click", () => switchView("analytics"));

let townFilterTimer = null;
app.$("filter-town").addEventListener("input", (event) => {
  clearTimeout(townFilterTimer);
  townFilterTimer = setTimeout(() => {
    app.state.townFilter = event.target.value.trim();
    void loadTurns();
  }, 250);
});

app.$("time-range").addEventListener("change", (event) => {
  app.state.timeRangePreset = event.target.value;
  void loadTurns();
});

app.$("game-day-filter").addEventListener("change", (event) => {
  app.state.selectedGameDay = event.target.value || "";
  rerenderTimelinePreserveViewport(app, renderTimelineWithSelection);
});

app.$("timeline-zoom").addEventListener("input", (event) => {
  setTimelineZoomIndex(app, renderTimelineWithSelection, Number(event.target.value));
});
app.$("timeline-zoom-out").addEventListener("click", () => {
  setTimelineZoomIndex(app, renderTimelineWithSelection, app.state.timelineZoomIndex - 1);
});
app.$("timeline-zoom-in").addEventListener("click", () => {
  setTimelineZoomIndex(app, renderTimelineWithSelection, app.state.timelineZoomIndex + 1);
});
app.$("timeline-zoom-reset").addEventListener("click", () => {
  setTimelineZoomIndex(app, renderTimelineWithSelection, 0);
});

app.$("npc-filter-btn").addEventListener("click", (event) => {
  event.stopPropagation();
  app.$("npc-filter-pop").classList.toggle("open");
  app.$("group-filter-pop").classList.remove("open");
});
app.$("group-filter-btn").addEventListener("click", (event) => {
  event.stopPropagation();
  app.$("group-filter-pop").classList.toggle("open");
  app.$("npc-filter-pop").classList.remove("open");
});
document.addEventListener("click", (event) => {
  const npcPop = app.$("npc-filter-pop");
  const groupPop = app.$("group-filter-pop");
  if (!npcPop.contains(event.target) && event.target !== app.$("npc-filter-btn")) {
    npcPop.classList.remove("open");
  }
  if (!groupPop.contains(event.target) && event.target !== app.$("group-filter-btn")) {
    groupPop.classList.remove("open");
  }
});

app.$("clear-all").addEventListener("click", () => { void clearAllAgentData(); });

app.$("auto-refresh").addEventListener("change", (event) => {
  if (app.state.autoTimer) {
    clearInterval(app.state.autoTimer);
    app.state.autoTimer = null;
  }
  if (event.target.checked) {
    app.state.autoTimer = setInterval(async () => {
      await loadTurns({ preserveViewport: true });
      await restorePinnedSessionSelection();
    }, 5000);
  }
});

app.$("timeline-wrap").addEventListener("wheel", (event) => {
  if (!(event.target instanceof Element) || !event.target.closest(".timeline-scroller, .timeline-labels")) return;
  if (!(event.ctrlKey || event.metaKey)) return;
  event.preventDefault();
  if (event.deltaY === 0) return;
  setTimelineZoomIndex(
    app,
    renderTimelineWithSelection,
    app.state.timelineZoomIndex + (event.deltaY < 0 ? 1 : -1),
    event.clientX,
  );
}, { passive: false });

window.addEventListener("resize", () => {
  if (app.state.turns.length > 0) {
    rerenderTimelinePreserveViewport(app, renderTimelineWithSelection);
  }
});

updateTimelineZoomUi(app);
void loadAgentRunFilter()
  .then(() => loadTurns())
  .then(() => restorePinnedSessionSelection({ scrollIntoView: true }));
`;
