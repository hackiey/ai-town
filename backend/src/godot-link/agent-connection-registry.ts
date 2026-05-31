import { WebSocket } from "ws";
import { type Locale, SOURCE_LOCALE } from "../i18n/index.js";
import { PROTOCOL_VERSION, type MessageEnvelope, type TownId } from "./protocol.js";

type AgentConnectionLogger = {
  info(data: Record<string, unknown>, message: string): void;
};

type RuntimeConnection = {
  townId: TownId;
  instanceId: string;
  socket: WebSocket;
  connectedAt: string;
  lastSeenAt: string;
  lastAckSeq: number;
  nextSeq: number;
  locale: Locale;
};

export type AgentConnectionSnapshot = Omit<RuntimeConnection, "socket"> & {
  readyState: number;
};

export class AgentConnectionRegistry {
  private readonly connections = new Map<TownId, RuntimeConnection>();

  constructor(private readonly log: AgentConnectionLogger) {}

  register(params: {
    townId: TownId;
    instanceId: string;
    socket: WebSocket;
    lastAckSeq: number;
    locale: Locale;
  }): AgentConnectionSnapshot {
    const existing = this.connections.get(params.townId);
    if (existing && existing.socket !== params.socket) {
      existing.socket.close(4000, "replaced by a newer runtime connection");
    }

    const now = new Date().toISOString();
    const connection: RuntimeConnection = {
      townId: params.townId,
      instanceId: params.instanceId,
      socket: params.socket,
      connectedAt: now,
      lastSeenAt: now,
      lastAckSeq: params.lastAckSeq,
      nextSeq: params.lastAckSeq + 1,
      locale: params.locale,
    };

    this.connections.set(params.townId, connection);
    this.log.info({ townId: params.townId, instanceId: params.instanceId }, "Godot agent connection registered");
    return snapshot(connection);
  }

  unregister(townId: TownId, instanceId: string, socket?: WebSocket): AgentConnectionSnapshot | null {
    const current = this.connections.get(townId);
    if (!current || current.instanceId !== instanceId || (socket && current.socket !== socket)) {
      return null;
    }

    this.connections.delete(townId);
    this.log.info({ townId, instanceId }, "Godot agent connection unregistered");
    return snapshot(current);
  }

  touch(townId: TownId): void {
    const connection = this.connections.get(townId);
    if (connection) {
      connection.lastSeenAt = new Date().toISOString();
    }
  }

  markAck(townId: TownId, ackSeq: number): void {
    const connection = this.connections.get(townId);
    if (!connection) {
      return;
    }
    connection.lastAckSeq = Math.max(connection.lastAckSeq, ackSeq);
    connection.lastSeenAt = new Date().toISOString();
  }

  hasConnection(townId: TownId): boolean {
    const connection = this.connections.get(townId);
    return connection?.socket.readyState === WebSocket.OPEN;
  }

  // 当前 Godot agent connection 的 locale。连接未建立时 fallback 到 SOURCE_LOCALE。
  // fallback 到 SOURCE_LOCALE，调用方拿到的 prompt 是中文。
  getLocale(townId: TownId): Locale {
    return this.connections.get(townId)?.locale ?? SOURCE_LOCALE;
  }

  send<TPayload>(townId: TownId, type: string, payload: TPayload): MessageEnvelope<TPayload> | null {
    const connection = this.connections.get(townId);
    if (!connection || connection.socket.readyState !== WebSocket.OPEN) {
      return null;
    }

    const envelope: MessageEnvelope<TPayload> = {
      id: createProtocolMessageId("msg"),
      seq: connection.nextSeq,
      type,
      townId,
      createdAt: new Date().toISOString(),
      version: PROTOCOL_VERSION,
      payload,
    };

    connection.nextSeq += 1;
    connection.socket.send(JSON.stringify(envelope));
    return envelope;
  }

  list(): AgentConnectionSnapshot[] {
    return Array.from(this.connections.values(), snapshot);
  }

  closeAll(reason: string): void {
    for (const connection of this.connections.values()) {
      connection.socket.close(1001, reason);
    }
    this.connections.clear();
  }
}

function createProtocolMessageId(prefix: string): string {
  return `${prefix}_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
}

function snapshot(connection: RuntimeConnection): AgentConnectionSnapshot {
  return {
    townId: connection.townId,
    instanceId: connection.instanceId,
    connectedAt: connection.connectedAt,
    lastSeenAt: connection.lastSeenAt,
    lastAckSeq: connection.lastAckSeq,
    nextSeq: connection.nextSeq,
    locale: connection.locale,
    readyState: connection.socket.readyState,
  };
}
