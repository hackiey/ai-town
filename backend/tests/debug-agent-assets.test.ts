import assert from "node:assert/strict";
import test from "node:test";
import ts from "typescript";
import { DEBUG_AGENT_ANALYTICS_MODULE } from "../src/routes/debug-agent/assets/analytics.js";
import { DEBUG_AGENT_CHARACTER_TIMELINE_MODULE } from "../src/routes/debug-agent/assets/character-timeline.js";
import { DEBUG_AGENT_DETAIL_MODULE } from "../src/routes/debug-agent/assets/detail.js";
import { DEBUG_AGENT_FILTERS_MODULE } from "../src/routes/debug-agent/assets/filters.js";
import { DEBUG_AGENT_MAIN_MODULE } from "../src/routes/debug-agent/assets/main.js";
import { DEBUG_AGENT_MESSAGE_RENDERERS_MODULE } from "../src/routes/debug-agent/assets/message-renderers.js";
import { DEBUG_AGENT_SESSION_VIEW_MODULE } from "../src/routes/debug-agent/assets/session-view.js";
import { DEBUG_AGENT_SHARED_MODULE } from "../src/routes/debug-agent/assets/shared.js";
import { DEBUG_AGENT_TIME_MODULE } from "../src/routes/debug-agent/assets/time.js";
import { DEBUG_AGENT_TIMELINE_MODULE } from "../src/routes/debug-agent/assets/timeline.js";

test("debug agent frontend modules are parseable JavaScript", () => {
  const modules = [
    ["analytics", DEBUG_AGENT_ANALYTICS_MODULE],
    ["character-timeline", DEBUG_AGENT_CHARACTER_TIMELINE_MODULE],
    ["detail", DEBUG_AGENT_DETAIL_MODULE],
    ["filters", DEBUG_AGENT_FILTERS_MODULE],
    ["main", DEBUG_AGENT_MAIN_MODULE],
    ["message-renderers", DEBUG_AGENT_MESSAGE_RENDERERS_MODULE],
    ["session-view", DEBUG_AGENT_SESSION_VIEW_MODULE],
    ["shared", DEBUG_AGENT_SHARED_MODULE],
    ["time", DEBUG_AGENT_TIME_MODULE],
    ["timeline", DEBUG_AGENT_TIMELINE_MODULE],
  ] as const;

  for (const [name, code] of modules) {
    const result = ts.transpileModule(code, {
      compilerOptions: {
        allowJs: true,
        module: ts.ModuleKind.ESNext,
        target: ts.ScriptTarget.ES2022,
      },
      fileName: `${name}.js`,
      reportDiagnostics: true,
    });
    const diagnostics = (result.diagnostics ?? []).map((diagnostic) => (
      ts.flattenDiagnosticMessageText(diagnostic.messageText, "\n")
    ));
    assert.deepEqual(diagnostics, [], `${name}.js should parse`);
  }
});
