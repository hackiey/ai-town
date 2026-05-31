import fp from "fastify-plugin";
import type { AppConfig } from "../config/env.js";

declare module "fastify" {
  interface FastifyInstance {
    config: AppConfig;
  }
}

export const configPlugin = fp<{ config: AppConfig }>(async (app, opts) => {
  app.decorate("config", opts.config);
});
