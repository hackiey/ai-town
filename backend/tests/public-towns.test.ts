import assert from "node:assert/strict";
import test from "node:test";
import Fastify from "fastify";
import { publicTownRoutes } from "../src/routes/public-towns.js";
import { createTestDb } from "./helpers/test-db.js";

const sampleMap = {
  version: 4,
  tile_size: 32,
  size: [48, 32],
  player_spawn: [24, 16],
  tiles: { meadow: 37, path: 0, field: 10, water: 18 },
  layers: { roads: [], fields: [], water: [] },
  fences: [],
  buildings: [{ id: "home", asset: "house_1", cell: [20, 16], footprint: [4, 4] }],
  decorations: [],
  locations: [],
};

test("public town routes publish, list, download and protect updates", async () => {
  const app = Fastify();
  const db = createTestDb();
  app.decorate("db", db);
  await app.register(publicTownRoutes);

  const created = await app.inject({
    method: "POST",
    url: "/api/towns",
    payload: { name: "测试小镇", authorName: "镇长", description: "第一张地图", map: sampleMap },
  });
  assert.equal(created.statusCode, 201);
  const createdBody = created.json();
  assert.equal(createdBody.ok, true);
  assert.match(createdBody.town.id, /^town_[a-f0-9]{16}$/);
  assert.equal(typeof createdBody.editToken, "string");

  const listed = await app.inject({ method: "GET", url: "/api/towns" });
  assert.equal(listed.statusCode, 200);
  assert.equal(listed.json().towns.length, 1);
  assert.equal(listed.json().towns[0].buildingCount, 1);

  const downloaded = await app.inject({ method: "GET", url: `/api/towns/${createdBody.town.id}` });
  assert.equal(downloaded.statusCode, 200);
  assert.deepEqual(downloaded.json().town.map.size, [48, 32]);

  const denied = await app.inject({
    method: "PUT",
    url: `/api/towns/${createdBody.town.id}`,
    payload: { name: "非法修改", authorName: "别人", map: sampleMap },
  });
  assert.equal(denied.statusCode, 403);

  const updated = await app.inject({
    method: "PUT",
    url: `/api/towns/${createdBody.town.id}`,
    headers: { "x-town-edit-token": createdBody.editToken },
    payload: { name: "更新后小镇", authorName: "镇长", description: "第二版", map: sampleMap },
  });
  assert.equal(updated.statusCode, 200);
  assert.equal(updated.json().town.name, "更新后小镇");

  await app.close();
  db.close();
});
