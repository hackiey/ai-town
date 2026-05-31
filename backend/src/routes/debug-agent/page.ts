export const DEBUG_HTML = String.raw`<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8" />
<title>Agent Loop Debugger</title>
<link rel="stylesheet" href="/debug/assets/debug-agent.css" />
</head>
<body>
<div class="layout">
  <div class="topbar">
    <div class="view-tabs">
      <button id="tab-timeline" class="view-tab active" data-view="timeline">时间轴</button>
      <button id="tab-analytics" class="view-tab" data-view="analytics">工具分析</button>
    </div>
    <input id="filter-town" placeholder="townId..." style="width:140px" />
    <div class="npc-filter">
      <button id="npc-filter-btn" class="npc-filter-btn">角色: 全部</button>
      <div id="npc-filter-pop" class="npc-filter-pop"></div>
    </div>
    <div class="npc-filter">
      <button id="group-filter-btn" class="npc-filter-btn">Group: 全部</button>
      <div id="group-filter-pop" class="npc-filter-pop"></div>
    </div>
    <label>时间范围
      <select id="time-range">
        <option value="1h">最近 1 小时</option>
        <option value="6h" selected>最近 6 小时</option>
        <option value="24h">最近 24 小时</option>
        <option value="7d">最近 7 天</option>
        <option value="all">全部</option>
      </select>
    </label>
    <label>游戏日期
      <select id="game-day-filter">
        <option value="">全部</option>
      </select>
    </label>
    <label><input type="checkbox" id="auto-refresh" /> 5s 自动刷新</label>
    <div class="timeline-zoom" title="Ctrl/⌘ + 滚轮也可以缩放右侧时间轴">
      <span>时间轴缩放</span>
      <button id="timeline-zoom-out" type="button" aria-label="缩小时间轴">－</button>
      <input id="timeline-zoom" type="range" min="0" max="8" step="1" value="0" />
      <button id="timeline-zoom-in" type="button" aria-label="放大时间轴">＋</button>
      <button id="timeline-zoom-reset" type="button">适配</button>
      <span id="timeline-zoom-label" class="zoom-value">100%</span>
    </div>
    <span class="grow"></span>
    <span id="turns-info" class="meta" style="color:var(--muted);font-size:11px"></span>
    <button id="refresh-btn" title="Reload">↻</button>
    <button id="clear-all" class="danger" title="清空 agent_sessions / agent_session_messages / runtime_storage(memory:*)">🗑 清空所有</button>
  </div>

  <div id="view-timeline" class="view-pane active">
    <div id="timeline-wrap" class="timeline-wrap">
      <div class="timeline-empty">加载中…</div>
    </div>

    <section class="detail">
      <div id="detail-header" class="detail-header">
        <span class="title">未选择 turn</span>
      </div>
      <div id="detail-body" class="detail-body">
        <div class="empty">点击上方时间轴上的 turn 查看详情</div>
      </div>
    </section>
  </div>

  <div id="view-analytics" class="view-pane analytics-pane">
    <div class="analytics-toolbar">
      <label>分析时间范围
        <select id="analytics-time-range">
          <option value="all" selected>全部</option>
          <option value="1h">最近 1 小时</option>
          <option value="6h">最近 6 小时</option>
          <option value="24h">最近 24 小时</option>
          <option value="7d">最近 7 天</option>
        </select>
      </label>
      <label>时间桶
        <select id="analytics-bucket">
          <option value="hour" selected>游戏小时</option>
          <option value="day">游戏日</option>
        </select>
      </label>
      <label>排序
        <select id="analytics-tool-sort">
          <option value="total" selected>按总数</option>
          <option value="errorRate">按失败率</option>
          <option value="errorCount">按失败数</option>
        </select>
      </label>
      <span id="analytics-focus" class="analytics-focus" hidden>
        聚焦工具：<strong id="analytics-focus-name"></strong>
        <button id="analytics-focus-clear" type="button">取消</button>
      </span>
      <span class="grow"></span>
      <span id="analytics-meta" class="meta"></span>
      <button id="analytics-refresh" type="button">↻</button>
    </div>
    <div id="analytics-body" class="analytics-body">
      <div class="empty">点击「工具分析」标签加载…</div>
    </div>
  </div>
</div>
<div id="tt" class="tt"></div>
<script type="module" src="/debug/assets/main.js"></script>
</body>
</html>`;
