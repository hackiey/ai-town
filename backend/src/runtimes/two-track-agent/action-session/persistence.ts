// Session 持久化：管理 agent_sessions 记录 + 消息追加 + usage 累计。
// 用一条 promise 链串起 append 顺序，避免并发追加打乱 seq。

import type { AgentMessage } from "@mariozechner/pi-agent-core";
import type { AgentRuntimeContext } from "../../../agent-host/runtime.js";
import type { GameTimeSnapshot } from "../../../godot-link/protocol.js";
import type {
  AgentInventorySnapshot,
  AgentKind,
  AgentSessionMessageRecord,
  AgentSessionRecord,
  AgentToolSnapshot,
} from "../../../agents/types.js";
import { createMessageId } from "../../../services/ids.js";
import {
  agentMessageRole,
  assistantUsage,
  isAssistantMessage,
  persistedMessageKey,
  usageCostUsd,
  usageTokenCount,
} from "../../../agent-shared/utils/agent-message.js";
import type { PiAgentRuntimeLogger } from "../runtime.js";

const AGENT_SESSION_ID_PREFIX = "agent_session";

export type PersistAgentMessageSnapshot = {
  gameTime?: GameTimeSnapshot;
  toolsSnapshot?: AgentToolSnapshot[];
  llmMessages?: AgentMessage[];
  llmSystemPrompt?: string;
  inventorySnapshot?: AgentInventorySnapshot;
};

type PersistedMessageRef = {
  id: string;
  seq: number;
};

export type SessionPersistenceOptions = {
  ctx: AgentRuntimeContext;
  townId: string;
  characterId: string;
  agentKind: AgentKind;
  logger?: PiAgentRuntimeLogger;
  // 取当前 think reason。append 时记录到 agent_sessions_messages.turnReason 列。
  getCurrentTurnReason: () => string | undefined;
};

// 管 agent_sessions 行 + agent_sessions_messages 队列追加。
// AgentSession record 在 ensure() 时缓存，append/updateUsage 后更新。
export class SessionPersistence {
  private session?: AgentSessionRecord;
  private persistQueue: Promise<void> = Promise.resolve();
  private readonly persistedMessageRefs = new Map<string, PersistedMessageRef>();

  constructor(private readonly options: SessionPersistenceOptions) {}

  get currentSession(): AgentSessionRecord | undefined {
    return this.session;
  }

  sessionId(): string {
    return `${AGENT_SESSION_ID_PREFIX}:${this.options.agentKind}:${this.options.townId}:${this.options.characterId}`;
  }

  async ensureSession(): Promise<AgentSessionRecord> {
    const session = await this.options.ctx.sessions().ensure({
      id: this.sessionId(),
      townId: this.options.townId,
      characterId: this.options.characterId,
      agentKind: this.options.agentKind,
    });
    this.session = session;
    return session;
  }

  // 等当前 append 队列排空。turn 入口在 build context 前调，确保 seq 顺序与 history 装配看到的一致。
  async drain(): Promise<void> {
    await this.persistQueue;
  }

  // 入队一条消息持久化。aborted 的 assistant message 不入队（不进历史）。
  enqueueMessage(message: AgentMessage, snapshot: PersistAgentMessageSnapshot = {}): void {
    if (isAssistantMessage(message) && message.stopReason === "aborted") {
      return;
    }
    this.persistQueue = this.persistQueue
      .then(() => this.persistMessage(message, snapshot))
      .catch((error) => {
        this.options.logger?.error({
          error,
          townId: this.options.townId,
          characterId: this.options.characterId,
          agentKind: this.options.agentKind,
        }, "failed to persist agent message");
      });
  }

  async listMessagesAfter(cutoff: number, options?: { limit?: number; order?: "asc" | "desc" }): Promise<AgentSessionMessageRecord[]> {
    const session = await this.ensureSession();
    return this.options.ctx.sessions().listMessages(session.id, {
      afterSeq: cutoff,
      limit: options?.limit,
      order: options?.order ?? "asc",
    });
  }

  private async persistMessage(message: AgentMessage, snapshot: PersistAgentMessageSnapshot): Promise<void> {
    const session = await this.ensureSession();
    const id = createMessageId("agent_msg");
    const updated = await this.options.ctx.sessions().appendMessage({
      id,
      sessionId: session.id,
      townId: this.options.townId,
      characterId: this.options.characterId,
      agentKind: this.options.agentKind,
      role: agentMessageRole(message),
      message,
      gameTime: snapshot.gameTime,
      turnReason: this.options.getCurrentTurnReason(),
      toolsSnapshot: snapshot.toolsSnapshot,
      llmMessages: snapshot.llmMessages,
      llmSystemPrompt: snapshot.llmSystemPrompt,
      inventorySnapshot: snapshot.inventorySnapshot,
    });
    const seq = updated.messageSeq;
    const key = persistedMessageKey(message);
    if (key) {
      this.persistedMessageRefs.set(key, { id, seq });
    }
    const usage = assistantUsage(message);
    if (usage) {
      this.session = await this.options.ctx.sessions().updateUsage({
        sessionId: session.id,
        usage,
        tokenCount: usageTokenCount(usage),
        costUsd: usageCostUsd(usage),
      });
      return;
    }
    this.session = updated;
  }
}
