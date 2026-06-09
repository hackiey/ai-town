// 玩家显示名 cache —— 真值就一处：Godot 写的 player_accounts(characterId, name) 表
// （src/autoload/db.gd）。本 cache 是同步 resolver（characterDisplayName 等）能用的内存
// 镜像，由 syncPlayerNameCacheFromDb 在 prompt 装配前刷一次。
//
// 设计点：
// - **不**接收 character.register 消息：登录写 player_accounts 已是真值，没必要再镜一份。
// - **不**单独维护 displayName/kind/aliases：玩家就一个名字，alias index 直接拿名字。
// - 找不到时 resolver 走 `|| id` fallback；本 cache 不抛——交给上层决定 fail-loud 与否。
//
// 删了什么（结构性合并）：
// - runtime_characters 表 + runtime-character-registry.ts 模块（仅给玩家做镜像，多余）
// - character.register / character.unregister 消息（玩家名真值已在 player_accounts）
// - Godot 端 _peer_to_display_name / _send_character_register / _player_display_name 镜像

import type { AppDb } from "../../db/sqlite.js";

const cache = new Map<string, string>();

export function getPlayerName(characterId: string): string | undefined {
  return cache.get(characterId.trim());
}

export function allPlayerNames(): Array<{ characterId: string; displayName: string }> {
  return Array.from(cache.entries()).map(([characterId, displayName]) => ({ characterId, displayName }));
}

// 由 assembleAgentContextFromManifest 在每次渲染前调一次，把整张 player_accounts 刷进 cache。
// player_accounts 由 Godot Db autoload 建表（[[feedback_backend_not_game_db_owner]]），
// backend 只读不写。townId 必传——多 town 部署时不能跨 town 串名字。
export function syncPlayerNameCacheFromDb(db: AppDb, townId: string): void {
  const rows = db
    .prepare(`SELECT characterId, name FROM player_accounts WHERE townId = ?`)
    .all(townId) as Array<{ characterId: string; name: string }>;
  cache.clear();
  for (const row of rows) {
    if (!row.characterId || !row.name) continue;
    cache.set(row.characterId, row.name);
  }
}

export function clearPlayerNameCache(): void {
  cache.clear();
}
