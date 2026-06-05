// 共享：给可交互 site（workstation / farm / shelf / container）的 display 文本附加
// 招牌后缀「（X 铁匠铺）」。两个用途：
//   1. 渲染层（sections.ts）—— 把 ownerGroup 招牌挂到名字上，让 LLM 知道归属。
//   2. resolver 层（targets.ts）—— 把同一个 "{name}（{group}）" 字符串塞进 alias 列表，
//      LLM 把渲染文本完整 copy 回来时也能反查 ID。
// 单点定义避免两边各算各的，导致 LLM 看的文本和 resolver 认的形式不对齐。

import { getActiveLocale, type Locale } from "../../i18n/index.js";
import { groupName } from "../name-resolver/group.js";
import type { InteractiveSiteContext } from "../prompt-context/types.js";

export function ownerSuffixedSiteName(
  displayName: string,
  ownerGroup?: string,
  locale: Locale = getActiveLocale(),
): string {
  if (!ownerGroup) return displayName;
  const owner = groupName(ownerGroup, locale).trim();
  return owner ? `${displayName}（${owner}）` : displayName;
}

// 交互 site（workstation / container / farm / shelf）面向 LLM 的**唯一**显示名来源。
// 渲染层（sections.ts）和解析层（targets.ts resolveInteractiveSite）都调它 —— LLM 看到的
// 字符串与 resolver 反查的 alias 由同一函数产出，杜绝"渲染加了后缀但 resolver 不认"这类
// 反复出现的漂移 bug。见 [[feedback_display_format_and_resolver_aliases]]。
export function renderInteractiveSiteName(
  site: Pick<InteractiveSiteContext, "displayName" | "ownerGroup">,
  locale: Locale = getActiveLocale(),
): string {
  return ownerSuffixedSiteName(site.displayName, site.ownerGroup, locale);
}
