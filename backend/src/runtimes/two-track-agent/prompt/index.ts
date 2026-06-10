// Two-track agent prompt 边界。大部分都从 agent-shared re-export；
// 只有 per-agent 的 system prompt 编排器和 message 模板在本地。
//
// agent 内部代码继续用 `from "./prompt/index.js"`；移植时如果想直接绕过这层
// import shared 也可以，没强制约束。

export type * from "../../../agent-shared/prompt-context/types.js";
export { AgentContextBuilder as TwoTrackAgentContextBuilder } from "./context/builder.js";
export type {
  AgentContextBuilderOptions as TwoTrackAgentContextBuilderOptions,
  BuildAgentContextInput as BuildTwoTrackAgentContextInput,
} from "./context/builder.js";
export {
  characterAttributeName,
  characterAttributeNameAliases,
  characterName,
  characterNameAliases,
  containerName,
  containerNameAliases,
  itemName,
  itemNameAliases,
  localizeStringValue,
  localizeText,
  localizeValue,
  locationName,
  materialName,
  materialNameAliases,
  resolveCharacterIdByName,
  resolveCharacterAttributeIdByName,
  resolveContainerIdByName,
  resolveItemIdByName,
  resolveLocationIdByName,
  resolveMaterialIdByName,
  resolveNavigableSiteIdByName,
  resolveWorkstationIdByName,
  workstationNameAliases,
} from "../../../agent-shared/name-resolver/index.js";
export { assembleAgentContextFromManifest } from "../../../agent-shared/prompt-context/assemble-from-manifest.js";
export { isEventRelevantToCharacter } from "../../../agent-shared/prompt-context/events.js";
export {
  renderInteractiveSitesSection,
  renderNearbyEnvironmentSections,
} from "../../../agent-shared/prompt-context/sections.js";
export { renderEventGameTimeLabel } from "../../../agent-shared/event-descriptions/index.js";
export { renderEventSummary } from "./context/renderer.js";
export {
  buildAgentTimelineEntries,
  countUncompactedTimelineEntries,
  filterTimelineEntriesAtOrBeforeCursor,
  filterTimelineEntriesAfterCursor,
  latestTimelineCursor,
  renderAgentContext,
  renderAgentEventsContext,
  renderAgentTimelineEntries,
  renderAgentSystemContext,
  renderAgentTurnContext,
  UNSUMMARIZED_TIMELINE_TRIGGER_COUNT,
  type AgentTimelineEntry,
} from "./context/renderer.js";
export {
  formatGameDate,
  formatGameTime,
  gameTimeFromRecord,
  gameTimeSortValue,
  normalizeGameTime,
  pad2,
  type NormalizedGameTime,
} from "../../../agent-shared/prompt-context/time.js";
export {
  buildTwoTrackAgentBaseSystemPrompt,
  buildTwoTrackAgentEffectiveSystemPrompt,
  buildTwoTrackAgentMemoryPinnedUserMessage,
  buildTwoTrackAgentTurnSystemPrompt,
  renderTwoTrackAgentActionNoticeUserMessage,
  renderTwoTrackAgentTurnUserMessage,
} from "./messages.js";
