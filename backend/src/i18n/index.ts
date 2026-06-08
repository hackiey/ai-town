// 后端通用 i18n catalog loader：跟 Godot 端读同一份 data/i18n/<locale>/*.json。
// 具体 Agent 的 prompt 文案由 Agent 自己加载，不属于共享 catalog。
// 启动 lazy-load 全部 supported locale，构造扁平 dot-key map。
// 调用约定：t("ui.farm.title", "zh") / t("error.npc_not_nearby", session.locale, { name: "Oren Vale" })。
// fallback 链：locale → SOURCE_LOCALE → key 本身（暴露遗漏，方便发现没填的 key）。

import { readFileSync } from "node:fs";

export const SOURCE_LOCALE = "zh";
export const SUPPORTED_LOCALES = ["zh", "en"] as const;
export type Locale = (typeof SUPPORTED_LOCALES)[number];

const DOMAINS = [
  "ui", "items", "materials", "shapes", "verbs", "workstations", "containers", "reactions",
  "npcs", "locations", "skills", "groups", "attributes", "diseases", "symptoms",
  "tools", "errors",
  // Agent 共享的 prompt 渲染文案（section 标签、世界设定、距离/状态/动作 label 等）。
  // Per-agent 的策略文案（system prompt / persona / compaction）仍由 agent 自己加载。
  "prompts",
] as const;

type Catalog = Map<string, string>;

const catalogs = new Map<Locale, Catalog>();
let loaded = false;

export function isLocale(value: unknown): value is Locale {
  return typeof value === "string" && (SUPPORTED_LOCALES as readonly string[]).includes(value);
}

export function resolveLocale(value: unknown, fallback: Locale = SOURCE_LOCALE): Locale {
  return isLocale(value) ? value : fallback;
}

// Backend 进程级活动 locale。worker 和 app 都从同一个 env 取，保证统一。
// 设置 BACKEND_LOCALE=en 切英文。后续会被 per-session locale 取代。
let _activeLocale: Locale | undefined;
export function getActiveLocale(): Locale {
  if (_activeLocale) return _activeLocale;
  _activeLocale = resolveLocale(process.env.BACKEND_LOCALE);
  return _activeLocale;
}

export function t(key: string, locale: Locale, params?: Record<string, string | number>): string {
  ensureLoaded();
  const primary = catalogs.get(locale);
  let value = primary?.get(key);
  if (value === undefined && locale !== SOURCE_LOCALE) {
    value = catalogs.get(SOURCE_LOCALE)?.get(key);
  }
  if (value === undefined) {
    return key;
  }
  return params ? interpolate(value, params) : value;
}

export function has(key: string, locale: Locale): boolean {
  ensureLoaded();
  return catalogs.get(locale)?.has(key) ?? false;
}

export function reload(): void {
  loaded = false;
  catalogs.clear();
  ensureLoaded();
}

function ensureLoaded(): void {
  if (loaded) return;
  for (const locale of SUPPORTED_LOCALES) {
    catalogs.set(locale, loadLocale(locale));
  }
  loaded = true;
}

function loadLocale(locale: Locale): Catalog {
  const out: Catalog = new Map();
  for (const domain of DOMAINS) {
    const url = new URL(`../../../data/i18n/${locale}/${domain}.json`, import.meta.url);
    let raw: string;
    try {
      raw = readFileSync(url, "utf8");
    } catch {
      continue;
    }
    if (raw.trim().length === 0) continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch (err) {
      throw new Error(`[i18n] failed to parse ${url.pathname}: ${(err as Error).message}`);
    }
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error(`[i18n] ${url.pathname} must be a JSON object at the root`);
    }
    // 文件名仅作组织用；不参与 key——JSON 顶层自带 namespace
    flatten("", parsed as Record<string, unknown>, out);
  }
  return out;
}

function flatten(prefix: string, src: Record<string, unknown>, out: Catalog): void {
  for (const [k, v] of Object.entries(src)) {
    const key = prefix === "" ? k : `${prefix}.${k}`;
    if (v === null || v === undefined) continue;
    if (Array.isArray(v)) {
      v.forEach((item, idx) => {
        const idxKey = `${key}.${idx}`;
        if (item !== null && typeof item === "object" && !Array.isArray(item)) {
          flatten(idxKey, item as Record<string, unknown>, out);
        } else {
          out.set(idxKey, String(item));
        }
      });
    } else if (typeof v === "object") {
      flatten(key, v as Record<string, unknown>, out);
    } else {
      out.set(key, String(v));
    }
  }
}

function interpolate(template: string, params: Record<string, string | number>): string {
  return template.replace(/\{(\w+)\}/g, (_, name) => {
    const value = params[name];
    return value === undefined ? `{${name}}` : String(value);
  });
}
