// 把任意值里的内部 slug 翻译成显示名。给 LLM 看的字段（tool result / action notice）
// 经过这一层后，看不到内部 slug，全是中文/英文名字。
//
// 语义：
//   - localizeStringValue(s): 把"看起来是个 slug"的字符串尝试解析成 displayName；解析不到原样返回
//   - localizeValue(v): deep walk 数组/对象，对所有字符串走 localizeStringValue
//   - localizeText(t): 在自由文本里 find-and-replace 已知的所有 slug/alias → displayName

import { objectValue } from "../utils/primitives.js";
import { characterDisplayName } from "./character.js";
import { characterDescriptors } from "./source-data.js";
import { containerName } from "./container.js";
import { containerNameAliases } from "./container.js";
import { itemName, itemNameAliases } from "./item.js";
import { locationDescriptors } from "./source-data.js";
import { locationName } from "./location.js";
import { materialName, materialNameAliases } from "./material.js";
import { workstationName } from "./workstation.js";
import { containerIds, itemIds, materialIds } from "./source-data.js";

export function localizeValue(value: unknown): unknown {
  if (typeof value === "string") {
    return localizeStringValue(value);
  }
  if (Array.isArray(value)) {
    return value.map(localizeValue);
  }
  const record = objectValue(value);
  if (!record) return value;
  return Object.fromEntries(Object.entries(record).map(([key, entry]) => [key, localizeValue(entry)]));
}

// "调用方手里只有 string，不知道是哪 kind 的 slug" 的兜底翻译。仅 catalog（无 sqlite 真值
// 上下文），sqlite-aware 路径请用 services/world-state/name-resolver.ts 的
// DisplayNameResolver.any()。两者尝试顺序需保持一致：
//   location → workstation → container → item → material → character
// 任一命中（返回值 !== 入参）即返回。
export function localizeStringValue(value: string): string {
  const lookups: Array<(id: string) => string> = [
    locationName,
    workstationName,
    containerName,
    itemName,
    materialName,
    characterDisplayName,
  ];
  for (const lookup of lookups) {
    const name = lookup(value);
    if (name && name !== value) return name;
  }
  return value;
}

export function localizeText(text: string): string {
  let out = text;
  // First names are deliberately NOT auto-aliased — when two characters share a
  // first name (e.g. Edda Hale + Edda Vance) the iteration order would silently
  // promote whichever appeared first in characterDescriptors() and overwrite
  // the other, producing hybrid renders like "艾达·黑尔 Vance". If a short form
  // genuinely needs to resolve to a slug, list it in descriptor.aliases.
  for (const [id, descriptor] of Object.entries(characterDescriptors())) {
    const displayName = characterDisplayName(id);
    out = replaceToken(out, id, displayName);
    if (descriptor.name) {
      out = replaceToken(out, descriptor.name, displayName);
    }
    for (const alias of descriptor.aliases ?? []) {
      out = replaceToken(out, alias, displayName);
    }
  }
  for (const id of Object.keys(locationDescriptors())) {
    out = replaceToken(out, id, locationName(id));
  }
  for (const id of itemIds()) {
    const displayName = itemName(id);
    out = replaceToken(out, id, displayName);
    for (const alias of itemNameAliases(id)) {
      out = replaceToken(out, alias, displayName);
    }
  }
  for (const id of containerIds()) {
    const displayName = containerName(id);
    out = replaceToken(out, id, displayName);
    for (const alias of containerNameAliases(id)) {
      out = replaceToken(out, alias, displayName);
    }
  }
  for (const id of materialIds()) {
    const displayName = materialName(id);
    out = replaceToken(out, id, displayName);
    for (const alias of materialNameAliases(id)) {
      out = replaceToken(out, alias, displayName);
    }
  }
  return out;
}

function replaceToken(input: string, token: string, replacement: string): string {
  if (!token || token === replacement || !input.includes(token)) {
    return input;
  }
  const escaped = escapeRegExp(token);
  if (/^[A-Za-z0-9_ -]+$/.test(token)) {
    return input.replace(new RegExp(`(^|[^A-Za-z0-9_])${escaped}(?=$|[^A-Za-z0-9_])`, "g"), `$1${replacement}`);
  }
  return input.replaceAll(token, replacement);
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
