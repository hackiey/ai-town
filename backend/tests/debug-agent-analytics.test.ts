import assert from "node:assert/strict";
import test from "node:test";
import Fastify from "fastify";
import type { AppDb } from "../src/db/sqlite.js";
import { toolAnalyticsRoutes } from "../src/routes/debug-agent/analytics.js";
import { createTestDb } from "./helpers/test-db.js";

test("tool analytics counts action failure details as tool errors", async () => {
  const { app, db } = await createAnalyticsApp();
  try {
    insertToolResult(db, {
      id: "msg-1",
      sessionId: "session-mira",
      characterId: "mira_blacksmith",
      seq: 1,
      createdAt: "2026-01-01T00:00:00.000Z",
      message: { toolName: "move_to_location", content: "ok", details: { status: "completed" } },
    });
    insertToolResult(db, {
      id: "msg-2",
      sessionId: "session-mira",
      characterId: "mira_blacksmith",
      seq: 2,
      createdAt: "2026-01-01T00:01:00.000Z",
      message: { toolName: "move_to_location", content: "blocked", details: { status: "failed" } },
    });
    insertToolResult(db, {
      id: "msg-3",
      sessionId: "session-oren",
      characterId: "oren_vale",
      seq: 1,
      createdAt: "2026-01-01T00:02:00.000Z",
      message: { toolName: "say_to", content: "tool exception", isError: true },
    });

    const response = await app.inject({ method: "GET", url: "/debug/api/tool-analytics?limit=10" });
    assert.equal(response.statusCode, 200);
    const payload = response.json();

    assert.equal(payload.totals.totalCalls, 3);
    assert.equal(payload.totals.totalErrors, 2);
    const move = payload.perTool.find((row: { name: string }) => row.name === "move_to_location");
    assert.equal(move.totalCount, 2);
    assert.equal(move.errorCount, 1);
  } finally {
    await app.close();
    db.close();
  }
});

test("tool analytics call details paginate and filter by failure and character", async () => {
  const { app, db } = await createAnalyticsApp();
  try {
    insertToolResult(db, {
      id: "msg-1",
      sessionId: "session-mira",
      characterId: "mira_blacksmith",
      seq: 1,
      createdAt: "2026-01-01T00:00:00.000Z",
      message: { toolName: "move_to_location", content: "arrived", details: { status: "completed" } },
    });
    insertToolResult(db, {
      id: "msg-2",
      sessionId: "session-oren",
      characterId: "oren_vale",
      seq: 2,
      createdAt: "2026-01-01T00:01:00.000Z",
      message: { toolName: "move_to_location", content: "path blocked", details: { status: "failed" } },
    });
    insertToolResult(db, {
      id: "msg-3",
      sessionId: "session-mira",
      characterId: "mira_blacksmith",
      seq: 3,
      createdAt: "2026-01-01T00:02:00.000Z",
      message: { toolName: "move_to_location", content: "door locked", details: { status: "failed" } },
    });

    const page1 = await app.inject({
      method: "GET",
      url: "/debug/api/tool-analytics/calls?tool=move_to_location&pageSize=1&page=1",
    });
    assert.equal(page1.statusCode, 200);
    const page1Payload = page1.json();
    assert.equal(page1Payload.total, 3);
    assert.equal(page1Payload.calls.length, 1);
    assert.equal(page1Payload.calls[0].seq, 3);
    assert.equal(page1Payload.calls[0].failed, true);
    assert.equal(page1Payload.hasNext, true);

    const page2 = await app.inject({
      method: "GET",
      url: "/debug/api/tool-analytics/calls?tool=move_to_location&pageSize=1&page=2",
    });
    assert.equal(page2.json().calls[0].seq, 2);

    const failedMira = await app.inject({
      method: "GET",
      url: "/debug/api/tool-analytics/calls?tool=move_to_location&status=failed&characterId=mira_blacksmith",
    });
    const failedMiraPayload = failedMira.json();
    assert.equal(failedMiraPayload.total, 1);
    assert.equal(failedMiraPayload.calls[0].characterId, "mira_blacksmith");
    assert.equal(failedMiraPayload.calls[0].status, "failed");
  } finally {
    await app.close();
    db.close();
  }
});

async function createAnalyticsApp(): Promise<{ app: ReturnType<typeof Fastify>; db: AppDb }> {
  const db = createTestDb();
  const app = Fastify({ logger: false });
  app.decorate("db", db);
  await app.register(toolAnalyticsRoutes);
  return { app, db };
}

function insertToolResult(
  db: AppDb,
  input: {
    id: string;
    sessionId: string;
    characterId: string;
    seq: number;
    createdAt: string;
    message: Record<string, unknown>;
  },
): void {
  db.prepare(
    `INSERT INTO agent_session_messages
       (id, sessionId, townId, characterId, agentKind, seq, role, message, createdAt, gameTime)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(
    input.id,
    input.sessionId,
    "town_001",
    input.characterId,
    "npc",
    input.seq,
    "toolResult",
    JSON.stringify(input.message),
    input.createdAt,
    JSON.stringify({ totalGameMinutes: input.seq }),
  );
}
