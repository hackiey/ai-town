// tsc 只编译 .ts，不复制非 ts 资源。这个脚本把 src 下所有 prompts.json
// 镜像到 dist 对应位置——i18n loader 按 import.meta.url 解析路径，dist 跑时
// 必须有同位置的 json 才能找到翻译 key。
//
// 加新 .json 资源时（locales 之外的），扩展 PATTERNS。

import { copyFileSync, mkdirSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";

const ROOT = resolve(import.meta.dirname, "..");
const SRC = join(ROOT, "src");
const DIST = join(ROOT, "dist");

const PATTERNS = [/\/prompt\/locales\/[^/]+\/prompts\.json$/];

function walk(dir, cb) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, cb);
    else cb(p);
  }
}

let copied = 0;
walk(SRC, (p) => {
  const rel = relative(SRC, p);
  if (!PATTERNS.some((re) => re.test(p))) return;
  const dst = join(DIST, rel);
  mkdirSync(dirname(dst), { recursive: true });
  copyFileSync(p, dst);
  copied += 1;
});
console.log(`[copy-assets] copied ${copied} file(s) to dist/`);
