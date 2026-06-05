import fp from "fastify-plugin";
import type { FastifyInstance } from "fastify";
import { WebSocket } from "ws";
import { rowToRuntimeSession } from "../db/records.js";
import type { RuntimeSessionRecord } from "../godot-link/protocol.js";
import { handleGodotMessage as handleGodotProtocolMessage } from "../agent-host/godot-message-handler.js";
import { SOURCE_LOCALE } from "../i18n/index.js";
import { createMessageId } from "../services/ids.js";
import { ensureMemoriesSeededForTown } from "../services/memory-service.js";
import { loadNpcRuntimeRouter } from "../agent-host/router.js";
import {
  AGENT_HOST_MESSAGE,
  PROTOCOL_VERSION,
  RUNTIME_MESSAGE,
  SERVER_MESSAGE,
  type MessageEnvelope,
} from "../godot-link/protocol.js";

export const godotAgentClientPlugin = fp(async (app) => {
  const config = app.config.agentHost;
  if (!config.enabled) {
    app.log.info("godot agent-host client disabled");
    return;
  }

  let socket: WebSocket | null = null;
  let reconnectTimer: NodeJS.Timeout | undefined;
  let closed = false;
  let lastGodotAckSeq = readLastGodotAckSeq(app, config.townId);

  const connect = () => {
    if (closed) {
      return;
    }
    const connection = new WebSocket(config.godotWsUrl);
    socket = connection;
    let registered = false;
    let connectedAt = "";

    connection.on("open", () => {
      if (socket !== connection) {
        connection.close(4000, "replaced by a newer runtime connection");
        return;
      }
      app.log.info({ url: config.godotWsUrl, townId: config.townId }, "connected to Godot agent server");
      connectedAt = new Date().toISOString();
      sendEnvelope(connection, config.townId, AGENT_HOST_MESSAGE.hello, {
        instanceId: config.instanceId,
        token: app.config.agentHostToken,
        lastAckSeq: lastGodotAckSeq,
        locale: SOURCE_LOCALE,
      });
    });

    connection.on("message", (raw) => {
      if (socket !== connection) {
        return;
      }
      handleGodotSocketMessage(connection, raw.toString(), () => {
        registered = true;
      }).catch((error) => {
        app.log.error({ err: error }, "failed to handle Godot agent server message");
      });
    });

    connection.on("close", (code, reason) => {
      const wasCurrentSocket = socket === connection;
      if (wasCurrentSocket) {
        socket = null;
      }
      app.log.warn({ code, reason: reason.toString(), url: config.godotWsUrl }, "Godot agent server connection closed");
      if (registered) {
        const disconnected = app.agentConnections.unregister(config.townId, config.instanceId, connection);
        if (disconnected) {
          recordRuntimeSession(app, {
            townId: config.townId,
            instanceId: config.instanceId,
            connectedAt: disconnected.connectedAt || connectedAt,
            disconnectedAt: new Date().toISOString(),
            lastSeenAt: disconnected.lastSeenAt,
            lastAckSeq: lastGodotAckSeq,
          });
        }
        registered = false;
      }
      if (wasCurrentSocket) {
        scheduleReconnect();
      }
    });

    connection.on("error", (error) => {
      app.log.warn({ err: error, url: config.godotWsUrl }, "Godot agent server connection error");
    });
  };

  const scheduleReconnect = () => {
    if (closed || reconnectTimer) {
      return;
    }
    reconnectTimer = setTimeout(() => {
      reconnectTimer = undefined;
      connect();
    }, config.reconnectDelayMs);
  };

  const handleGodotSocketMessage = async (
    connection: WebSocket,
    raw: string,
    markRegistered: () => void,
  ): Promise<void> => {
    const message = JSON.parse(raw) as MessageEnvelope;
    if (message.townId !== config.townId) {
      throw new Error(`Godot message townId mismatch: ${message.townId}`);
    }
    if (socket !== connection) {
      return;
    }
    if (message.type === SERVER_MESSAGE.runtimeAccepted) {
      if (connection.readyState !== WebSocket.OPEN) {
        return;
      }
      app.agentConnections.register({
        townId: config.townId,
        instanceId: config.instanceId,
        socket: connection,
        lastAckSeq: 0,
        locale: SOURCE_LOCALE,
      });
      markRegistered();
      seedAgentHostData(app, config.townId).catch((error) => {
        app.log.error({ err: error, townId: config.townId }, "failed to seed/replay agent host data");
      });
      if (typeof message.seq === "number" && Number.isInteger(message.seq) && message.seq > 0) {
        lastGodotAckSeq = Math.max(lastGodotAckSeq, message.seq);
        sendEnvelope(connection, config.townId, RUNTIME_MESSAGE.protocolAck, { ackSeq: message.seq });
      }
      return;
    }

    await handleGodotProtocolMessage(app, config.townId, raw);
    if (typeof message.seq === "number" && Number.isInteger(message.seq) && message.seq > 0) {
      lastGodotAckSeq = Math.max(lastGodotAckSeq, message.seq);
      sendEnvelope(connection, config.townId, RUNTIME_MESSAGE.protocolAck, { ackSeq: message.seq });
    }
  };

  connect();

  app.addHook("onClose", async () => {
    closed = true;
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = undefined;
    }
    if (socket && socket.readyState === WebSocket.OPEN) {
      socket.close(1001, "backend shutting down");
    }
  });
});

