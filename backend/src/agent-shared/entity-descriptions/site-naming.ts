// 共享：给可交互 site（workstation / farm / shelf / container）的 display 文本附加
// 招牌后缀「（X 铁匠铺）」。两个用途：
//   1. 渲染层（sections.ts）—— 把 ownerGroup 招牌挂到名字上，让 LLM 知道归属。
//   2. resolver 层（targets.ts）—— 把同一个 "{name}（{group}）" 字符串塞进 alias 列表，
//      LLM 把渲染文本完整 copy 回来时也能反查 ID。
// 单点定义避免两边各算各的，导致 LLM 看的文本和 resolver 认的形式不对齐。

import { getActiveLocale, type Locale } from "../../i18n/index.js";
import { groupName } from "../name-resolver/group.js";

export function ownerSuffixedSiteName(
  displayName: string,
  ownerGroup?: string,
  locale: Locale = getActiveLocale(),
): string {
  if (!ownerGroup) return displayName;
  const owner = groupName(ownerGroup, locale).trim();
  return owner ? `${displayName}（${owner}）` : displayName;
}
