import { normalizeSlugKey } from "./alias-index.js";
import { createSimpleEntityResolver } from "./_simple-entity.js";
import { groupIds } from "./source-data.js";

const resolver = createSimpleEntityResolver({
  i18nNamespace: "group",
  loadIds: groupIds,
  normalize: normalizeSlugKey,
});

export const groupName = resolver.name;
export const groupNameAliases = resolver.aliases;
export const resolveGroupIdByName = resolver.resolveByName;
