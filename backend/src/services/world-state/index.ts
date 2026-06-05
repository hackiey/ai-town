// World-state repository 层入口。所有 SQLite 读路径都从这里走，runtime/context 拼装层
// 只依赖这一个文件的 export，方便 P4-P7 切换 / 重构时收口。

export * from "./types.js";

export { getCharacterState, getCharacterPresences } from "./character-repo.js";
export { getProficiencyForCharacter } from "./proficiency-repo.js";
export { getInventoryForCharacter, getInventoryForContainer } from "./inventory-repo.js";
export { getFarmsByIds } from "./farm-repo.js";
export { getWorkstationsByIds } from "./workstation-repo.js";
export { getShelvesByIds } from "./shelf-repo.js";
export { getContainersByIds } from "./container-repo.js";
export { getLocationsByIds, getAllLocations } from "./location-repo.js";
export { getPendingTradesFor } from "./trade-repo.js";
export { getItemDefsByIds, type ItemDefView } from "./item-def-repo.js";
export { DisplayNameResolver } from "./name-resolver.js";
