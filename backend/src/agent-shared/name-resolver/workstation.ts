import { normalizeSlugKey } from "./alias-index.js";
import { createSimpleEntityResolver } from "./_simple-entity.js";
import { workstationIds } from "./source-data.js";

const resolver = createSimpleEntityResolver({
  i18nNamespace: "workstation",
  loadIds: workstationIds,
  normalize: normalizeSlugKey,
});

export const workstationName = resolver.name;
export const workstationNameAliases = resolver.aliases;
export const resolveWorkstationIdByName = resolver.resolveByName;
