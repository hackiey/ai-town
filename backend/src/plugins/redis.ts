import fp from "fastify-plugin";
import { Redis } from "ioredis";

declare module "fastify" {
  interface FastifyInstance {
    redis: Redis;
    subRedis: Redis;
  }
}

export const redisPlugin = fp(async (app) => {
  const redis = new Redis(app.config.redisUrl);
  const subRedis = new Redis(app.config.redisUrl);

  app.decorate("redis", redis);
  app.decorate("subRedis", subRedis);

  app.addHook("onClose", async () => {
    await Promise.all([redis.quit(), subRedis.quit()]);
  });
});
