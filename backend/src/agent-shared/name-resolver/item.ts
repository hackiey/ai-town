// Item 的 normalize 比其它 entity 更宽松：保留空格、不替换 dash，
// 因为物品名常有多词组合（"Iron Ore" / "Wheat Seed"）。

import { normalizeItemAliasKey } from "./alias-index.js";
import { createSimpleEntityResolver } from "./_simple-entity.js";
import { itemIds } from "./source-data.js";

const resolver = createSimpleEntityResolver({
  i18nNamespace: "item",
  loadIds: itemIds,
  normalize: normalizeItemAliasKey,
});

export const itemName = resolver.name;
export const itemNameAliases = resolver.aliases;
export const resolveItemIdByName = resolver.resolveByName;
