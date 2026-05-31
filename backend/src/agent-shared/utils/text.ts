// 文本工具：对 LLM 的输出/上下文做截断标记，避免硬塞超长字符串。
// 截断标记从 i18n error.truncated_marker 取，符合多语言原则。

import { getActiveLocale, t } from "../../i18n/index.js";

export function trimText(text: string, maxChars: number): string {
  if (text.length <= maxChars) {
    return text;
  }
  return `${text.slice(0, maxChars).trimEnd()}\n${t("error.truncated_marker", getActiveLocale())}`;
}
