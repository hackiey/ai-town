export const DEBUG_AGENT_MESSAGE_RENDERERS_MODULE = String.raw`
import {
  costFromUsage,
  escapeHtml,
  extractReasoning,
  extractText,
  extractToolCalls,
  formatCostUsd,
  formatTokenCount,
  formatUsage,
  prettyJson,
  tokenCountFromUsage,
} from "./shared.js";
import { formatGameTime } from "./time.js";

export function groupTurns(messages) {
  const turns = [];
  let current = null;
  const preamble = [];
  for (const message of messages) {
    if (message.role === "user") {
      if (current) turns.push(current);
      current = { messages: [message], turnReason: message.turnReason };
    } else if (current) {
      current.messages.push(message);
    } else {
      preamble.push(message);
    }
  }
  if (current) turns.push(current);
  if (preamble.length > 0) {
    turns.unshift({ messages: preamble, turnReason: "(无 user 起始)" });
  }
  return turns;
}

export function isGroupedTurnSelected(groupedTurn, selectedTurn) {
  if (!selectedTurn || !groupedTurn || !Array.isArray(groupedTurn.messages) || groupedTurn.messages.length === 0) {
    return false;
  }
  const first = groupedTurn.messages[0];
  const last = groupedTurn.messages[groupedTurn.messages.length - 1];
  return first.seq === selectedTurn.startSeq && last.seq === selectedTurn.endSeq;
}

export function buildTurn(app, index, turn, selectedTurn) {
  const wrap = document.createElement("div");
  const isSelected = isGroupedTurnSelected(turn, selectedTurn);
  wrap.className = "turn" + (isSelected ? " selected" : " collapsed");

  const first = turn.messages[0];
  const last = turn.messages[turn.messages.length - 1];
  const seqRange = first.seq === last.seq
    ? "#" + first.seq
    : "#" + first.seq + "–" + last.seq;
  const reason = turn.turnReason || first.turnReason || "—";
  const turnTokens = sumTurnTokens(turn.messages);
  const turnCost = sumTurnCost(turn.messages);
  const header = document.createElement("div");
  header.className = "turn-header";
  header.innerHTML = ""
    + '<span class="turn-no">Turn ' + index + "</span>"
    + '<span class="pill">' + escapeHtml(seqRange) + "</span>"
    + (turnTokens != null ? '<span class="pill">' + escapeHtml(formatTokenCount(turnTokens)) + "</span>" : "")
    + (turnCost != null ? '<span class="pill">' + escapeHtml(formatCostUsd(turnCost)) + "</span>" : "")
    + '<span class="turn-toggle"></span>'
    + '<span class="reason">reason: ' + escapeHtml(reason) + "</span>"
    + '<span class="time">' + formatGameTime(first.gameTime)
    + " → " + formatGameTime(last.gameTime) + "</span>";

  const toggle = header.querySelector(".turn-toggle");
  const syncToggleText = () => {
    if (!toggle) return;
    if (wrap.classList.contains("collapsed")) {
      toggle.textContent = "点击展开";
    } else if (isSelected) {
      toggle.textContent = "当前 turn";
    } else {
      toggle.textContent = "点击收起";
    }
  };
  syncToggleText();
  header.addEventListener("click", () => {
    wrap.classList.toggle("collapsed");
    syncToggleText();
  });
  wrap.appendChild(header);

  const body = document.createElement("div");
  body.className = "turn-body";
  for (const message of turn.messages) {
    body.appendChild(buildMessage(app, message));
  }
  wrap.appendChild(body);
  return wrap;
}

function sumTurnTokens(messages) {
  let total = 0;
  let hasTokens = false;
  for (const record of messages || []) {
    if (record.role !== "assistant") continue;
    const usage = record.message && record.message.usage;
    const tokens = tokenCountFromUsage(usage);
    if (tokens == null) continue;
    total += tokens;
    hasTokens = true;
  }
  return hasTokens ? total : null;
}

function sumTurnCost(messages) {
  let total = 0;
  let hasCost = false;
  for (const record of messages || []) {
    if (record.role !== "assistant") continue;
    const usage = record.message && record.message.usage;
    const cost = costFromUsage(usage);
    if (cost == null) continue;
    total += cost;
    hasCost = true;
  }
  return hasCost ? total : null;
}

export function buildSectionCard(kind, title, bodyNode, metaHtml) {
  const card = document.createElement("section");
  card.className = "section section-card " + kind;

  const head = document.createElement("div");
  head.className = "section-head";
  head.innerHTML = '<span class="section-title">' + escapeHtml(title) + "</span>"
    + (metaHtml ? '<span class="section-meta">' + metaHtml + "</span>" : "");
  card.appendChild(head);

  const body = document.createElement("div");
  body.className = "section-body";
  if (typeof bodyNode === "string") {
    body.innerHTML = bodyNode;
  } else if (bodyNode) {
    body.appendChild(bodyNode);
  }
  card.appendChild(body);
  return card;
}

export function buildDetailsBlock(title, innerHtml, open) {
  const details = document.createElement("details");
  if (open) details.open = true;
  details.innerHTML = "<summary>" + escapeHtml(title) + '</summary><div class="body">' + innerHtml + "</div>";
  return details;
}

function buildMessage(app, record) {
  const div = document.createElement("div");
  div.className = "msg " + record.role;
  div.dataset.messageSeq = String(record.seq);
  const message = record.message || {};
  const roleLabel = record.role === "toolResult" ? "tool response" : record.role;
  const roleMeta = record.role === "assistant" ? buildAssistantHeaderMeta(message) : "";

  const bar = document.createElement("div");
  bar.className = "role-bar";
  bar.innerHTML = ""
    + '<span class="role">' + escapeHtml(roleLabel) + "</span>"
    + '<span class="seq">#' + record.seq + "</span>"
    + '<span class="ts">' + formatGameTime(record.gameTime, { short: true }) + "</span>"
    + (roleMeta ? '<span class="role-meta">' + roleMeta + "</span>" : "");
  div.appendChild(bar);

  if (record.role === "toolResult") {
    const toolCallId = message.toolCallId || message.tool_call_id;
    if (toolCallId) div.dataset.toolCallId = String(toolCallId);
  }

  if (record.role === "user") {
    div.appendChild(renderUserBody(message));
  } else if (record.role === "assistant") {
    renderAssistantBody(div, message, record.toolsSnapshot, record.llmMessages, record.llmSystemPrompt);
  } else if (record.role === "toolResult") {
    div.appendChild(renderToolResultBody(message));
  } else {
    const pre = document.createElement("pre");
    pre.textContent = JSON.stringify(message, null, 2);
    div.appendChild(pre);
  }

  return div;
}

function renderUserBody(message) {
  const text = extractText(message.content);
  return collapsibleText(text || "(empty)");
}

function renderAssistantBody(container, message, toolsSnapshot, llmMessages, llmSystemPrompt) {
  const hasLlmMessages = Array.isArray(llmMessages) && llmMessages.length > 0;
  if (hasLlmMessages || llmSystemPrompt) {
    container.appendChild(buildAssistantSection(
      "llm-messages",
      "messages at LLM call",
      buildLlmCallDetails(llmMessages, llmSystemPrompt),
      '<span class="pill">' + (hasLlmMessages ? llmMessages.length : 0) + " messages</span>",
      { collapsible: true },
    ));
  }

  const hasToolsSnapshot = Array.isArray(toolsSnapshot) && toolsSnapshot.length > 0;
  if (hasToolsSnapshot) {
    container.appendChild(buildAssistantSection(
      "tools-snapshot",
      "tools at LLM call",
      buildToolsSnapshotDetails(toolsSnapshot),
      '<span class="pill">' + toolsSnapshot.length + " tools</span>",
      { collapsible: true },
    ));
  }

  const reasoning = extractReasoning(message);
  if (reasoning) {
    container.appendChild(buildAssistantSection(
      "reasoning",
      "reasoning",
      collapsibleText(reasoning, { truncate: false }),
      '<span class="pill">' + reasoning.length + " chars</span>",
      { collapsible: true },
    ));
  }

  const text = extractText(message.content);
  if (text) {
    container.appendChild(buildAssistantSection(
      "assistant-content",
      "content",
      collapsibleText(text),
    ));
  }

  const toolCalls = extractToolCalls(message);
  if (toolCalls.length > 0) {
    const sec = document.createElement("div");
    for (const toolCall of toolCalls) {
      sec.appendChild(renderToolCall(toolCall));
    }
    container.appendChild(buildAssistantSection(
      "tool-calls",
      "tool_calls",
      sec,
      '<span class="pill">' + toolCalls.length + " calls</span>",
      { collapsible: true, defaultOpen: true },
    ));
  }

  if (message.errorMessage) {
    const pre = document.createElement("pre");
    pre.className = "error";
    pre.textContent = String(message.errorMessage);
    container.appendChild(buildAssistantSection("error-block", "error", pre));
  }

  if (!hasLlmMessages && !llmSystemPrompt && !hasToolsSnapshot && !reasoning && !text && toolCalls.length === 0 && !message.errorMessage && !message.usage && !message.stopReason) {
    const pre = document.createElement("pre");
    pre.textContent = "(empty)";
    container.appendChild(buildAssistantSection("meta-block", "assistant", pre));
  }
}

function buildLlmCallDetails(messages, systemPrompt) {
  const body = document.createElement("div");
  if (systemPrompt) {
    const details = document.createElement("details");
    details.className = "llm-message-card";
    details.innerHTML = '<summary><span class="role">system</span></summary>';
    const pre = document.createElement("pre");
    pre.textContent = systemPrompt;
    details.appendChild(pre);
    body.appendChild(details);
  }

  const list = Array.isArray(messages) ? messages : [];
  for (let index = 0; index < list.length; index += 1) {
    const message = list[index] || {};
    const role = message.role || "unknown";
    const preview = extractText(message.content) || message.errorMessage || "";
    const details = document.createElement("details");
    details.className = "llm-message-card";
    details.innerHTML = ""
      + "<summary>"
      + '<span class="role">' + escapeHtml(role) + "</span>"
      + '<span class="seq">#' + (index + 1) + "</span>"
      + (preview ? '<span class="preview">' + escapeHtml(preview.slice(0, 160)) + "</span>" : "")
      + "</summary>";
    const pre = document.createElement("pre");
    pre.textContent = prettyJson(message);
    details.appendChild(pre);
    body.appendChild(details);
  }

  if (!systemPrompt && list.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "没有保存这次 LLM call 的 messages（旧数据不会回填）";
    body.appendChild(empty);
  }
  return body;
}

function buildAssistantHeaderMeta(message) {
  const parts = [];
  if (message.usage) parts.push(formatUsage(message.usage));
  if (message.stopReason) {
    parts.push('<span class="pill">stop_reason=' + escapeHtml(String(message.stopReason)) + "</span>");
  }
  return parts.join(" ");
}

function renderToolCall(toolCall) {
  const card = document.createElement("div");
  card.className = "toolcall";
  if (toolCall.id) card.dataset.toolCallId = String(toolCall.id);
  const args = toolCall.args !== undefined ? prettyJson(toolCall.args) : "(no args)";
  card.innerHTML = ""
    + '<div class="head"><span class="name">' + escapeHtml(toolCall.name || "unknown") + "</span>"
    + '<span class="id">' + escapeHtml(toolCall.id || "") + "</span></div>"
    + "<pre>" + escapeHtml(args) + "</pre>";
  return card;
}

function renderToolResultBody(message) {
  const wrap = document.createElement("div");
  const toolName = message.toolName || message.name || "?";
  const toolCallId = message.toolCallId || message.tool_call_id || "?";
  const meta = [
    '<span class="pill">tool=' + escapeHtml(toolName) + "</span>",
    '<span class="pill">id=' + escapeHtml(toolCallId) + "</span>",
  ];
  if (message.isError) meta.push('<span class="badge-error">error</span>');

  let body;
  const content = extractText(message.content);
  if (content) {
    body = collapsibleText(content);
  } else if (message.content !== undefined) {
    body = collapsibleText(prettyJson(message.content));
  } else {
    body = collapsibleText("(empty)");
  }
  wrap.appendChild(buildSectionCard("tool-response", "tool response", body, meta.join(" ")));
  return wrap;
}

function collapsibleText(text, options) {
  const wrap = document.createElement("div");
  const pre = document.createElement("pre");
  pre.textContent = text;
  wrap.appendChild(pre);
  const shouldTruncate = !options || options.truncate !== false;
  if (shouldTruncate && text.length > 800) {
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

function buildAssistantSection(kind, title, bodyNode, metaHtml, options) {
  const isCollapsible = !!(options && options.collapsible);
  const section = document.createElement(isCollapsible ? "details" : "section");
  section.className = "section assistant-section " + kind;
  if (isCollapsible && options && options.defaultOpen) {
    section.open = true;
  }

  const head = document.createElement(isCollapsible ? "summary" : "div");
  head.className = "assistant-section-head";
  head.innerHTML = '<span class="assistant-section-title">' + escapeHtml(title) + "</span>"
    + (metaHtml ? '<span class="assistant-section-meta">' + metaHtml + "</span>" : "");
  section.appendChild(head);

  const body = document.createElement("div");
  body.className = "assistant-section-body";
  if (typeof bodyNode === "string") {
    body.innerHTML = bodyNode;
  } else if (bodyNode) {
    body.appendChild(bodyNode);
  }
  section.appendChild(body);
  return section;
}

function buildToolsSnapshotDetails(tools) {
  const body = document.createElement("div");
  for (const tool of tools) {
    const card = document.createElement("details");
    card.className = "tool-snapshot";
    card.innerHTML = ""
      + "<summary>"
      + '<span class="name">' + escapeHtml(tool.name || "?") + "</span>"
      + (tool.label ? ' <span class="id">' + escapeHtml(tool.label) + "</span>" : "")
      + "</summary>";
    const inner = document.createElement("div");
    inner.className = "body";
    if (tool.description) {
      const description = document.createElement("div");
      description.className = "tool-desc";
      description.textContent = tool.description;
      inner.appendChild(description);
    }
    if (tool.parameters !== undefined) {
      const heading = document.createElement("h4");
      heading.textContent = "parameters";
      inner.appendChild(heading);
      const pre = document.createElement("pre");
      pre.textContent = prettyJson(tool.parameters);
      inner.appendChild(pre);
    }
    card.appendChild(inner);
    body.appendChild(card);
  }
  return body;
}
`;
