export const DEBUG_AGENT_SESSION_VIEW_MODULE = String.raw`
  import { buildSectionCard, buildTurn, groupTurns } from "./message-renderers.js";
import {
  costFromUsage,
  escapeHtml,
  extractToolCalls,
  formatCostUsd,
  formatTokenCount,
  formatRealTime,
  prettyJson,
  tokenCountFromUsage,
  toolResultIsFailure,
  truncate,
} from "./shared.js";
import {
  computeGameTimeTicks,
  formatDuration,
  formatGameDuration,
  formatGameTime,
  gameTimeTotalMinutes,
} from "./time.js";

export function buildSessionDetailView(app, turn, session, messagesRes, promptMemory, handlers, extras) {
  const wrap = document.createElement("div");
  const messages = Array.isArray(messagesRes && messagesRes.messages) ? messagesRes.messages : [];
  const selectedTurnMessages = filterMessagesForSelectedTurn(messages, turn);
  const promptMemoryPayload = promptMemory && !promptMemory.error ? promptMemory.promptMemory : null;
  const promptMemoryError = promptMemory && promptMemory.error ? promptMemory.error : null;
  const memoryView = extras && extras.memory ? extras.memory : null;
  const turnUserMessage = selectedTurnMessages.find((message) => message && message.role === "user");
  const inventorySnapshot = turnUserMessage && turnUserMessage.inventorySnapshot
    ? turnUserMessage.inventorySnapshot
    : null;

  const selectedTurnTab = {
    key: "selected-turn",
    label: "Selected Turn",
    build: () => {
      const turnsWrap = document.createElement("div");
      turnsWrap.appendChild(buildSelectedTurnScopeCard(turn, session, selectedTurnMessages));
      if (selectedTurnMessages.length > 0) {
        turnsWrap.appendChild(buildInnerTimeline(app, selectedTurnMessages, turn, handlers));
        const groupedSelectedTurns = groupTurns(selectedTurnMessages);
        let selectedIndex = 0;
        for (const groupedTurn of groupedSelectedTurns) {
          selectedIndex += 1;
          turnsWrap.appendChild(buildTurn(app, selectedIndex, groupedTurn, turn));
        }
      } else {
        const empty = document.createElement("div");
        empty.className = "empty";
        empty.textContent = "这个 turn 的消息不在当前 session 消息范围内（可能已被压缩或尚未写入）";
        turnsWrap.appendChild(empty);
      }
      return turnsWrap;
    },
  };

  const llmCallsTab = {
    key: "llm-calls",
    label: "LLM Calls",
    build: () => buildLlmCallsView(messages, turn),
  };

  const systemPromptTab = promptMemoryPayload ? {
    key: "system-prompt",
    label: "System Prompt",
    build: () => {
      const div = document.createElement("div");
      div.innerHTML = "<pre>" + escapeHtml(promptMemoryPayload.effectiveSystemPrompt || "(empty)") + "</pre>";
      return div;
    },
  } : null;

  const stableContextTab = promptMemoryPayload ? {
    key: "stable-context",
    label: "Stable Context",
    build: () => {
      const div = document.createElement("div");
      div.innerHTML = "<pre>" + escapeHtml(promptMemoryPayload.renderedStableContext || "(empty)") + "</pre>";
      return div;
    },
  } : null;

  const memoryTab = promptMemoryPayload ? {
    key: "memory",
    label: "Memory",
    build: () => {
      const div = document.createElement("div");
      const selectedCount = Array.isArray(promptMemoryPayload.promptSelectedMemories)
        ? promptMemoryPayload.promptSelectedMemories.length
        : 0;
      const storedCount = Array.isArray(promptMemoryPayload.storedMemories)
        ? promptMemoryPayload.storedMemories.length
        : 0;
      div.innerHTML = ""
        + '<div class="prompt-memory-meta">送进 prompt 的 memory：' + selectedCount
        + " 条；库里总 memory：" + storedCount + " 条</div>"
        + renderMemoryListHtml(promptMemoryPayload.promptSelectedMemories, "当前 prompt 选中的 memory")
        + renderMemoryListHtml(promptMemoryPayload.storedMemories, "数据库里的全部 memory");
      return div;
    },
  } : null;

  const basePromptTab = promptMemoryPayload ? {
    key: "base-prompt",
    label: "Base Prompt",
    build: () => {
      const div = document.createElement("div");
      div.innerHTML = "<pre>" + escapeHtml(promptMemoryPayload.baseSystemPrompt || "(empty)") + "</pre>";
      return div;
    },
  } : null;

  const promptErrorTab = promptMemoryError ? {
    key: "pm-error",
    label: "Prompt Error",
    build: () => {
      const div = document.createElement("div");
      div.innerHTML = '<div class="error">' + escapeHtml(promptMemoryError) + "</div>";
      return div;
    },
  } : null;

  const inventoryTab = {
    key: "inventory",
    label: "背包",
    build: () => buildInventoryView(turn, inventorySnapshot),
  };

  const workingMemoryTab = {
    key: "working-memory",
    label: "Memory",
    build: () => buildMemoryView(memoryView),
  };

  const tabs = [
    selectedTurnTab,
    inventoryTab,
    workingMemoryTab,
    llmCallsTab,
    systemPromptTab,
    stableContextTab,
    memoryTab,
    basePromptTab,
    promptErrorTab,
  ].filter(Boolean);

  wrap.appendChild(buildLazyTopTabs(tabs, "selected-turn"));
  return wrap;
}

function filterMessagesForSelectedTurn(messages, selectedTurn) {
  return messages.filter((message) => (
    message.seq >= selectedTurn.startSeq && message.seq <= selectedTurn.endSeq
  ));
}

function buildSelectedTurnScopeCard(selectedTurn, session, selectedMessages) {
  const cardBody = document.createElement("div");
  const focusText = "#" + selectedTurn.startSeq + "–#" + selectedTurn.endSeq;
  cardBody.innerHTML = ""
    + "<div>当前默认只展示选中的 turn。历史裁剪或后续上下文变化不会改变这个 turn 的消息边界。</div>"
    + '<div style="margin-top:6px;color:var(--muted)">turn 范围：' + escapeHtml(focusText)
    + " · reason=" + escapeHtml(selectedTurn.turnReason || "—") + "</div>"
    + '<div style="margin-top:6px;color:var(--muted)">已加载该 turn 内 message：'
    + selectedMessages.length + " 条</div>"
    + '<div style="margin-top:6px;color:var(--muted)">完整共享 session 可在 “Session Turns” tab 查看。</div>';

  return buildSectionCard(
    "meta-block",
    "Selected Turn Context",
    cardBody,
    ""
      + '<span class="pill">session=' + escapeHtml(session.id) + "</span>"
      + '<span class="pill">turn=' + escapeHtml(focusText) + "</span>"
      + (Number.isFinite(session.lastUsageCostUsd) ? '<span class="pill">last cost=' + escapeHtml(formatCostUsd(session.lastUsageCostUsd)) + "</span>" : ""),
  );
}

function buildLlmCallsView(messages, selectedTurn) {
  const wrap = document.createElement("div");
  const calls = messages.filter((message) => message.role === "assistant");
  wrap.appendChild(buildLlmCallsScopeCard(calls, selectedTurn));

  if (calls.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "这个 session 还没有 assistant/LLM call 消息";
    wrap.appendChild(empty);
    return wrap;
  }

  let index = 0;
  for (const call of calls) {
    index += 1;
    wrap.appendChild(buildLlmCallCard(index, call, selectedTurn));
  }
  return wrap;
}

function buildLlmCallsScopeCard(calls, selectedTurn) {
  const capturedCount = calls.filter((call) => Array.isArray(call.llmMessages) || call.llmSystemPrompt).length;
  const selectedCalls = calls.filter((call) => (
    call.seq >= selectedTurn.startSeq && call.seq <= selectedTurn.endSeq
  )).length;
  const cardBody = document.createElement("div");
  cardBody.innerHTML = ""
    + "<div>这里展示每次实际请求 LLM 时的 system prompt 和 messages 快照，而不是 session transcript。</div>"
    + '<div style="margin-top:6px;color:var(--muted)">当前 session 共 '
    + calls.length + " 次 assistant/LLM call；已保存 request messages 的 " + capturedCount + " 次。</div>"
    + '<div style="margin-top:6px;color:var(--muted)">当前选中 turn 内 LLM call：'
    + selectedCalls + " 次。旧数据不会回填 request messages。</div>";

  return buildSectionCard(
    "meta-block",
    "LLM Request Messages",
    cardBody,
    '<span class="pill">' + capturedCount + "/" + calls.length + " captured</span>",
  );
}

function buildLlmCallCard(index, record, selectedTurn) {
  const messages = Array.isArray(record.llmMessages) ? record.llmMessages : [];
  const isSelected = record.seq >= selectedTurn.startSeq && record.seq <= selectedTurn.endSeq;
  const details = document.createElement("details");
  details.className = "llm-call-card" + (isSelected ? " selected" : "");
  details.open = isSelected || index === 1;
  details.innerHTML = ""
    + "<summary>"
    + '<span class="name">LLM Call ' + index + "</span>"
    + '<span class="pill">response #' + record.seq + "</span>"
    + '<span class="pill">' + messages.length + " messages</span>"
    + '<span class="meta">' + escapeHtml(formatGameTime(record.gameTime, { short: true })) + "</span>"
    + (record.turnReason ? '<span class="meta">reason=' + escapeHtml(record.turnReason) + "</span>" : "")
    + (isSelected ? '<span class="pill">selected turn</span>' : "")
    + "</summary>";

  const body = document.createElement("div");
  body.className = "body";
  if (record.llmSystemPrompt) {
    body.appendChild(buildLlmRequestMessageDetails("system", 0, record.llmSystemPrompt, record.llmSystemPrompt, true));
  }

  if (messages.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "没有保存这次 LLM call 的 request messages（通常是旧数据）";
    body.appendChild(empty);
  } else {
    let openedFirstUser = false;
    for (let messageIndex = 0; messageIndex < messages.length; messageIndex += 1) {
      const message = messages[messageIndex] || {};
      const role = message.role || "unknown";
      const defaultOpen = role === "system" || (role === "user" && !openedFirstUser);
      if (role === "user" && !openedFirstUser) openedFirstUser = true;
      body.appendChild(buildLlmRequestMessageDetails(
        role,
        messageIndex + 1,
        llmMessagePreview(message),
        prettyJson(message),
        defaultOpen,
      ));
    }
  }

  details.appendChild(body);
  return details;
}

function buildLlmRequestMessageDetails(role, index, preview, fullText, defaultOpen) {
  const details = document.createElement("details");
  details.className = "llm-request-message";
  if (defaultOpen) details.open = true;
  details.innerHTML = ""
    + "<summary>"
    + '<span class="role">' + escapeHtml(role) + "</span>"
    + (index > 0 ? '<span class="seq">#' + index + "</span>" : "")
    + (preview ? '<span class="preview">' + escapeHtml(truncate(String(preview).replace(/\s+/g, " "), 180)) + "</span>" : "")
    + "</summary>";
  const pre = document.createElement("pre");
  pre.textContent = fullText || "";
  details.appendChild(pre);
  return details;
}

function llmMessagePreview(message) {
  if (!message || typeof message !== "object") return "";
  if (message.errorMessage) return String(message.errorMessage);
  if (message.toolName) return "toolResult: " + message.toolName;
  return contentPreview(message.content);
}

function contentPreview(content) {
  if (content == null) return "";
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return prettyJson(content);
  return content.map((part) => {
    if (typeof part === "string") return part;
    if (!part || typeof part !== "object") return "";
    if (part.type === "text") return part.text || "";
    if (part.type === "toolCall") return "toolCall: " + (part.name || "?");
    if (part.type === "thinking") return "thinking";
    return part.type || "";
  }).filter(Boolean).join(" | ");
}

function findJumpTarget(root, target) {
  if (!root || !target) return null;

  if (target.kind === "message") {
    const seq = String(target.seq);
    for (const el of root.querySelectorAll(".msg")) {
      if (el.dataset.messageSeq === seq) return el;
    }
    return null;
  }

  if (target.kind === "tool") {
    const callId = target.toolCallId ? String(target.toolCallId) : "";
    if (callId) {
      for (const el of root.querySelectorAll(".toolcall")) {
        if (el.dataset.toolCallId === callId) return el;
      }
      for (const el of root.querySelectorAll(".msg.toolResult")) {
        if (el.dataset.toolCallId === callId) return el;
      }
    }
    if (target.assistantSeq != null) {
      return findJumpTarget(root, { kind: "message", seq: target.assistantSeq });
    }
    if (target.resultSeq != null) {
      return findJumpTarget(root, { kind: "message", seq: target.resultSeq });
    }
  }

  return null;
}

function flashJumpTarget(root, el) {
  if (!root || !el) return;
  for (const node of root.querySelectorAll(".jump-target")) {
    node.classList.remove("jump-target");
  }
  el.classList.add("jump-target");
  window.setTimeout(() => {
    if (el.isConnected) el.classList.remove("jump-target");
  }, 1800);
}

function jumpToSegmentTarget(root, target) {
  const el = findJumpTarget(root, target);
  if (!el) return false;
  flashJumpTarget(root, el);
  el.scrollIntoView({ behavior: "smooth", block: "center", inline: "nearest" });
  return true;
}

function buildInnerTimeline(app, messages, turn, handlers) {
  const wrap = document.createElement("div");
  wrap.className = "inner-timeline";

  const startMs = Date.parse(turn.startedAt);
  const endMs = Date.parse(turn.endedAt);
  const totalMs = Number.isFinite(startMs) && Number.isFinite(endMs) ? Math.max(0, endMs - startMs) : 0;
  const segments = computeInnerSegments(messages);
  const visualSegments = segments.filter((seg) => seg.startGameMinute != null && seg.endGameMinute != null);

  const summary = document.createElement("div");
  summary.className = "legend";
  summary.innerHTML = ""
    + '<span><span class="swatch" style="background:#4ea0ff"></span>LLM 调用</span>'
    + '<span><span class="swatch" style="background:#d6a76a"></span>Tool 执行</span>'
    + '<span style="margin-left:auto">游戏时长 ' + escapeHtml(formatGameDuration(turn.startGameTime, turn.endGameTime))
    + "（实际 " + escapeHtml(formatDuration(totalMs)) + "）</span>";
  wrap.appendChild(summary);

  if (segments.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.style.padding = "6px";
    empty.textContent = "没有可视化的 LLM/tool 段（turn 内只有 user 消息）";
    wrap.appendChild(empty);
    return wrap;
  }
  if (visualSegments.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.style.padding = "6px";
    empty.textContent = "没有可用 gameTime 的 LLM/tool 段";
    wrap.appendChild(empty);
    return wrap;
  }

  let minGame = gameTimeTotalMinutes(turn.startGameTime);
  let maxGame = gameTimeTotalMinutes(turn.endGameTime);
  for (const seg of visualSegments) {
    const segMin = Math.min(seg.startGameMinute, seg.endGameMinute);
    const segMax = Math.max(seg.startGameMinute, seg.endGameMinute);
    if (minGame == null || segMin < minGame) minGame = segMin;
    if (maxGame == null || segMax > maxGame) maxGame = segMax;
  }
  if (minGame == null || maxGame == null) {
    minGame = visualSegments[0].startGameMinute;
    maxGame = visualSegments[0].endGameMinute;
  }
  if (minGame === maxGame) {
    minGame -= 1;
    maxGame += 1;
  }
  const gameSpan = Math.max(1, maxGame - minGame);

  const width = Math.max(600, wrap.clientWidth || 800);
  const innerLabelW = 60;
  const padX = 4;
  const innerW = width - innerLabelW - padX * 2;
  const rowH = 22;
  const rows = ["LLM", "Tools"];
  const height = rows.length * rowH + 22;
  const xOf = (gameMinute) => innerLabelW + padX + ((gameMinute - minGame) / gameSpan) * innerW;

  const parts = [];
  parts.push('<svg class="inner-svg" width="' + width + '" height="' + height + '" xmlns="http://www.w3.org/2000/svg">');
  for (let index = 0; index < rows.length; index += 1) {
    const y = index * rowH;
    parts.push('<text class="row-label" x="6" y="' + (y + rowH / 2) + '">' + rows[index] + "</text>");
  }

  const ticks = computeGameTimeTicks(minGame, maxGame, 6);
  for (const tick of ticks) {
    const x = xOf(tick.gameMinutes);
    parts.push('<line class="axis-tick" x1="' + x + '" y1="0" x2="' + x + '" y2="' + (rows.length * rowH) + '" stroke-dasharray="2 3" />');
    parts.push('<text class="axis-text" x="' + (x + 2) + '" y="' + (rows.length * rowH + 14) + '">' + escapeHtml(tick.label) + "</text>");
  }

  for (let segIdx = 0; segIdx < visualSegments.length; segIdx += 1) {
    const seg = visualSegments[segIdx];
    const rowI = seg.kind === "llm" ? 0 : 1;
    const y = rowI * rowH + 3;
    const x1 = xOf(Math.min(seg.startGameMinute, seg.endGameMinute));
    const x2 = xOf(Math.max(seg.startGameMinute, seg.endGameMinute));
    const widthPx = Math.max(2, x2 - x1);
    const fill = seg.kind === "llm" ? "#4ea0ff" : "#d6a76a";
    const stroke = seg.isError ? "var(--error)" : fill;
    parts.push(
      '<rect class="seg" data-seg="' + segIdx + '"'
      + ' x="' + x1 + '" y="' + y + '"'
      + ' width="' + widthPx + '" height="' + (rowH - 6) + '"'
      + ' fill="' + fill + '" stroke="' + stroke + '"></rect>',
    );
  }
  parts.push("</svg>");

  const svgWrap = document.createElement("div");
  svgWrap.style.overflowX = "auto";
  svgWrap.innerHTML = parts.join("");
  wrap.appendChild(svgWrap);

  let selectedRect = null;
  for (const rect of svgWrap.querySelectorAll(".seg")) {
    const seg = visualSegments[Number(rect.dataset.seg)];
    if (!seg) continue;
    rect.addEventListener("click", () => {
      const targetRoot = wrap.parentElement || wrap;
      if (selectedRect) selectedRect.classList.remove("selected");
      selectedRect = rect;
      selectedRect.classList.add("selected");
      jumpToSegmentTarget(targetRoot, seg.target);
    });
    rect.addEventListener("mousemove", (event) => showSegTooltip(app, event, seg, handlers));
    rect.addEventListener("mouseleave", () => handlers.hideTooltip());
  }

  return wrap;
}

function showSegTooltip(app, event, seg, handlers) {
  const argsHtml = seg.args
    ? '<div class="tt-meta" style="white-space:pre-wrap;color:var(--text);max-height:160px;overflow:auto;margin-top:4px;border-top:1px solid var(--border);padding-top:4px">'
      + escapeHtml(truncate(prettyJson(seg.args), 600)) + "</div>"
    : "";
  const html = ""
    + '<div class="tt-name">' + escapeHtml(seg.label) + "</div>"
    + '<div class="tt-meta">' + escapeHtml(formatGameTime(seg.startGameTime))
    + " → " + escapeHtml(formatGameTime(seg.endGameTime)) + "</div>"
    + '<div class="tt-meta">游戏时长 ' + escapeHtml(formatGameDuration(seg.startGameTime, seg.endGameTime))
    + "（实际 " + escapeHtml(formatDuration(seg.endMs - seg.startMs)) + "）</div>"
    + (seg.tokens != null ? '<div class="tt-meta">' + escapeHtml(formatTokenCount(seg.tokens)) + "</div>" : "")
    + (seg.costUsd != null ? '<div class="tt-meta">cost: ' + escapeHtml(formatCostUsd(seg.costUsd)) + "</div>" : "")
    + (seg.isError ? '<div class="tt-meta" style="color:var(--error)">[error]</div>' : "")
    + argsHtml;
  handlers.showTooltip(event, html);
}

function computeInnerSegments(messages) {
  const segments = [];
  let lastUserMs = null;
  let lastUserGameTime = null;
  const pendingTools = new Map();

  for (const messageRecord of messages) {
    const ts = Date.parse(messageRecord.createdAt);
    if (!Number.isFinite(ts)) continue;

    if (messageRecord.role === "user") {
      lastUserMs = ts;
      lastUserGameTime = messageRecord.gameTime || null;
      continue;
    }

    if (messageRecord.role === "assistant") {
      const startMs = lastUserMs != null ? lastUserMs : ts;
      const startGameTime = lastUserGameTime || messageRecord.gameTime || null;
      const endGameTime = messageRecord.gameTime || null;
      const usage = messageRecord.message && messageRecord.message.usage;
      const tokens = tokenCountFromUsage(usage);
      const costUsd = costFromUsage(usage);
      const isError = !!(messageRecord.message && messageRecord.message.errorMessage);
      segments.push({
        kind: "llm",
        startMs,
        endMs: ts,
        startGameTime,
        endGameTime,
        startGameMinute: gameTimeTotalMinutes(startGameTime),
        endGameMinute: gameTimeTotalMinutes(endGameTime),
        label: "assistant #" + messageRecord.seq
          + (
            messageRecord.message && messageRecord.message.stopReason
              ? " (" + messageRecord.message.stopReason + ")"
              : ""
        ),
        tokens,
        costUsd,
        isError,
        target: { kind: "message", seq: messageRecord.seq },
      });
      lastUserMs = ts;
      lastUserGameTime = messageRecord.gameTime || null;
      const calls = extractToolCalls(messageRecord.message || {});
      for (const toolCall of calls) {
        pendingTools.set(toolCall.id, {
          name: toolCall.name,
          args: toolCall.args,
          startMs: ts,
          startGameTime: messageRecord.gameTime || null,
          assistantSeq: messageRecord.seq,
        });
      }
      continue;
    }

    if (messageRecord.role === "toolResult") {
      const callId = (messageRecord.message
        && (messageRecord.message.toolCallId || messageRecord.message.tool_call_id))
        || "";
      const pending = pendingTools.get(callId);
      const startMs = pending ? pending.startMs : (lastUserMs ?? ts);
      const startGameTime = pending ? pending.startGameTime : (lastUserGameTime || messageRecord.gameTime || null);
      const endGameTime = messageRecord.gameTime || null;
      const name = pending
        ? pending.name
        : ((messageRecord.message && (messageRecord.message.toolName || messageRecord.message.name)) || "?");
      const isError = toolResultIsFailure(messageRecord.message);
      segments.push({
        kind: "tool",
        startMs,
        endMs: ts,
        startGameTime,
        endGameTime,
        startGameMinute: gameTimeTotalMinutes(startGameTime),
        endGameMinute: gameTimeTotalMinutes(endGameTime),
        label: name + " #" + messageRecord.seq,
        tokens: null,
        costUsd: null,
        isError,
        args: pending ? pending.args : undefined,
        target: {
          kind: "tool",
          toolCallId: callId,
          assistantSeq: pending ? pending.assistantSeq : null,
          resultSeq: messageRecord.seq,
        },
      });
      if (pending) pendingTools.delete(callId);
      lastUserMs = ts;
      lastUserGameTime = messageRecord.gameTime || null;
    }
  }
  return segments;
}

function buildInventoryView(turn, snapshot) {
  const wrap = document.createElement("div");
  if (!snapshot) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "这个 turn 没保存背包快照（老数据 / 还没产生 user message）";
    wrap.appendChild(empty);
    return wrap;
  }
  const inventory = Array.isArray(snapshot.inventory) ? snapshot.inventory : [];
  const backpack = Array.isArray(snapshot.backpack) ? snapshot.backpack : [];
  const walletCenti = Number.isFinite(snapshot.walletCenti) ? snapshot.walletCenti : 0;

  const meta = document.createElement("div");
  meta.className = "prompt-memory-meta";
  meta.textContent = "turn 入口 LLM 实际看到的背包快照（与 user prompt 中文本一致，按 slot 解析）。"
    + " 装备槽 " + inventory.length + " 件 · 背包 " + backpack.length + " 件"
    + " · 钱包 " + (walletCenti / 100).toFixed(2) + " 银";
  wrap.appendChild(meta);

  wrap.appendChild(buildInventorySection("钱包", ["silver_coin × " + (walletCenti / 100).toFixed(2) + " 银"]));
  wrap.appendChild(buildInventorySection("装备槽 (equipment / slotIndex < 0)", inventory));
  wrap.appendChild(buildInventorySection("背包 (slotIndex >= 0)", backpack));
  return wrap;
}

function buildInventorySection(title, entries) {
  const section = document.createElement("div");
  section.className = "section";
  const heading = document.createElement("h4");
  heading.textContent = title + " (" + entries.length + ")";
  section.appendChild(heading);
  if (entries.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "空";
    section.appendChild(empty);
    return section;
  }
  const list = document.createElement("ul");
  list.style.listStyle = "none";
  list.style.padding = "0";
  list.style.margin = "0";
  for (const entry of entries) {
    const li = document.createElement("li");
    li.style.padding = "4px 8px";
    li.style.borderBottom = "1px solid var(--border)";
    li.style.fontFamily = "ui-monospace, monospace";
    li.style.fontSize = "12px";
    li.textContent = String(entry ?? "");
    list.appendChild(li);
  }
  section.appendChild(list);
  return section;
}

function buildMemoryView(memoryView) {
  const wrap = document.createElement("div");
  if (!memoryView) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "加载 memory 中…或本 session 没有 memory 数据";
    wrap.appendChild(empty);
    return wrap;
  }
  if (memoryView.error) {
    const err = document.createElement("div");
    err.className = "error";
    err.textContent = String(memoryView.error);
    wrap.appendChild(err);
    return wrap;
  }

  const working = memoryView.workingMemory;
  const latest = memoryView.latestThinkingTurn;

  const meta = document.createElement("div");
  meta.className = "prompt-memory-meta";
  meta.innerHTML = "runtime=" + escapeHtml(memoryView.runtimeName || "—")
    + (working ? " · working_memory updatedAt=" + escapeHtml(formatRealTime(working.updatedAt)) : " · 无 working_memory");
  wrap.appendChild(meta);

  const section = document.createElement("div");
  section.className = "section";
  const heading = document.createElement("h4");
  heading.textContent = "最新 working_memory";
  section.appendChild(heading);
  if (working && working.content) {
    const metaLine = document.createElement("div");
    metaLine.className = "meta";
    metaLine.style.marginBottom = "6px";
    metaLine.innerHTML = ""
      + (working.triggerReason ? '<span class="pill">reason=' + escapeHtml(working.triggerReason) + "</span> " : "")
      + (working.gameTime ? '<span class="pill">' + escapeHtml(formatGameTime(working.gameTime, { short: true })) + "</span>" : "");
    section.appendChild(metaLine);
    const pre = document.createElement("pre");
    pre.textContent = working.content;
    section.appendChild(pre);
  } else {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "runtime_storage 里没有 working_memory（thinking 轨还没写过）";
    section.appendChild(empty);
  }
  wrap.appendChild(section);

  if (latest) {
    const thinkSection = document.createElement("div");
    thinkSection.className = "section";
    const h = document.createElement("h4");
    h.textContent = "最新一次 thinking turn";
    thinkSection.appendChild(h);
    const summaryLine = document.createElement("div");
    summaryLine.className = "meta";
    summaryLine.style.marginBottom = "6px";
    summaryLine.innerHTML = ""
      + '<span class="pill">reason=' + escapeHtml(latest.triggerReason || "—") + "</span> "
      + (latest.intent ? '<span class="pill">intent=' + escapeHtml(latest.intent) + "</span> " : "")
      + '<span class="pill">' + escapeHtml(formatGameTime(latest.endGameTime || latest.startGameTime, { short: true })) + "</span> "
      + (latest.totalTokens != null ? '<span class="pill">' + escapeHtml(formatTokenCount(latest.totalTokens)) + "</span> " : "")
      + (latest.costUsd != null ? '<span class="pill">' + escapeHtml(formatCostUsd(latest.costUsd)) + "</span> " : "")
      + (latest.error ? '<span class="pill" style="color:var(--error)">error</span>' : "");
    thinkSection.appendChild(summaryLine);
    if (latest.writtenContent) {
      const pre = document.createElement("pre");
      pre.textContent = latest.writtenContent;
      thinkSection.appendChild(pre);
    } else if (!latest.error) {
      const empty = document.createElement("div");
      empty.className = "empty";
      empty.textContent = "这次 thinking turn 没写出 working_memory";
      thinkSection.appendChild(empty);
    }
    wrap.appendChild(thinkSection);
  }

  return wrap;
}

function renderMemoryListHtml(memories, title) {
  const list = Array.isArray(memories) ? memories : [];
  const cards = list.length === 0
    ? '<div class="empty">没有 memory</div>'
    : list.map((memory) => {
      const importance = typeof memory.importance === "number" ? memory.importance : "—";
      const sourceEventIds = Array.isArray(memory.sourceEventIds) && memory.sourceEventIds.length > 0
        ? memory.sourceEventIds.join(", ")
        : "—";
      return ""
        + '<div class="memory-card">'
        + '<div class="head">'
        + '<span class="kind">' + escapeHtml(memory.kind || "unknown") + "</span>"
        + '<span class="pill">importance=' + escapeHtml(String(importance)) + "</span>"
        + '<span class="meta">created=' + escapeHtml(formatRealTime(memory.createdAt)) + "</span>"
        + '<span class="meta">lastAccessed=' + escapeHtml(formatRealTime(memory.lastAccessedAt)) + "</span>"
        + "</div>"
        + "<pre>" + escapeHtml(memory.text || "") + "</pre>"
        + '<div class="meta">id=' + escapeHtml(memory.id || "") + "</div>"
        + '<div class="meta">sourceEventIds=' + escapeHtml(sourceEventIds) + "</div>"
        + "</div>";
    }).join("");
  return ""
    + '<div class="section">'
    + "<h4>" + escapeHtml(title) + " (" + list.length + ")</h4>"
    + '<div class="memory-list">' + cards + "</div>"
    + "</div>";
}

function buildLazyTopTabs(tabs, defaultKey) {
  const wrap = document.createElement("div");
  wrap.className = "top-tabs";
  const tabBar = document.createElement("div");
  tabBar.className = "tab-bar";
  const panel = document.createElement("div");
  panel.className = "tab-panel";
  let activeKey = defaultKey || (tabs[0] && tabs[0].key);

  function renderActive() {
    for (const btn of tabBar.querySelectorAll(".tab-btn")) {
      btn.classList.toggle("active", btn.dataset.key === activeKey);
    }
    const tab = tabs.find((item) => item.key === activeKey) || tabs[0];
    panel.innerHTML = "";
    if (tab) panel.appendChild(tab.build());
  }

  for (const tab of tabs) {
    const button = document.createElement("button");
    button.className = "tab-btn";
    button.type = "button";
    button.dataset.key = tab.key;
    button.textContent = tab.label;
    button.addEventListener("click", () => {
      activeKey = tab.key;
      renderActive();
    });
    tabBar.appendChild(button);
  }

  wrap.appendChild(tabBar);
  wrap.appendChild(panel);
  renderActive();
  return wrap;
}
`;
