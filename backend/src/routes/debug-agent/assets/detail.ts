export const DEBUG_AGENT_DETAIL_MODULE = String.raw`
import {
  escapeHtml,
  extractReasoning,
  extractText,
  extractToolCalls,
  formatCostUsd,
  formatTokenCount,
  formatUsage,
  getCharacterDisplayName,
  getCharacterGroupNames,
  prettyJson,
} from "./shared.js";
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

  body.appendChild(thinkingSectionCard("thinking-system", "system prompt", collapsibleTextNode(detail.systemPrompt || "(empty)")));
  body.appendChild(thinkingSectionCard("thinking-user", "user prompt", collapsibleTextNode(detail.userPrompt || "(empty)")));

  if (detail.assistantMessage) {
    const message = detail.assistantMessage;
    const meta = [];
    if (message.usage) meta.push(formatUsage(message.usage));
    if (message.stopReason) meta.push('<span class="pill">stop_reason=' + escapeHtml(String(message.stopReason)) + "</span>");

    const assistantBody = document.createElement("div");
    const reasoning = extractReasoning(message);
    if (reasoning) {
      assistantBody.appendChild(thinkingSubsection("reasoning", reasoning));
    }
    const text = extractText(message.content);
    if (text) {
      assistantBody.appendChild(thinkingSubsection("content", text));
    }
    const toolCalls = extractToolCalls(message);
    for (const toolCall of toolCalls) {
      const args = toolCall.args !== undefined ? prettyJson(toolCall.args) : "(no args)";
      assistantBody.appendChild(thinkingSubsection(
        "tool_call " + (toolCall.name || "unknown"),
        args,
      ));
    }
    if (message.errorMessage) {
      assistantBody.appendChild(thinkingSubsection("error", String(message.errorMessage)));
    }
    body.appendChild(thinkingSectionCard("thinking-assistant", "assistant", assistantBody, meta.join(" ")));
  } else {
    body.appendChild(thinkingSectionCard("thinking-assistant", "assistant", collapsibleTextNode("(no assistant message captured)")));
  }

  if (detail.writtenContent) {
    body.appendChild(thinkingSectionCard("thinking-written", "written working_memory", collapsibleTextNode(detail.writtenContent)));
  }
  if (detail.error) {
    const pre = document.createElement("pre");
    pre.className = "error";
    pre.textContent = detail.error;
    body.appendChild(thinkingSectionCard("thinking-error", "error", pre));
  }
}

function thinkingSectionCard(kind, title, bodyNode, metaHtml) {
  const card = document.createElement("section");
  card.className = "section section-card " + kind;
  const head = document.createElement("div");
  head.className = "section-head";
  head.innerHTML = '<span class="section-title">' + escapeHtml(title) + "</span>"
    + (metaHtml ? '<span class="section-meta">' + metaHtml + "</span>" : "");
  card.appendChild(head);
  const inner = document.createElement("div");
  inner.className = "section-body";
  if (typeof bodyNode === "string") inner.innerHTML = bodyNode;
  else if (bodyNode) inner.appendChild(bodyNode);
  card.appendChild(inner);
  return card;
}

function thinkingSubsection(title, text) {
  const details = document.createElement("details");
  details.open = true;
  details.className = "llm-message-card";
  details.innerHTML = "<summary><span class=\"role\">" + escapeHtml(title) + "</span></summary>";
  const pre = document.createElement("pre");
  pre.textContent = text;
  details.appendChild(pre);
  return details;
}

function collapsibleTextNode(text) {
  const wrap = document.createElement("div");
  const pre = document.createElement("pre");
  pre.textContent = text;
  wrap.appendChild(pre);
  if (text && text.length > 1200) {
    wrap.classList.add("truncate-wrap", "collapsed");
    const toggle = document.createElement("div");
    toggle.className = "truncate-toggle";
    toggle.textContent = "展开 (" + text.length + " 字符)";
    toggle.addEventListener("click", () => {
      wrap.classList.toggle("collapsed");
      toggle.textContent = wrap.classList.contains("collapsed")
        ? "展开 (" + text.length + " 字符)"
        : "收起";
    });
    wrap.appendChild(toggle);
  }
  return wrap;
}
`;
