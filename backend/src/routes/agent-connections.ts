import type { FastifyPluginAsync } from "fastify";

export const agentConnectionHttpRoutes: FastifyPluginAsync = async (app) => {
  app.get("/agent-connections", async () => ({
    connections: app.agentConnections.list(),
  }));
};
