export const DEBUG_AGENT_DETAIL_MODULE = String.raw`
import {
  escapeHtml,
  formatCostUsd,
  formatTokenCount,
  getCharacterDisplayName,
  getCharacterGroupNames,
} from "./shared.js";
import { buildMessage, buildSectionCard, collapsibleText } from "./message-renderers.js";
import { buildSessionDetailView } from "./session-view.js";
import { formatDuration, formatGameTime } from "./time.js";

export function renderDetailHeader(app, turn, handlers) {
  const tokenInfo = turn.totalTokens != null ? formatTokenCount(turn.totalTokens) : "—";
  const costInfo = turn.totalCostUsd != null ? formatCostUsd(turn.totalCostUsd) : "—";
  const npcTokenInfo = turn.npcCumulativeTokens != null ? formatTokenCount(turn.npcCumulativeTokens) : "—";
  const npcAtTurnInfo = turn.npcCumulativeTokensAtTurn != null ? formatTokenCount(turn.npcCumulativeTokensAtTurn) : "—";
  const npcCostInfo = turn.npcCumulativeCostUsd != null ? formatCostUsd(turn.npcCumulativeCostUsd) : "—";
  const npcCostAtTurnInfo = turn.npcCumulativeCostUsdAtTurn != null ? formatCostUsd(turn.npcCumulativeCostUsdAtTurn) : "—";
  const displayName = getCharacterDisplayName(app, turn.characterId, turn.townId);
  const groupText = getCharacterGroupNames(app, turn.characterId, turn.townId).join("、");
  app.$("detail-header").innerHTML = ""
    + '<span class="title">' + escapeHtml(displayName) + "</span>"
    + (groupText ? '<span class="meta">' + escapeHtml(groupText) + "</span>" : "")
    + '<span class="meta">' + escapeHtml(turn.characterId) + " · " + escapeHtml(turn.agentKind)
    + " · " + escapeHtml(turn.townId) + "</span>"
    + '<span class="meta">reason=' + escapeHtml(turn.turnReason || "—") + "</span>"
    + '<span class="meta">' + escapeHtml(formatGameTime(turn.startGameTime))
    + " → " + escapeHtml(formatGameTime(turn.endGameTime)) + "</span>"
    + '<span class="meta">' + turn.msgCount + " msg · " + turn.llmCallCount + " LLM · "
    + turn.toolCallCount + " tool · " + tokenInfo + " · " + costInfo + "</span>"
    + '<span class="meta">NPC tokens: 累计 ' + escapeHtml(npcTokenInfo)
    + " · 截至此 turn " + escapeHtml(npcAtTurnInfo)
    + (turn.npcTurnIndex > 0 && turn.npcTurnCount > 0 ? " · turn " + turn.npcTurnIndex + "/" + turn.npcTurnCount : "")
    + "</span>"
    + '<span class="meta">NPC cost: 累计 ' + escapeHtml(npcCostInfo)
    + " · 截至此 turn " + escapeHtml(npcCostAtTurnInfo)
    + "</span>"
    + '<span class="meta" style="margin-left:auto">session=' + escapeHtml(turn.sessionId) + "</span>"
    + '<button id="delete-session" class="danger" title="删除该 session 的所有消息">🗑 删除整 session</button>';

  const button = app.$("delete-session");
  if (button) {
    button.addEventListener("click", () => { void handlers.onDelete(); });
  }
}

export function renderDetailLoading(app, text) {
  app.$("detail-body").innerHTML = '<div class="empty">' + escapeHtml(text) + "</div>";
}

export function renderDetailError(app, text) {
  app.$("detail-body").innerHTML = '<div class="empty error">' + escapeHtml(text) + "</div>";
}

export function renderDetailPlaceholder(app, text) {
  app.$("detail-header").innerHTML = '<span class="title">未选择 turn</span>';
  app.$("detail-body").innerHTML = '<div class="empty">' + escapeHtml(text) + "</div>";
}

export function renderDetailBody(app, turn, session, messagesRes, promptMemory, handlers, extras) {
  const body = app.$("detail-body");
  body.innerHTML = "";
  body.appendChild(buildSessionDetailView(app, turn, session, messagesRes, promptMemory, handlers, extras));
}

export function renderThinkingDetail(app, summary, detail) {
  renderThinkingDetailHeader(app, summary, detail);
  renderThinkingDetailBody(app, detail);
}

function renderThinkingDetailHeader(app, summary, detail) {
  const character = detail.characterId || summary.characterId;
  const town = detail.townId || summary.townId;
  const displayName = getCharacterDisplayName(app, character, town);
  const groupText = getCharacterGroupNames(app, character, town).join("、");
  const tokens = detail.totalTokens != null ? formatTokenCount(detail.totalTokens) : "—";
  const cost = detail.costUsd != null ? formatCostUsd(detail.costUsd) : "—";
  const writeStatus = detail.error
    ? '<span style="color:var(--error)">error</span>'
    : (detail.writtenContent ? "wrote working_memory" : "no write");
  app.$("detail-header").innerHTML = ""
    + '<span class="title">[思考] ' + escapeHtml(displayName) + "</span>"
    + (groupText ? '<span class="meta">' + escapeHtml(groupText) + "</span>" : "")
    + '<span class="meta">' + escapeHtml(character) + " · " + escapeHtml(town)
    + " · " + escapeHtml(detail.modelId || "—") + "</span>"
    + '<span class="meta">trigger=' + escapeHtml(detail.triggerReason || "—") + "</span>"
    + (detail.intent ? '<span class="meta">intent=' + escapeHtml(detail.intent) + "</span>" : "")
    + '<span class="meta">' + escapeHtml(formatGameTime(detail.startGameTime))
    + (detail.endGameTime ? " → " + escapeHtml(formatGameTime(detail.endGameTime)) : "") + "</span>"
    + '<span class="meta">duration ' + escapeHtml(formatDuration(detail.durationMs)) + "</span>"
    + '<span class="meta">' + escapeHtml(tokens) + " · " + escapeHtml(cost) + " · " + writeStatus + "</span>"
    + '<span class="meta" style="margin-left:auto">id=' + escapeHtml(detail.id) + "</span>";
}

function renderThinkingDetailBody(app, detail) {
  const body = app.$("detail-body");
  body.innerHTML = "";

  // 与 action 轨用同一套 message 渲染：把 thinking turn 表示成「一条 user prompt + 一条 assistant 回复」，
  // 复用 buildMessage（含 reasoning / content / tool_calls / system 折叠区的统一样式）。
  // systemPrompt 走 assistant 的 llmSystemPrompt，折叠在 "messages at LLM call" 里，和 action 一致。
  body.appendChild(buildMessage(app, {
    role: "user",
    seq: 1,
    gameTime: detail.startGameTime || null,
    turnReason: detail.triggerReason || null,
    message: { content: detail.userPrompt || "" },
  }));

  body.appendChild(buildMessage(app, {
    role: "assistant",
    seq: 2,
    gameTime: detail.endGameTime || detail.startGameTime || null,
    turnReason: detail.triggerReason || null,
    message: detail.assistantMessage || {},
    llmSystemPrompt: detail.systemPrompt || "",
  }));

  // thinking 专属产出：写出的 working_memory（即 write_working_memory 的入参），单独高亮一张卡。
  if (detail.writtenContent) {
    body.appendChild(buildSectionCard("thinking-written", "written working_memory", collapsibleText(detail.writtenContent)));
  }
  if (detail.error) {
    const pre = document.createElement("pre");
    pre.className = "error";
    pre.textContent = detail.error;
    body.appendChild(buildSectionCard("thinking-error", "error", pre));
  }
}
`;
