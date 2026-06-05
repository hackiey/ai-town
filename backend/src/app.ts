import { characterStatusBusPlugin } from "./plugins/character-status-bus.js";
import Fastify from "fastify";
import type { AppConfig } from "./config/env.js";
import { agentRuntimePlugin } from "./plugins/agent-runtime.js";
import { configPlugin } from "./plugins/config.js";
import { godotAgentClientPlugin } from "./plugins/godot-agent-client.js";
import { groupsPlugin } from "./plugins/groups.js";
import { actionBusPlugin } from "./plugins/action-bus.js";
import { memoryPlugin } from "./plugins/memory.js";
import { messageBusPlugin } from "./plugins/message-bus.js";
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
  await app.register(messageBusPlugin);
  await app.register(groupsPlugin);
  await app.register(memoryPlugin);
  await app.register(runtimeRegistryPlugin);
  await app.register(characterStatusBusPlugin);
  await app.register(actionBusPlugin);
  // agent runtime（原 worker.ts）订阅 world-event / perception / game-time 三条 bus；
  // 注册在 godot client 之前，确保 Godot 连上推事件前订阅已就绪。
  await app.register(agentRuntimePlugin);
  await app.register(godotAgentClientPlugin);

  await app.register(healthRoutes);
  await app.register(agentConnectionHttpRoutes);
  await app.register(debugAgentRoutes);

  return app;
}
