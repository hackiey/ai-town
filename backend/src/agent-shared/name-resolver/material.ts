import { normalizeSlugKey } from "./alias-index.js";
import { createSimpleEntityResolver } from "./_simple-entity.js";
import { materialIds } from "./source-data.js";

const resolver = createSimpleEntityResolver({
  i18nNamespace: "material",
  loadIds: materialIds,
  normalize: normalizeSlugKey,
});

export const materialName = resolver.name;
export const materialNameAliases = resolver.aliases;
export const resolveMaterialIdByName = resolver.resolveByName;