async function seedAgentHostData(app: FastifyInstance, townId: string): Promise<void> {
  // 同步 agent-runtime 插件起 AgentHost 时的路由约定——按角色实际要走的 runtimeName 写 seed，
  // 否则 seed 写在错的命名空间，agent 启动读不到自己的 soul。
  const router = loadNpcRuntimeRouter();
  const { seeded, characters } = ensureMemoriesSeededForTown(
    app.db,
    townId,
    (characterId) => router.runtimeFor(characterId),
    SOURCE_LOCALE,
  );
  if (seeded > 0) {
    app.log.info({ townId, seeded, characters }, "seeded initial agent memories");
  }
}

function readLastGodotAckSeq(app: FastifyInstance, townId: string): number {
  try {
    if (!sqliteTableExists(app, "runtime_sessions")) {
      return 0;
    }
    const row = app.db
      .prepare("SELECT * FROM runtime_sessions WHERE townId = ? ORDER BY disconnectedAt DESC, lastSeenAt DESC LIMIT 1")
      .get(townId) as Record<string, unknown> | undefined;
    return row ? rowToRuntimeSession(row).lastAckSeq : 0;
  } catch (error) {
    app.log.warn({ err: error, townId }, "failed to read last agent ack seq");
    return 0;
  }
}

function sqliteTableExists(app: FastifyInstance, tableName: string): boolean {
  const row = app.db
    .prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?")
    .get(tableName);
  return row != null;
}

function recordRuntimeSession(app: FastifyInstance, record: RuntimeSessionRecord): void {
  try {
    app.db.prepare(
      `INSERT INTO runtime_sessions (townId, instanceId, connectedAt, disconnectedAt, lastSeenAt, lastAckSeq)
       VALUES (?, ?, ?, ?, ?, ?)`,
    ).run(
      record.townId,
      record.instanceId,
      record.connectedAt,
      record.disconnectedAt ?? null,
      record.lastSeenAt,
      record.lastAckSeq,
    );
  } catch (error) {
    app.log.warn({ err: error, townId: record.townId }, "failed to record agent runtime session");
  }
}

function sendEnvelope<TPayload>(socket: WebSocket | null, townId: string, type: string, payload: TPayload): void {
  if (!socket || socket.readyState !== WebSocket.OPEN) {
    return;
  }
  socket.send(JSON.stringify({
    id: createMessageId("msg"),
    type,
    townId,
    createdAt: new Date().toISOString(),
    version: PROTOCOL_VERSION,
    payload,
  }));
}
