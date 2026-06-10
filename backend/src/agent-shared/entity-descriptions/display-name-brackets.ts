const DISPLAY_NAME_OPEN = "【";
const DISPLAY_NAME_CLOSE = "】";

export function bracketDisplayName(name: string): string {
  const trimmed = name.trim();
  if (!trimmed) return trimmed;
  if (trimmed.startsWith(DISPLAY_NAME_OPEN) && trimmed.endsWith(DISPLAY_NAME_CLOSE)) {
    return trimmed;
  }
  return `${DISPLAY_NAME_OPEN}${trimmed}${DISPLAY_NAME_CLOSE}`;
}

export function stripDisplayNameBrackets(name: string): string {
  const trimmed = name.trim();
  if (trimmed.startsWith(DISPLAY_NAME_OPEN) && trimmed.endsWith(DISPLAY_NAME_CLOSE)) {
    return trimmed.slice(DISPLAY_NAME_OPEN.length, -DISPLAY_NAME_CLOSE.length).trim();
  }
  return trimmed;
}
