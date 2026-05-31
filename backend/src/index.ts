import "dotenv/config";
import { buildApp } from "./app.js";
import { loadConfig } from "./config/env.js";

const config = loadConfig();
const shouldInit = process.argv.includes("--INIT");

if (shouldInit) {
  throw new Error("backend --INIT has moved to the Godot server. Run: ./scripts/dev server --INIT");
}

const app = await buildApp(config);

const shutdown = async (signal: NodeJS.Signals) => {
  app.log.info({ signal }, "shutting down backend");
  await app.close();
  process.exit(0);
};

process.once("SIGINT", shutdown);
process.once("SIGTERM", shutdown);

await app.listen({
  host: config.host,
  port: config.port,
});
