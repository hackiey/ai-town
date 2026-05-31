// 工作台显示名：优先用 context 里给的 displayName，再 fallback 到 locationName(id)，
// 再 fallback 到 "第N个工作台" 的默认编号。

import { getActiveLocale, t } from "../../i18n/index.js";
import { locationName } from "../name-resolver/location.js";
import type { WorkstationContext } from "../prompt-context/types.js";

export function workstationDisplayName(workstation: WorkstationContext, index: number): string {
  const display = workstation.displayName?.trim() || locationName(workstation.id);
  return display && display !== workstation.id
    ? display
    : t("prompt.context.workstation.name_default_format", getActiveLocale(), { n: index + 1 });
}
