export const DEBUG_AGENT_SHARED_MODULE = String.raw`
export function createDebugAgentApp() {
  const initialHashParams = new URLSearchParams(window.location.hash.replace(/^#/, ""));
  return {
    state: {
      turns: [],
      characters: [],
      groups: [],
      townFilter: "",
      selectedCharacterIds: new Set(),
      selectedGroupIds: new Set(),
      agentRunFilterConfigured: false,
      enabledAgentCharacterIds: new Set(),
      timeRangePreset: "6h",
      selectedGameDay: "",
      selectedTurn: null,
      selectedThinking: null,
      thinkingTurns: [],
      pinnedSessionId: initialHashParams.get("session") || "",
      pinnedMessageSeq: (() => {
        const raw = initialHashParams.get("seq");
        if (!raw) return null;
        const n = Number(raw);
        return Number.isFinite(n) ? n : null;
      })(),
      autoTimer: null,
      truncated: false,
      timelineZoomIndex: 0,
      characterMetaByKey: new Map(),
      characterMetaById: new Map(),
    },
    constants: {
      ROW_HEIGHT: 18,
      LABEL_W: 360,
      AXIS_H: 18,
      TIMELINE_PAD_X: 6,
      TIMELINE_ZOOM_LEVELS: [1, 1.5, 2, 3, 4, 6, 8, 12, 16],
      TIMELINE_TICK_PX: 150,
      SESSION_MESSAGE_PAGE_LIMIT: 5000,
    },
    $: (id) => document.getElementById(id),
  };
}

export function makeCharacterKey(townId, characterId) {
  return String(townId || "") + "\u0000" + String(characterId || "");
}

export function compareZhText(a, b) {
  return String(a || "").localeCompare(String(b || ""), "zh-Hans-CN");
}

export function rebuildMetadataIndex(app) {
  const state = app.state;
  state.characterMetaByKey = new Map();
  state.characterMetaById = new Map();

  for (const character of state.characters || []) {
    const groups = Array.isArray(character.groups) ? character.groups.slice() : [];
    groups.sort((a, b) => compareZhText(a.displayName || a.groupId, b.displayName || b.groupId));
    const normalized = {
      characterId: character.characterId,
      townId: character.townId,
      agentKind: character.agentKind,
      displayName: character.displayName || character.characterId,
      turnCount: Number.isFinite(character.turnCount) ? character.turnCount : 0,
      llmCallCount: Number.isFinite(character.llmCallCount) ? character.llmCallCount : 0,
      toolCallCount: Number.isFinite(character.toolCallCount) ? character.toolCallCount : 0,
      totalTokens: Number.isFinite(character.totalTokens) ? character.totalTokens : null,
      totalCostUsd: Number.isFinite(character.totalCostUsd) ? character.totalCostUsd : null,
      groups,
    };
    state.characterMetaByKey.set(
      makeCharacterKey(normalized.townId, normalized.characterId),
      normalized,
    );
    if (!state.characterMetaById.has(normalized.characterId)) {
      state.characterMetaById.set(normalized.characterId, normalized);
    }
  }
}

export function pruneSelectionSet(selection, validIds) {
  const valid = new Set(validIds || []);
  for (const id of Array.from(selection)) {
    if (!valid.has(id)) selection.delete(id);
  }
}

export function applyAgentRunFilterPayload(app, payload) {
  app.state.agentRunFilterConfigured = !!(payload && payload.configured);
  app.state.enabledAgentCharacterIds = new Set(
    Array.isArray(payload && payload.characterIds) ? payload.characterIds : [],
  );
}

export function isAgentRunCharacterEnabled(app, characterId) {
  return !app.state.agentRunFilterConfigured || app.state.enabledAgentCharacterIds.has(characterId);
}

export function setAgentRunCharacterEnabled(app, characterId, enabled) {
  ensureAgentRunFilterConfigured(app);
  if (enabled) app.state.enabledAgentCharacterIds.add(characterId);
  else app.state.enabledAgentCharacterIds.delete(characterId);
}

export async function saveAgentRunFilter(app) {
  const response = await fetch("/debug/api/agent-run-filter", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ characterIds: Array.from(app.state.enabledAgentCharacterIds) }),
  });
  const payload = await response.json();
  if (payload && !payload.error) {
    applyAgentRunFilterPayload(app, payload);
  }
}

function ensureAgentRunFilterConfigured(app) {
  if (app.state.agentRunFilterConfigured) return;
  app.state.agentRunFilterConfigured = true;
  app.state.enabledAgentCharacterIds = new Set(currentCharacterIds(app));
}

function currentCharacterIds(app) {
  return Array.from(new Set(app.state.characters.map((character) => character.characterId).filter(Boolean)));
}

export function getCharacterMeta(app, characterId, townId) {
  return app.state.characterMetaByKey.get(makeCharacterKey(townId, characterId))
    || app.state.characterMetaById.get(characterId)
    || null;
}

export function formatGroupNames(groups) {
  const list = Array.isArray(groups) ? groups : [];
  return list
    .map((group) => group.displayName || group.groupId || "")
    .filter(Boolean)
    .join("、");
}

export function getGroupSortKey(groups) {
  const list = Array.isArray(groups) ? groups.slice() : [];
  const names = list
    .map((group) => group.displayName || group.groupId || "")
    .filter(Boolean);
  names.sort((a, b) => compareZhText(a, b));
  return names.join("");
}

export function getCharacterGroupSortKeyByKey(app, rowKey) {
  const meta = app.state.characterMetaByKey.get(rowKey);
  return meta ? getGroupSortKey(meta.groups) : "";
}

export function getCharacterDisplayName(app, characterId, townId) {
  const meta = getCharacterMeta(app, characterId, townId);
  return (meta && meta.displayName) || characterId;
}

export function getCharacterGroupNames(app, characterId, townId) {
  const meta = getCharacterMeta(app, characterId, townId);
  return Array.isArray(meta && meta.groups)
    ? meta.groups.map((group) => group.displayName || group.groupId).filter(Boolean)
    : [];
}

export function getCharacterTimelineLabelByKey(app, rowKey) {
  const meta = app.state.characterMetaByKey.get(rowKey);
  if (!meta) return rowKey;
  const groupText = formatGroupNames(meta.groups);
  const stats = [];
  if (meta.turnCount > 0) stats.push(meta.turnCount + " turns");
  if (meta.totalTokens != null) stats.push(formatTokenCount(meta.totalTokens));
  if (meta.totalCostUsd != null) stats.push(formatCostUsd(meta.totalCostUsd));
  const suffix = stats.concat(groupText ? [groupText] : []).join(" · ");
  return suffix ? meta.displayName + " · " + suffix : meta.displayName;
}

export function formatRealTime(iso) {
  if (!iso) return "";
  try {
    const d = new Date(iso);
    const pad = (n) => String(n).padStart(2, "0");
    return pad(d.getMonth() + 1) + "/" + pad(d.getDate()) + " "
      + pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds());
  } catch {
    return iso;
  }
}

export function truncate(value, limit) {
  if (value == null) return "";
  const text = String(value);
  return text.length > limit ? text.slice(0, limit) + "…" : text;
}

export function prettyJson(value) {
  try {
    if (typeof value === "string") {
      const trimmed = value.trim();
      if (
        (trimmed.startsWith("{") && trimmed.endsWith("}"))
        || (trimmed.startsWith("[") && trimmed.endsWith("]"))
      ) {
        return JSON.stringify(JSON.parse(trimmed), null, 2);
      }
      return value;
    }
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

export function escapeHtml(text) {
  if (text == null) return "";
  return String(text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

export function extractText(content) {
  if (content == null) return "";
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.map((part) => {
      if (typeof part === "string") return part;
      if (!part || typeof part !== "object") return "";
      if (part.type === "text") return part.text || "";
      if (part.type === "tool_use" || part.type === "tool_result") return "";
      if (part.text) return part.text;
      return "";
    }).filter(Boolean).join("\\n");
  }
  if (typeof content === "object") {
    if (content.text) return content.text;
    return prettyJson(content);
  }
  return String(content);
}

export function extractReasoning(message) {
  if (!message) return "";
  if (typeof message.reasoning === "string") return message.reasoning;
  if (typeof message.thinking === "string") return message.thinking;
  if (Array.isArray(message.content)) {
    const parts = [];
    for (const part of message.content) {
      if (!part || typeof part !== "object") continue;
      if (part.type === "thinking" || part.type === "reasoning") {
        parts.push(part.thinking || part.reasoning || part.text || "");
      }
    }
    if (parts.length > 0) return parts.filter(Boolean).join("\\n");
  }
  return "";
}

export function extractToolCalls(message) {
  if (!message) return [];
  const calls = [];
  if (Array.isArray(message.toolCalls)) {
    for (const toolCall of message.toolCalls) calls.push(normalizeToolCall(toolCall));
  }
  if (Array.isArray(message.tool_calls)) {
    for (const toolCall of message.tool_calls) calls.push(normalizeToolCall(toolCall));
  }
  if (Array.isArray(message.content)) {
    for (const part of message.content) {
      if (!part || typeof part !== "object") continue;
      if (part.type === "tool_use" || part.type === "toolCall") {
        calls.push(normalizeToolCall(part));
      }
    }
  }
  return calls;
}

export function normalizeToolCall(toolCall) {
  const fn = toolCall.function || {};
  return {
    id: toolCall.id || toolCall.toolCallId || toolCall.tool_call_id || toolCall.call_id || "",
    name: toolCall.name || fn.name || "",
    args: toolCall.arguments ?? toolCall.args ?? toolCall.input ?? fn.arguments,
  };
}

export function formatTokenCount(value) {
  if (!Number.isFinite(value)) return "—";
  return formatCompactNumber(value) + " tok";
}

export function formatCostUsd(value) {
  if (!Number.isFinite(value)) return "—";
  const sign = value < 0 ? "-" : "";
  const abs = Math.abs(value);
  if (abs === 0) return "$0";
  if (abs < 0.000001) return sign + "$" + abs.toExponential(2);
  if (abs < 0.0001) return sign + "$" + trimFixedNumber(abs, 6);
  if (abs < 1) return sign + "$" + trimFixedNumber(abs, 4);
  return sign + "$" + trimFixedNumber(abs, 2);
}

function trimFixedNumber(value, digits) {
  return value.toFixed(digits).replace(/\.0+$/, "").replace(/(\.\d*?)0+$/, "$1");
}

export function formatCompactNumber(value) {
  if (!Number.isFinite(value)) return "—";
  const abs = Math.abs(value);
  if (abs >= 1000000) return trimCompactNumber(value / 1000000) + "m";
  if (abs >= 1000) return trimCompactNumber(value / 1000) + "k";
  return String(Math.round(value));
}

function trimCompactNumber(value) {
  return value.toFixed(value >= 10 ? 0 : 1).replace(/\.0$/, "");
}

export function tokenCountFromUsage(usage) {
  if (!usage || typeof usage !== "object") return null;
  const input = firstUsageNumber(usage, ["input", "inputTokens", "promptTokens", "prompt_tokens", "input_tokens"]);
  const output = firstUsageNumber(usage, ["output", "outputTokens", "completionTokens", "completion_tokens", "output_tokens"]);
  const cacheRead = firstUsageNumber(usage, ["cacheRead", "cache_read", "cacheReadTokens", "cache_read_tokens"]);
  const cacheWrite = firstUsageNumber(usage, ["cacheWrite", "cache_write", "cacheWriteTokens", "cache_write_tokens"]);
  const total = firstUsageNumber(usage, ["totalTokens", "total_tokens", "total"]);
  if (total != null) return total;
  if (input == null && output == null && cacheRead == null && cacheWrite == null) return null;
  return (input || 0) + (output || 0) + (cacheRead || 0) + (cacheWrite || 0);
}

export function costFromUsage(usage) {
  if (!usage || typeof usage !== "object") return null;
  const costValue = usage.cost;
  if (Number.isFinite(costValue)) return Math.max(0, costValue);
  if (!costValue || typeof costValue !== "object" || Array.isArray(costValue)) {
    return firstUsageCostNumber(usage, ["totalCost", "total_cost", "costUsd", "cost_usd"]);
  }
  const total = firstUsageCostNumber(costValue, ["total", "totalCost", "total_cost", "costUsd", "cost_usd"]);
  if (total != null) return total;
  const input = firstUsageCostNumber(costValue, ["input", "inputCost", "input_cost"]);
  const output = firstUsageCostNumber(costValue, ["output", "outputCost", "output_cost"]);
  const cacheRead = firstUsageCostNumber(costValue, ["cacheRead", "cache_read", "cacheReadCost", "cache_read_cost"]);
  const cacheWrite = firstUsageCostNumber(costValue, ["cacheWrite", "cache_write", "cacheWriteCost", "cache_write_cost"]);
  if (input == null && output == null && cacheRead == null && cacheWrite == null) return null;
  return (input || 0) + (output || 0) + (cacheRead || 0) + (cacheWrite || 0);
}

function firstUsageNumber(record, keys) {
  for (const key of keys) {
    const value = record[key];
    if (Number.isFinite(value)) return Math.max(0, Math.round(value));
  }
  return null;
}

function firstUsageCostNumber(record, keys) {
  for (const key of keys) {
    const value = record[key];
    if (Number.isFinite(value)) return Math.max(0, value);
  }
  return null;
}

export function formatUsage(usage) {
  const parts = [];
  if (usage.input != null) parts.push("in=" + formatCompactNumber(usage.input));
  if (usage.output != null) parts.push("out=" + formatCompactNumber(usage.output));
  if (usage.cacheRead != null && usage.cacheRead > 0) parts.push("cacheR=" + formatCompactNumber(usage.cacheRead));
  if (usage.cacheWrite != null && usage.cacheWrite > 0) parts.push("cacheW=" + formatCompactNumber(usage.cacheWrite));
  const total = tokenCountFromUsage(usage);
  if (total != null) parts.push("total=" + formatCompactNumber(total));
  const cost = costFromUsage(usage);
  if (cost != null) parts.push("cost=" + formatCostUsd(cost));
  return parts.map((part) => '<span class="pill">' + escapeHtml(part) + "</span>").join(" ");
}
`;
