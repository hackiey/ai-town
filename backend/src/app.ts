import { characterStatusBusPlugin } from "./plugins/character-status-bus.js";
import Fastify from "fastify";
import type { AppConfig } from "./config/env.js";
import { configPlugin } from "./plugins/config.js";
import { godotAgentClientPlugin } from "./plugins/godot-agent-client.js";
import { groupsPlugin } from "./plugins/groups.js";
import { actionBusPlugin } from "./plugins/action-bus.js";
import { memoryPlugin } from "./plugins/memory.js";
import { redisPlugin } from "./plugins/redis.js";
import { runtimeRegistryPlugin } from "./plugins/runtime-registry.js";
import { sqlitePlugin } from "./plugins/sqlite.js";
import { debugAgentRoutes } from "./routes/debug-agent.js";
import { healthRoutes } from "./routes/health.js";
import { agentConnectionHttpRoutes } from "./routes/agent-connections.js";

export async function buildApp(config: AppConfig) {
  const app = Fastify({
    logger: {
      level: config.logLevel,
    },
    disableRequestLogging: true,
  });

  await app.register(configPlugin, { config });
  await app.register(sqlitePlugin);
  await app.register(redisPlugin);
  await app.register(groupsPlugin);
  await app.register(memoryPlugin);
  await app.register(runtimeRegistryPlugin);
  await app.register(characterStatusBusPlugin);
  await app.register(actionBusPlugin);
  await app.register(godotAgentClientPlugin);

  await app.register(healthRoutes);
  await app.register(agentConnectionHttpRoutes);
  await app.register(debugAgentRoutes);

  return app;
}
