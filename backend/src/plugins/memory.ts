import fp from "fastify-plugin";
import { validateMemoryBookReferences } from "../services/memory-service.js";

// Boot 时校验：npcs.json 里每个 NPC 配置的 skills id 都得在 i18n skill catalog
// (data/i18n/<locale>/skills.json) 里至少有 1 条 entry。实际把初始 memory 写进
// runtime_storage 则由 Godot agent-host client 在握手成功后触发。
export const memoryPlugin = fp(async (app) => {
  validateMemoryBookReferences();
  app.log.info("skill book references validated");
});
