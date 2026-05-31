// Character attribute（饱食度/体力等）。normalize 比 slug 更宽松——
// "饱食度" / "satiation" / "satiation_level" 都要能命中。

import { normalizeAttributeAliasKey } from "./alias-index.js";
import { createSimpleEntityResolver } from "./_simple-entity.js";
import { attributeIds } from "./source-data.js";

const resolver = createSimpleEntityResolver({
  i18nNamespace: "attribute",
  loadIds: attributeIds,
  normalize: normalizeAttributeAliasKey,
});

const baseName = resolver.name;

export function characterAttributeName(idOrName: string, locale?: Parameters<typeof baseName>[1]): string {
  // 比其它 entity 多一步：吃 id 也吃 name；先用 resolver 反查 id，再走 name 渲染。
  const id = resolver.resolveByName(idOrName) ?? idOrName;
  return baseName(id, locale);
}

export const characterAttributeNameAliases = resolver.aliases;
export const resolveCharacterAttributeIdByName = resolver.resolveByName;
