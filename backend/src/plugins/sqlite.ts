import fp from "fastify-plugin";
import { openDatabase, type AppDb } from "../db/sqlite.js";

declare module "fastify" {
  interface FastifyInstance {
    db: AppDb;
  }
}

export const sqlitePlugin = fp(async (app) => {
  const db = openDatabase(app.config.dbPath);
  app.decorate("db", db);
  app.log.info({ dbPath: app.config.dbPath }, "sqlite database opened");
  app.addHook("onClose", async () => {
    db.close();
  });
});
