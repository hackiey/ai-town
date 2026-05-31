import { getActiveLocale, t } from "../../i18n/index.js";
import {
  buildTwoTrackAgentBaseSystemPrompt,
  buildTwoTrackAgentEffectiveSystemPrompt,
} from "../../runtimes/two-track-agent/prompt/index.js";

export function parseIntOr(value: string | undefined, fallback: number): number {
  if (!value) return fallback;
  const n = Number.parseInt(value, 10);
  return Number.isFinite(n) ? n : fallback;
}

export function makeCharacterLookupKey(townId: string, characterId: string): string {
  return `${townId}\u0000${characterId}`;
}

export function translateCatalogName(
  domain: "npc" | "group",
  id: string,
  locale = getActiveLocale(),
): string {
  const key = `${domain}.${id}.name`;
  const translated = t(key, locale);
  return translated === key ? id : translated;
}

export function buildBaseSystemPrompt(): string {
  return buildTwoTrackAgentBaseSystemPrompt();
}

export function buildEffectiveSystemPrompt(
  context: Parameters<typeof buildTwoTrackAgentEffectiveSystemPrompt>[0],
): string {
  return buildTwoTrackAgentEffectiveSystemPrompt(context);
}

function extractMessageText(message: Record<string, unknown> | null | undefined): string {
  if (!message) return "";
  const content = message.content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.map((part) => {
      if (typeof part === "string") return part;
      if (!part || typeof part !== "object") return "";
      const typedPart = part as Record<string, unknown>;
      if (typeof typedPart.text === "string") return typedPart.text;
      if (typeof typedPart.reasoning === "string") return typedPart.reasoning;
      if (typeof typedPart.thinking === "string") return typedPart.thinking;
      return "";
    }).filter(Boolean).join("\n");
  }
  if (content && typeof content === "object") {
    const typedContent = content as Record<string, unknown>;
    if (typeof typedContent.text === "string") return typedContent.text;
  }
  return "";
}

export function isInterruptContinuationMessage(
  message: Record<string, unknown> | null | undefined,
): boolean {
  const text = extractMessageText(message).trimStart();
  if (!text) return false;
  return text.startsWith(t("prompt.context.section.event_interrupt", getActiveLocale()));
}
