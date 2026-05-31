import fp from "fastify-plugin";
import { AgentConnectionRegistry } from "../godot-link/agent-connection-registry.js";

declare module "fastify" {
  interface FastifyInstance {
    agentConnections: AgentConnectionRegistry;
  }
}

export const runtimeRegistryPlugin = fp(async (app) => {
  const registry = new AgentConnectionRegistry(app.log);
  app.decorate("agentConnections", registry);

  app.addHook("onClose", async () => {
    registry.closeAll("server shutting down");
  });
});
