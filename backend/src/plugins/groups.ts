import fp from "fastify-plugin";
import { validateGroupDefinitions } from "../services/group-seed.js";

// Boot 时校验 npcs.json：每个 NPC 的 groups[] 引用的 group id 必须在 i18n catalog
// (data/i18n/<locale>/groups.json) 里有 display name 注册，否则 throw 打断 boot。
// 实际成员种子由 Godot Db autoload 完成（src/autoload/db.gd::_ensure_groups_seeded），backend 不写。
// 资源归属（location / farm / workstation）真值在 Godot 场景树，不经此校验。
export const groupsPlugin = fp(async (app) => {
  validateGroupDefinitions();
  app.log.info("npcs.json group membership validated");
});
