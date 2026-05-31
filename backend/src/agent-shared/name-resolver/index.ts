// Agent-shared name resolver。所有 entity 类型的"字符串 ↔ id"翻译都从这里 import。
// 之前 catalog.ts 把这一切混在一起，重构后每个 entity 一个文件，对外有统一形态：
//   - <kind>Name(id, locale?) / <kind>NameAliases(id) / resolve<Kind>IdByName(value)
// 边界规则见 [[feedback_llm_id_name_boundary]] —— LLM 只看人类名字，路由层负责归一。

export {
  characterName,
  characterDisplayName,
  characterNameAliases,
  resolveCharacterIdByName,
} from "./character.js";
export {
  locationName,
  locationDescription,
  locationNameAliases,
  resolveLocationIdByName,
} from "./location.js";
export {
  workstationName,
  workstationNameAliases,
  resolveWorkstationIdByName,
} from "./workstation.js";
export {
  containerName,
  containerNameAliases,
  resolveContainerIdByName,
} from "./container.js";
export {
  materialName,
  materialNameAliases,
  resolveMaterialIdByName,
} from "./material.js";
export {
  itemName,
  itemNameAliases,
  resolveItemIdByName,
} from "./item.js";
export {
  characterAttributeName,
  characterAttributeNameAliases,
  resolveCharacterAttributeIdByName,
} from "./attribute.js";
export {
  groupName,
  groupNameAliases,
  resolveGroupIdByName,
} from "./group.js";
export {
  resolveNavigableSiteIdByName,
} from "./site.js";
export {
  localizeValue,
  localizeStringValue,
  localizeText,
} from "./localize.js";

// 用于 perception event handler / classifier 等"调用方手上的 string 不一定是合法 slug"的场景：
// 反查 character id 成功就归一，否则原样返回（如 player_xxx 这类不在 npcs.json 的 id）。
import { resolveCharacterIdByName } from "./character.js";
export function normalizeCharacterId(value: string): string {
  return resolveCharacterIdByName(value) ?? value;
}
