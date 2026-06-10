export const DEBUG_CHARACTER_HTML = String.raw`<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8" />
<title>Agent Debugger - Characters</title>
<link rel="stylesheet" href="/debug/assets/debug-agent.css" />
</head>
<body>
<div class="layout">
  <div class="topbar">
    <div class="view-tabs">
      <a class="view-tab" href="/debug">总时间轴</a>
      <button id="tab-timeline" class="view-tab active" data-view="timeline">角色三列</button>
    </div>
    <input id="filter-town" placeholder="townId..." style="width:140px" />
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
    <span class="grow"></span>
    <span id="turns-info" class="meta" style="color:var(--muted);font-size:11px"></span>
    <button id="refresh-btn" title="Reload">↻</button>
    <button id="clear-all" class="danger" title="清空 agent_sessions / agent_session_messages / runtime_storage(memory:*)">🗑 清空所有</button>
  </div>

  <div id="view-timeline" class="view-pane active character-debug-view">
    <div class="debug-columns">
      <aside class="character-pane">
        <div class="pane-header">
          <span class="title">角色列表</span>
          <span id="character-list-meta" class="meta"></span>
        </div>
        <div id="character-list" class="character-list">
          <div class="empty">加载中…</div>
        </div>
      </aside>

      <section class="timeline-pane">
        <div class="pane-header">
          <span class="title">时间轴</span>
          <span id="timeline-selected-meta" class="meta"></span>
        </div>
        <div id="timeline-wrap" class="timeline-wrap">
          <div class="timeline-empty">请选择左侧角色</div>
        </div>
      </section>

      <section class="detail detail-pane">
        <div id="detail-header" class="detail-header">
          <span class="title">未选择 session</span>
        </div>
        <div id="detail-body" class="detail-body">
          <div class="empty">选择左侧角色，再点击中间时间轴上的 turn 查看详情</div>
        </div>
      </section>
    </div>
  </div>
</div>
<div id="tt" class="tt"></div>
<script type="module" src="/debug/assets/main.js"></script>
</body>
</html>`;
