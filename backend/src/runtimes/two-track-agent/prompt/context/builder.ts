import type { AgentRuntimeContext } from "../../../../agent-host/runtime.js";
import type { WorldEventRecord } from "../../../../godot-link/protocol.js";
import { loadTwoTrackAgentPromptMemories } from "../../memory.js";
import type { AgentCurrentContext, GameAgentContext, WorkingMemorySnapshot } from "../../../../agent-shared/prompt-context/types.js";
import { isCharacterContextEvent, isEventRelevantToCharacter } from "../../../../agent-shared/prompt-context/events.js";
import { getDefaultWorldLore } from "../../../../agent-shared/entity-descriptions/lore.js";
import { gameTimeFromRecord, gameTimeSortValue, normalizeGameTime } from "../../../../agent-shared/prompt-context/time.js";

// Manifest+repo 路径：runtime 端 currentContextFromHost 把 AgentCurrentContext 算好后传入。
export type BuildAgentContextInput = {
  ctx: AgentRuntimeContext;
  current: AgentCurrentContext;
  pendingEvents?: WorldEventRecord[];
  // Action 轨 turn 入口注入；Thinking 轨自己写不读，留空。
  workingMemory?: WorkingMemorySnapshot;
  now?: Date;
};

export type AgentContextBuilderOptions = {
  worldLore?: string[];
  otherMemoryLimit?: number;
  relevantEventLimit?: number;
  recentEventWindowGameMinutes?: number;
  relevantEventWindowGameHours?: number;
};

const DEFAULT_RECENT_EVENT_WINDOW_GAME_MINUTES = 60;
const DEFAULT_RELEVANT_EVENT_WINDOW_GAME_HOURS = 8;

export class AgentContextBuilder {
  private readonly worldLore: string[];
  private readonly otherMemoryLimit: number;
  private readonly relevantEventLimit: number;
  private readonly recentEventWindowGameMinutes: number;
  private readonly relevantEventWindowGameHours: number;

  constructor(options: AgentContextBuilderOptions = {}) {
    this.worldLore = options.worldLore ?? getDefaultWorldLore();
    this.otherMemoryLimit = options.otherMemoryLimit ?? 20;
    this.relevantEventLimit = options.relevantEventLimit ?? 50;
    this.recentEventWindowGameMinutes = options.recentEventWindowGameMinutes ?? DEFAULT_RECENT_EVENT_WINDOW_GAME_MINUTES;
    this.relevantEventWindowGameHours = options.relevantEventWindowGameHours ?? DEFAULT_RELEVANT_EVENT_WINDOW_GAME_HOURS;
  }

  async build(input: BuildAgentContextInput): Promise<GameAgentContext> {
    const now = input.now ?? new Date();
    const ctx = input.ctx;

    const memory = await loadTwoTrackAgentPromptMemories(ctx.storage(), {
      otherLimit: this.otherMemoryLimit,
    });

    // wall-clock 预过滤：按 1× time_scale 折算，保证至少覆盖所需的游戏小时跨度；
    // 真正按游戏时间的精确过滤在下面用 currentGameMinutes 做。
    // recentEventRecords 由 host 注入 characterId，在 SQL 层就按角色相关过滤再 LIMIT，
    // 所以这里直接取 relevantEventLimit 条（都是本角色相关的），不再 ×2 预取兜全局截断。
    const rawRelevantEvents = await ctx.recentEventRecords({
      sinceMs: this.relevantEventWindowGameHours * 60 * 60 * 1000,
      limit: this.relevantEventLimit,
    });
    await ctx.characterGroups(); // i18n / group cache 预热；返回值已经在 input.current 反映过。
    // 本角色近期 action_log（带 result）——给事件渲染合并自身动作效果（item-3）。复用已有 host 方法。
    const selfActionResults = await ctx.actions().recentForCharacter(ctx.characterId, this.relevantEventLimit);
    const current = input.current;
    const currentGameTime = normalizeGameTime(current.gameTime);
    const currentGameMinutes = currentGameTime ? gameTimeSortValue(currentGameTime) : undefined;
    const historicalCutoffGameMinutes = currentGameMinutes != null
      ? currentGameMinutes - this.relevantEventWindowGameHours * 60
      : undefined;

    const relevantEvents = rawRelevantEvents
      .filter((event) => !isCharacterContextEvent(event) && isEventRelevantToCharacter(event, ctx.characterId))
      .filter((event) => {
        if (historicalCutoffGameMinutes == null) return true;
        const eventGameTime = normalizeGameTime(event.gameTime ?? gameTimeFromRecord(event.data));
        if (!eventGameTime) return true; // 没 gameTime 的事件按可见保留
        return gameTimeSortValue(eventGameTime) >= historicalCutoffGameMinutes;
      })
      .slice(0, this.relevantEventLimit);

    return {
      townId: ctx.townId,
      characterId: ctx.characterId,
      assembledAt: now.toISOString(),
      recentEventWindowMinutes: this.recentEventWindowGameMinutes,
      relevantEventWindowHours: this.relevantEventWindowGameHours,
      worldLore: this.worldLore,
      current,
      memory,
      relevantEvents,
      pendingEvents: input.pendingEvents ?? [],
      workingMemory: input.workingMemory,
      selfActionResults,
    };
  }
}
