import type { FastifyPluginAsync } from "fastify";

export const healthRoutes: FastifyPluginAsync = async (app) => {
  app.get("/health", async () => ({
    ok: true,
    service: "ai-games-backend",
    uptimeSec: Math.round(process.uptime()),
  }));

  app.get("/ready", async () => {
    app.db.prepare("SELECT 1").get();
    await app.redis.ping();
    return {
      ok: true,
      sqlite: "ok",
      redis: "ok",
    };
  });
};
