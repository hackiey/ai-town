import type { FastifyInstance } from "fastify";
import { DEBUG_AGENT_ANALYTICS_MODULE } from "./assets/analytics.js";
import { DEBUG_AGENT_DETAIL_MODULE } from "./assets/detail.js";
import { DEBUG_AGENT_FILTERS_MODULE } from "./assets/filters.js";
import { DEBUG_AGENT_MAIN_MODULE } from "./assets/main.js";
import { DEBUG_AGENT_MESSAGE_RENDERERS_MODULE } from "./assets/message-renderers.js";
import { DEBUG_AGENT_PAGE_STYLE } from "./assets/style.js";
import { DEBUG_AGENT_SESSION_VIEW_MODULE } from "./assets/session-view.js";
import { DEBUG_AGENT_SHARED_MODULE } from "./assets/shared.js";
import { DEBUG_AGENT_TIME_MODULE } from "./assets/time.js";
import { DEBUG_AGENT_TIMELINE_MODULE } from "./assets/timeline.js";

interface DebugAgentAsset {
  body: string;
  contentType: string;
  path: string;
}

const DEBUG_AGENT_ASSETS: DebugAgentAsset[] = [
  {
    path: "/debug/assets/debug-agent.css",
    contentType: "text/css; charset=utf-8",
    body: DEBUG_AGENT_PAGE_STYLE,
  },
  {
    path: "/debug/assets/shared.js",
    contentType: "text/javascript; charset=utf-8",
    body: DEBUG_AGENT_SHARED_MODULE,
  },
  {
    path: "/debug/assets/time.js",
    contentType: "text/javascript; charset=utf-8",
    body: DEBUG_AGENT_TIME_MODULE,
  },
  {
    path: "/debug/assets/filters.js",
    contentType: "text/javascript; charset=utf-8",
    body: DEBUG_AGENT_FILTERS_MODULE,
  },
  {
    path: "/debug/assets/timeline.js",
    contentType: "text/javascript; charset=utf-8",
    body: DEBUG_AGENT_TIMELINE_MODULE,
  },
  {
    path: "/debug/assets/session-view.js",
    contentType: "text/javascript; charset=utf-8",
    body: DEBUG_AGENT_SESSION_VIEW_MODULE,
  },
  {
    path: "/debug/assets/detail.js",
    contentType: "text/javascript; charset=utf-8",
    body: DEBUG_AGENT_DETAIL_MODULE,
  },
  {
    path: "/debug/assets/main.js",
    contentType: "text/javascript; charset=utf-8",
    body: DEBUG_AGENT_MAIN_MODULE,
  },
  {
    path: "/debug/assets/message-renderers.js",
    contentType: "text/javascript; charset=utf-8",
    body: DEBUG_AGENT_MESSAGE_RENDERERS_MODULE,
  },
  {
    path: "/debug/assets/analytics.js",
    contentType: "text/javascript; charset=utf-8",
    body: DEBUG_AGENT_ANALYTICS_MODULE,
  },
];

export function registerDebugAgentAssetRoutes(app: FastifyInstance): void {
  for (const asset of DEBUG_AGENT_ASSETS) {
    app.get(asset.path, async (_request, reply) => {
      reply.header("cache-control", "no-store");
      reply.type(asset.contentType);
      return asset.body;
    });
  }
}
