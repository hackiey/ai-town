import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import type { FastifyPluginAsync } from "fastify";

const MAX_MAP_BYTES = 2_000_000;
const MAX_TOWNS_RETURNED = 100;

type JsonObject = Record<string, unknown>;

type TownRow = {
  id: string;
  name: string;
  authorName: string;
  description: string;
  mapJson: string;
  width: number;
  height: number;
  buildingCount: number;
  editTokenHash: string;
  createdAt: string;
  updatedAt: string;
};

type PublishTownBody = {
  name?: unknown;
  authorName?: unknown;
  description?: unknown;
  map?: unknown;
};

export const publicTownRoutes: FastifyPluginAsync = async (app) => {
  app.get("/api/towns", async () => {
    const rows = app.db
      .prepare(
        `SELECT id, name, authorName, description, width, height, buildingCount, createdAt, updatedAt
         FROM public_towns
         ORDER BY updatedAt DESC
         LIMIT ?`,
      )
      .all(MAX_TOWNS_RETURNED) as Omit<TownRow, "mapJson" | "editTokenHash">[];
    return { towns: rows.map(toTownSummary) };
  });

  app.get<{ Params: { id: string } }>("/api/towns/:id", async (request, reply) => {
    const row = app.db.prepare("SELECT * FROM public_towns WHERE id = ?").get(request.params.id) as TownRow | undefined;
    if (!row) {
      return reply.code(404).send({ ok: false, error: "town_not_found" });
    }
    return {
      ok: true,
      town: {
        ...toTownSummary(row),
        map: JSON.parse(row.mapJson) as JsonObject,
      },
    };
  });

  app.post<{ Body: PublishTownBody }>("/api/towns", async (request, reply) => {
    const parsed = parsePublishBody(request.body);
    if (!parsed.ok) {
      return reply.code(400).send({ ok: false, error: parsed.error });
    }
    const id = `town_${randomBytes(8).toString("hex")}`;
    const editToken = randomBytes(24).toString("base64url");
    const now = new Date().toISOString();
    app.db
      .prepare(
        `INSERT INTO public_towns (
          id, name, authorName, description, mapJson, width, height, buildingCount,
          editTokenHash, createdAt, updatedAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        id,
        parsed.name,
        parsed.authorName,
        parsed.description,
        parsed.mapJson,
        parsed.width,
        parsed.height,
        parsed.buildingCount,
        hashToken(editToken),
        now,
        now,
      );
    const row = app.db.prepare("SELECT * FROM public_towns WHERE id = ?").get(id) as TownRow;
    return reply.code(201).send({ ok: true, town: toTownSummary(row), editToken });
  });

  app.put<{ Params: { id: string }; Body: PublishTownBody }>("/api/towns/:id", async (request, reply) => {
    const row = app.db.prepare("SELECT * FROM public_towns WHERE id = ?").get(request.params.id) as TownRow | undefined;
    if (!row) {
      return reply.code(404).send({ ok: false, error: "town_not_found" });
    }
    const editToken = readEditToken(request.headers["x-town-edit-token"]);
    if (!editToken || !tokensMatch(row.editTokenHash, editToken)) {
      return reply.code(403).send({ ok: false, error: "invalid_edit_token" });
    }
    const parsed = parsePublishBody(request.body);
    if (!parsed.ok) {
      return reply.code(400).send({ ok: false, error: parsed.error });
    }
    const now = new Date().toISOString();
    app.db
      .prepare(
        `UPDATE public_towns
         SET name = ?, authorName = ?, description = ?, mapJson = ?, width = ?, height = ?,
             buildingCount = ?, updatedAt = ?
         WHERE id = ?`,
      )
      .run(
        parsed.name,
        parsed.authorName,
        parsed.description,
        parsed.mapJson,
        parsed.width,
        parsed.height,
        parsed.buildingCount,
        now,
        row.id,
      );
    const updated = app.db.prepare("SELECT * FROM public_towns WHERE id = ?").get(row.id) as TownRow;
    return { ok: true, town: toTownSummary(updated) };
  });
};

function parsePublishBody(body: PublishTownBody | undefined):
  | {
      ok: true;
      name: string;
      authorName: string;
      description: string;
      mapJson: string;
      width: number;
      height: number;
      buildingCount: number;
    }
  | { ok: false; error: string } {
  const name = cleanText(body?.name, 80);
  const authorName = cleanText(body?.authorName, 48) || "匿名镇长";
  const description = cleanText(body?.description, 300);
  if (!name) {
    return { ok: false, error: "name_required" };
  }
  if (!isJsonObject(body?.map)) {
    return { ok: false, error: "map_required" };
  }
  const size = body.map.size;
  if (!Array.isArray(size) || size.length < 2) {
    return { ok: false, error: "invalid_map_size" };
  }
  const width = Number(size[0]);
  const height = Number(size[1]);
  if (!Number.isInteger(width) || !Number.isInteger(height) || width < 8 || height < 8 || width > 256 || height > 256) {
    return { ok: false, error: "invalid_map_size" };
  }
  const mapJson = JSON.stringify(body.map);
  if (Buffer.byteLength(mapJson, "utf8") > MAX_MAP_BYTES) {
    return { ok: false, error: "map_too_large" };
  }
  const buildings = Array.isArray(body.map.buildings) ? body.map.buildings : [];
  if (buildings.length > 5000) {
    return { ok: false, error: "too_many_buildings" };
  }
  return {
    ok: true,
    name,
    authorName,
    description,
    mapJson,
    width,
    height,
    buildingCount: buildings.length,
  };
}

function toTownSummary(row: Omit<TownRow, "mapJson" | "editTokenHash"> | TownRow) {
  return {
    id: row.id,
    name: row.name,
    authorName: row.authorName,
    description: row.description,
    width: row.width,
    height: row.height,
    buildingCount: row.buildingCount,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  };
}

function cleanText(value: unknown, maximumLength: number): string {
  return typeof value === "string" ? value.trim().slice(0, maximumLength) : "";
}

function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function readEditToken(value: string | string[] | undefined): string {
  if (Array.isArray(value)) {
    return value[0] ?? "";
  }
  return value ?? "";
}

function hashToken(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function tokensMatch(expectedHash: string, token: string): boolean {
  const actual = Buffer.from(hashToken(token), "hex");
  const expected = Buffer.from(expectedHash, "hex");
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}
