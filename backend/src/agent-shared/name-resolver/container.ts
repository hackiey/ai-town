import { normalizeSlugKey } from "./alias-index.js";
import { createSimpleEntityResolver } from "./_simple-entity.js";
import { containerIds } from "./source-data.js";

const resolver = createSimpleEntityResolver({
  i18nNamespace: "container",
  loadIds: containerIds,
  normalize: normalizeSlugKey,
});

export const containerName = resolver.name;
export const containerNameAliases = resolver.aliases;
export const resolveContainerIdByName = resolver.resolveByName;
