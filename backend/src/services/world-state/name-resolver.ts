import {
  characterName,
  containerName,
  groupName,
  itemName,
  locationName,
  materialName,
  workstationName,
} from "../../agent-shared/name-resolver/index.js";

// 统一的"id → 中文显示名"解析器。每个 entity kind 走对应 i18n catalog
// (data/i18n/<locale>/<kind>.json)。kind 之间互不串话，杜绝命名空间撞车
// （workstation slug 撞 location slug 之类的历史 bug）。
//
// **不读 sqlite**：display name 的 source-of-truth 永远是 i18n catalog；
// Godot 不再把名字 roundtrip 进 sqlite。所以 resolver 不需要 db/townId 也能解析。
// 如果将来要支持"per-instance 自定义显示名"（玩家命名物品、动态招牌等），
// 应该单独走一张 override 表 + 显式方法（withOverride），不要再把所有名字混进
// state 表的 displayName 字段。
//
// API：调用方在知道 kind 时**必须**调 typed 方法（.location / .workstation / ...），
// 让 grep 能查"谁在解析 workstation 名字"；只有真不知道 kind 的入口（tool input/output
// 翻译、自由文本替换）才调 .any()。
export class DisplayNameResolver {
  location(id: string | undefined | null): string {
    return resolveCatalog(id, locationName);
  }

  workstation(id: string | undefined | null): string {
    return resolveCatalog(id, workstationName);
  }

  container(id: string | undefined | null): string {
    return resolveCatalog(id, containerName);
  }

  item(id: string | undefined | null): string {
    return resolveCatalog(id, itemName);
  }

  character(id: string | undefined | null): string {
    return resolveCatalog(id, characterName);
  }

  material(id: string | undefined | null): string {
    return resolveCatalog(id, materialName);
  }

  group(id: string | undefined | null): string {
    return resolveCatalog(id, groupName);
  }

  // 未知 kind 的兜底翻译——仅供 unstructured tool input/output 用。
  // 调用方知道 kind 时**不要**用这个，请用 typed 方法。
  // 顺序需与 agent-shared/name-resolver/localize.ts localizeStringValue 一致。
  any(id: string | undefined | null): string {
    if (!id) return "";
    const candidates = [
      this.location(id),
      this.workstation(id),
      this.container(id),
      this.item(id),
      this.material(id),
      this.character(id),
    ];
    for (const cand of candidates) {
      if (cand && cand !== id) return cand;
    }
    return id;
  }
}

function resolveCatalog(id: string | undefined | null, lookup: (id: string) => string): string {
  if (!id) return "";
  const name = lookup(id);
  return name && name !== id ? name : id;
}
