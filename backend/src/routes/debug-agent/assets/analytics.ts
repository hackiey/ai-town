export const DEBUG_AGENT_ANALYTICS_MODULE = String.raw`
import { escapeHtml, formatRealTime } from "./shared.js";
import { formatGameDayLabel, formatGameTime } from "./time.js";

const TIME_PRESETS = {
  "1h": 3600e3,
  "6h": 6 * 3600e3,
  "24h": 24 * 3600e3,
  "7d": 7 * 24 * 3600e3,
};

export function createAnalyticsView(app) {
  const state = {
    data: null,
    loading: false,
    error: null,
    bucket: "hour",
    timeRange: "all",
    toolSort: "total",
    focusedTool: null,
    callStatus: "all",
    callCharacterId: "",
    callPage: 1,
    callPageSize: 50,
    callsData: null,
    callsLoading: false,
    callsError: null,
    callsRequestKey: "",
    lastRequestKey: "",
  };

  const $ = (id) => document.getElementById(id);

  function computeSince() {
    const ms = TIME_PRESETS[state.timeRange];
    if (!ms) return null;
    return new Date(Date.now() - ms).toISOString();
  }

  function buildBaseParams() {
    const params = new URLSearchParams();
    if (app.state.townFilter) params.set("townId", app.state.townFilter);
    if (app.state.selectedCharacterIds.size > 0) {
      params.set("characterIds", Array.from(app.state.selectedCharacterIds).join(","));
    }
    if (app.state.selectedGroupIds.size > 0) {
      params.set("groupIds", Array.from(app.state.selectedGroupIds).join(","));
    }
    const since = computeSince();
    if (since) params.set("since", since);
    return params;
  }

  function buildUrl() {
    const params = buildBaseParams();
    params.set("bucket", state.bucket);
    params.set("limit", "20000");
    return "/debug/api/tool-analytics?" + params.toString();
  }

  function buildCallsUrl() {
    const params = buildBaseParams();
    params.set("tool", state.focusedTool || "");
    params.set("status", state.callStatus);
    params.set("page", String(state.callPage));
    params.set("pageSize", String(state.callPageSize));
    if (state.callCharacterId) params.set("characterId", state.callCharacterId);
    return "/debug/api/tool-analytics/calls?" + params.toString();
  }

  function requestKey() {
    return [
      app.state.townFilter || "",
      Array.from(app.state.selectedCharacterIds).sort().join(","),
      Array.from(app.state.selectedGroupIds).sort().join(","),
      state.timeRange,
      state.bucket,
    ].join("|");
  }

  function callsRequestKey() {
    return [
      requestKey(),
      state.focusedTool || "",
      state.callStatus,
      state.callCharacterId,
      state.callPage,
      state.callPageSize,
    ].join("|");
  }

  async function load(options) {
    const force = !!(options && options.force);
    const key = requestKey();
    if (!force && key === state.lastRequestKey && state.data) {
      renderAll();
      return;
    }
    state.loading = true;
    state.error = null;
    renderAll();
    try {
      const data = await fetch(buildUrl()).then((response) => response.json());
      if (data.error) {
        state.error = String(data.error);
        state.data = null;
      } else {
        state.data = data;
        state.lastRequestKey = key;
      }
    } catch (error) {
      state.error = String(error && error.message ? error.message : error);
      state.data = null;
    } finally {
      state.loading = false;
      renderAll();
    }
    if (!state.error && state.focusedTool) {
      void loadCalls({ force: true });
    }
  }

  async function loadCalls(options) {
    if (!state.focusedTool) return;
    const force = !!(options && options.force);
    const key = callsRequestKey();
    if (!force && key === state.callsRequestKey && state.callsData) {
      renderAll();
      return;
    }
    state.callsLoading = true;
    state.callsError = null;
    renderAll();
    try {
      const data = await fetch(buildCallsUrl()).then((response) => response.json());
      if (key !== callsRequestKey()) return;
      if (data.error) {
        state.callsError = String(data.error);
        state.callsData = null;
      } else {
        state.callsData = data;
        state.callsRequestKey = key;
      }
    } catch (error) {
      if (key !== callsRequestKey()) return;
      state.callsError = String(error && error.message ? error.message : error);
      state.callsData = null;
    } finally {
      if (key === callsRequestKey()) {
        state.callsLoading = false;
        renderAll();
      }
    }
  }

  function pct(value) {
    if (!Number.isFinite(value)) return "—";
    return (value * 100).toFixed(1) + "%";
  }

  function fmtNum(value) {
    if (!Number.isFinite(value)) return "0";
    return new Intl.NumberFormat("en-US").format(value);
  }

  function renderAll() {
    renderToolbarMeta();
    renderFocusBadge();
    renderBody();
  }

  function renderToolbarMeta() {
    const meta = $("analytics-meta");
    if (!meta) return;
    if (state.loading) {
      meta.textContent = "加载中…";
      return;
    }
    if (state.error) {
      meta.textContent = "错误：" + state.error;
      return;
    }
    const data = state.data;
    if (!data) {
      meta.textContent = "";
      return;
    }
    const parts = [
      "样本 " + fmtNum(data.sampledRows) + " 条",
    ];
    if (data.truncated) parts.push("已截断");
    meta.textContent = parts.join(" · ");
  }

  function renderFocusBadge() {
    const wrap = $("analytics-focus");
    const name = $("analytics-focus-name");
    if (!wrap || !name) return;
    if (state.focusedTool) {
      wrap.hidden = false;
      name.textContent = state.focusedTool;
    } else {
      wrap.hidden = true;
      name.textContent = "";
    }
  }

  function renderBody() {
    const body = $("analytics-body");
    if (!body) return;
    if (state.loading && !state.data) {
      body.innerHTML = '<div class="empty">加载中…</div>';
      return;
    }
    if (state.error) {
      body.innerHTML = '<div class="empty error">加载失败：' + escapeHtml(state.error) + "</div>";
      return;
    }
    const data = state.data;
    if (!data) {
      body.innerHTML = '<div class="empty">点击刷新加载数据</div>';
      return;
    }
    if (data.sampledRows === 0) {
      body.innerHTML = '<div class="empty">当前 filter 范围内没有 toolResult</div>';
      return;
    }

    body.innerHTML = ""
      + renderKpis(data.totals)
      + renderToolTable(data.perTool)
      + renderSelectedToolCalls()
      + renderErrorList(data.perToolErrors)
      + renderCharacterTable(data.perCharacter)
      + renderTimeBuckets(data.timeBuckets, data.bucket);

    bindToolTableEvents();
    bindToolCallControls();
    bindCallRowEvents();
    bindErrorRowEvents();
  }

  function renderKpis(totals) {
    if (!totals) return "";
    const kpis = [
      { label: "总调用数", value: fmtNum(totals.totalCalls) },
      { label: "失败数", value: fmtNum(totals.totalErrors), cls: totals.totalErrors > 0 ? "kpi-error" : "" },
      { label: "失败率", value: pct(totals.errorRate), cls: totals.errorRate > 0.1 ? "kpi-error" : "" },
      { label: "涉及工具", value: fmtNum(totals.distinctTools) },
      { label: "涉及角色", value: fmtNum(totals.distinctCharacters) },
    ];
    return ''
      + '<section class="analytics-section">'
      + '<div class="kpi-row">'
      + kpis.map((k) => ''
        + '<div class="kpi-card ' + (k.cls || "") + '">'
        + '<div class="kpi-label">' + escapeHtml(k.label) + "</div>"
        + '<div class="kpi-value">' + escapeHtml(k.value) + "</div>"
        + "</div>"
      ).join("")
      + "</div>"
      + "</section>";
  }

  function renderToolTable(perTool) {
    if (!Array.isArray(perTool) || perTool.length === 0) return "";
    const sorted = perTool.slice().sort((a, b) => {
      if (state.toolSort === "errorRate") return b.errorRate - a.errorRate;
      if (state.toolSort === "errorCount") return b.errorCount - a.errorCount;
      return b.totalCount - a.totalCount;
    });
    const maxTotal = sorted.reduce((acc, row) => Math.max(acc, row.totalCount), 1);

    const rows = sorted.map((row) => {
      const succ = row.totalCount - row.errorCount;
      const totalWidth = (row.totalCount / maxTotal) * 100;
      const errPart = row.totalCount > 0 ? (row.errorCount / row.totalCount) * 100 : 0;
      const focused = state.focusedTool === row.name ? " focused" : "";
      return ''
        + '<tr class="analytics-tool-row' + focused + '" data-tool="' + escapeHtml(row.name) + '">'
        + '<td class="cell-name"><span class="tool-link">' + escapeHtml(row.name) + "</span></td>"
        + '<td class="cell-num">' + fmtNum(row.totalCount) + "</td>"
        + '<td class="cell-num">' + fmtNum(succ) + "</td>"
        + '<td class="cell-num ' + (row.errorCount > 0 ? "cell-error" : "") + '">' + fmtNum(row.errorCount) + "</td>"
        + '<td class="cell-num ' + (row.errorRate > 0.1 ? "cell-error" : "") + '">' + pct(row.errorRate) + "</td>"
        + '<td class="cell-bar">'
        + '<div class="bar-track" style="width:' + totalWidth.toFixed(1) + '%">'
        + '<div class="bar-fill-success" style="width:' + (100 - errPart).toFixed(1) + '%"></div>'
        + '<div class="bar-fill-error" style="width:' + errPart.toFixed(1) + '%"></div>'
        + "</div>"
        + "</td>"
        + '<td class="cell-num">' + fmtNum(row.uniqueCharacters) + "</td>"
        + "</tr>";
    }).join("");

    return ''
      + '<section class="analytics-section">'
      + '<h3>工具调用统计</h3>'
      + '<table class="analytics-table tool-table">'
      + '<thead><tr>'
      + '<th>工具</th><th class="cell-num">总数</th><th class="cell-num">成功</th>'
      + '<th class="cell-num">失败</th><th class="cell-num">失败率</th>'
      + '<th class="cell-bar">分布</th><th class="cell-num">角色数</th>'
      + "</tr></thead>"
      + "<tbody>" + rows + "</tbody>"
      + "</table>"
      + "</section>";
  }

  function renderSelectedToolCalls() {
    if (!state.focusedTool) return "";
    const data = state.callsData;
    const title = "调用明细（" + escapeHtml(state.focusedTool) + "）";
    let content = renderToolCallFilters(data);

    if (state.callsLoading && !data) {
      content += '<div class="empty">加载调用明细…</div>';
    } else if (state.callsError) {
      content += '<div class="empty error">加载失败：' + escapeHtml(state.callsError) + "</div>";
    } else if (!data) {
      content += '<div class="empty">选择工具后加载调用明细</div>';
    } else if (!Array.isArray(data.calls) || data.calls.length === 0) {
      content += '<div class="empty">当前筛选下没有调用记录</div>';
      content += renderToolCallPagination(data);
    } else {
      content += renderToolCallTable(data.calls);
      content += renderToolCallPagination(data);
    }

    return ''
      + '<section class="analytics-section analytics-call-section">'
      + '<h3>' + title + (state.callsLoading && data ? ' <span class="cell-id">刷新中…</span>' : "") + "</h3>"
      + content
      + "</section>";
  }

  function renderToolCallFilters(data) {
    const characters = Array.isArray(data && data.characters) ? data.characters : [];
    const characterOptions = ['<option value="">全部角色</option>'].concat(characters.map((row) => {
      const selected = row.characterId === state.callCharacterId ? " selected" : "";
      const label = (row.displayName || row.characterId)
        + (row.displayName && row.displayName !== row.characterId ? " (" + row.characterId + ")" : "")
        + " · " + fmtNum(row.totalCalls) + " 次"
        + (row.errorCalls > 0 ? " / 失败 " + fmtNum(row.errorCalls) : "");
      return '<option value="' + escapeHtml(row.characterId) + '"' + selected + ">" + escapeHtml(label) + "</option>";
    })).join("");

    return ''
      + '<div class="analytics-subtoolbar">'
      + '<label>是否失败 '
      + '<select id="analytics-call-status">'
      + '<option value="all"' + (state.callStatus === "all" ? " selected" : "") + ">全部</option>"
      + '<option value="failed"' + (state.callStatus === "failed" ? " selected" : "") + ">仅失败</option>"
      + '<option value="success"' + (state.callStatus === "success" ? " selected" : "") + ">仅成功</option>"
      + "</select></label>"
      + '<label>角色名 '
      + '<select id="analytics-call-character">' + characterOptions + "</select></label>"
      + '<label>每页 '
      + '<select id="analytics-call-page-size">'
      + pageSizeOption(25) + pageSizeOption(50) + pageSizeOption(100) + pageSizeOption(200)
      + "</select></label>"
      + '<span class="grow"></span>'
      + '<button id="analytics-calls-reload" type="button">刷新明细</button>'
      + "</div>";
  }

  function pageSizeOption(value) {
    return '<option value="' + value + '"' + (state.callPageSize === value ? " selected" : "") + ">" + value + "</option>";
  }

  function renderToolCallTable(calls) {
    const rows = calls.map((row) => {
      const statusClass = row.failed ? "cell-error" : "";
      const statusText = row.failed ? "失败" : "成功";
      const gameTime = row.gameTime ? formatGameTime(row.gameTime, { short: true }) : "—";
      const role = row.displayName || row.characterId;
      return ''
        + '<tr class="analytics-call-row' + (row.failed ? " failed" : "") + '" data-session="' + escapeHtml(row.sessionId) + '" data-seq="' + row.seq + '">'
        + '<td class="cell-time">' + escapeHtml(formatRealTime(row.createdAt)) + '<div class="cell-id">' + escapeHtml(gameTime) + "</div></td>"
        + '<td class="cell-name">' + escapeHtml(role)
        + (role !== row.characterId ? ' <span class="cell-id">(' + escapeHtml(row.characterId) + ")</span>" : "")
        + '<div class="cell-id">' + escapeHtml(row.townId) + "</div></td>"
        + '<td class="cell-num">#' + row.seq + "</td>"
        + '<td class="cell-name ' + statusClass + '">' + statusText + '<div class="cell-id">' + escapeHtml(row.status || "") + "</div></td>"
        + '<td class="cell-excerpt"><pre>' + escapeHtml(row.excerpt || "") + "</pre></td>"
        + '<td class="cell-action"><button type="button" class="call-jump">跳转</button></td>'
        + "</tr>";
    }).join("");

    return ''
      + '<table class="analytics-table call-table">'
      + '<thead><tr>'
      + '<th>时间</th><th>角色</th><th class="cell-num">Seq</th><th>结果</th><th>摘要</th><th></th>'
      + "</tr></thead>"
      + "<tbody>" + rows + "</tbody>"
      + "</table>";
  }

  function renderToolCallPagination(data) {
    if (!data) return "";
    const total = Number.isFinite(data.total) ? data.total : 0;
    const pageSize = Number.isFinite(data.pageSize) ? data.pageSize : state.callPageSize;
    const page = Number.isFinite(data.page) ? data.page : state.callPage;
    const totalPages = Math.max(1, Math.ceil(total / Math.max(1, pageSize)));
    const start = total === 0 ? 0 : ((page - 1) * pageSize) + 1;
    const end = total === 0 ? 0 : Math.min(total, start + (Array.isArray(data.calls) ? data.calls.length : 0) - 1);
    return ''
      + '<div class="analytics-pagination">'
      + '<span class="meta">' + escapeHtml(fmtNum(total)) + " 条 · " + escapeHtml(String(start)) + "-" + escapeHtml(String(end)) + " / 第 " + escapeHtml(String(page)) + " / " + escapeHtml(String(totalPages)) + " 页</span>"
      + '<button id="analytics-calls-prev" type="button"' + (data.hasPrev ? "" : " disabled") + ">上一页</button>"
      + '<button id="analytics-calls-next" type="button"' + (data.hasNext ? "" : " disabled") + ">下一页</button>"
      + "</div>";
  }

  function renderErrorList(perToolErrors) {
    if (!Array.isArray(perToolErrors) || perToolErrors.length === 0) {
      return ''
        + '<section class="analytics-section">'
        + '<h3>失败 Top</h3>'
        + '<div class="empty">没有失败记录</div>'
        + "</section>";
    }
    const filtered = state.focusedTool
      ? perToolErrors.filter((row) => row.toolName === state.focusedTool)
      : perToolErrors;
    if (filtered.length === 0) {
      return ''
        + '<section class="analytics-section">'
        + '<h3>失败 Top（' + escapeHtml(state.focusedTool || "") + '）</h3>'
        + '<div class="empty">该工具没有失败记录</div>'
        + "</section>";
    }

    const rows = filtered.map((row) => {
      return ''
        + '<tr class="analytics-error-row" data-session="' + escapeHtml(row.lastSessionId) + '" data-seq="' + row.lastSeq + '">'
        + '<td class="cell-name">' + escapeHtml(row.toolName) + "</td>"
        + '<td class="cell-num cell-error">' + fmtNum(row.count) + "</td>"
        + '<td class="cell-num">' + fmtNum(row.uniqueCharacters) + "</td>"
        + '<td class="cell-excerpt"><pre>' + escapeHtml(row.errorExcerpt) + "</pre></td>"
        + '<td class="cell-action"><button type="button" class="error-jump">跳转</button></td>'
        + "</tr>";
    }).join("");

    const title = state.focusedTool
      ? "失败 Top（" + escapeHtml(state.focusedTool) + "）"
      : "失败 Top";

    return ''
      + '<section class="analytics-section">'
      + '<h3>' + title + "</h3>"
      + '<table class="analytics-table error-table">'
      + '<thead><tr>'
      + '<th>工具</th><th class="cell-num">次数</th><th class="cell-num">角色数</th>'
      + '<th>错误摘要</th><th></th>'
      + "</tr></thead>"
      + "<tbody>" + rows + "</tbody>"
      + "</table>"
      + "</section>";
  }

  function renderCharacterTable(perCharacter) {
    if (!Array.isArray(perCharacter) || perCharacter.length === 0) return "";
    const filtered = perCharacter.filter((row) => row.errorCalls > 0 || !state.focusedTool);
    if (filtered.length === 0) {
      return ''
        + '<section class="analytics-section">'
        + '<h3>按角色看失败</h3>'
        + '<div class="empty">没有数据</div>'
        + "</section>";
    }
    const sorted = filtered.slice().sort((a, b) => {
      if (b.errorCalls !== a.errorCalls) return b.errorCalls - a.errorCalls;
      return b.totalCalls - a.totalCalls;
    });
    const rows = sorted.slice(0, 50).map((row) => ''
      + "<tr>"
      + '<td class="cell-name">' + escapeHtml(row.displayName || row.characterId)
      + (row.displayName && row.displayName !== row.characterId
        ? ' <span class="cell-id">(' + escapeHtml(row.characterId) + ")</span>"
        : "")
      + "</td>"
      + '<td class="cell-num">' + fmtNum(row.totalCalls) + "</td>"
      + '<td class="cell-num ' + (row.errorCalls > 0 ? "cell-error" : "") + '">' + fmtNum(row.errorCalls) + "</td>"
      + '<td class="cell-num ' + (row.errorRate > 0.1 ? "cell-error" : "") + '">' + pct(row.errorRate) + "</td>"
      + '<td class="cell-name">' + (row.topErrorTool ? escapeHtml(row.topErrorTool) + ' <span class="cell-id">×' + fmtNum(row.topErrorToolCount) + "</span>" : "—") + "</td>"
      + "</tr>"
    ).join("");

    return ''
      + '<section class="analytics-section">'
      + '<h3>按角色看失败' + (sorted.length > 50 ? "（前 50）" : "") + "</h3>"
      + '<table class="analytics-table character-table">'
      + '<thead><tr>'
      + '<th>角色</th><th class="cell-num">总调用</th><th class="cell-num">失败</th>'
      + '<th class="cell-num">失败率</th><th>主要失败工具</th>'
      + "</tr></thead>"
      + "<tbody>" + rows + "</tbody>"
      + "</table>"
      + "</section>";
  }

  function renderTimeBuckets(timeBuckets, bucketKind) {
    if (!Array.isArray(timeBuckets) || timeBuckets.length === 0) return "";
    const maxCount = timeBuckets.reduce((acc, row) => Math.max(acc, row.totalCalls), 1);
    const bars = timeBuckets.map((row) => {
      const label = bucketLabel(row, bucketKind);
      const heightPct = (row.totalCalls / maxCount) * 100;
      const errPart = row.totalCalls > 0 ? (row.errorCalls / row.totalCalls) * 100 : 0;
      const succPct = 100 - errPart;
      return ''
        + '<div class="time-bucket" title="' + escapeHtml(label + " · 总 " + row.totalCalls + " · 失败 " + row.errorCalls) + '">'
        + '<div class="time-bucket-bar" style="height:' + heightPct.toFixed(1) + '%">'
        + '<div class="time-bucket-error" style="height:' + errPart.toFixed(1) + '%"></div>'
        + '<div class="time-bucket-success" style="height:' + succPct.toFixed(1) + '%"></div>'
        + "</div>"
        + '<div class="time-bucket-label">' + escapeHtml(label) + "</div>"
        + "</div>";
    }).join("");

    return ''
      + '<section class="analytics-section">'
      + '<h3>时间分布（' + (bucketKind === "day" ? "按游戏日" : "按游戏小时") + "）</h3>"
      + '<div class="time-buckets">' + bars + "</div>"
      + '<div class="legend">'
      + '<span><span class="legend-swatch legend-success"></span>成功</span>'
      + '<span><span class="legend-swatch legend-error"></span>失败</span>'
      + "</div>"
      + "</section>";
  }

  function bucketLabel(row, bucketKind) {
    if (row.gameDay != null) {
      const dayLabel = formatGameDayLabel(row.gameDay);
      if (bucketKind === "day") return dayLabel;
      const hh = String(row.gameHour ?? 0).padStart(2, "0");
      return dayLabel + " " + hh + ":00";
    }
    if (row.isoStart) {
      try {
        const d = new Date(row.isoStart);
        const pad = (n) => String(n).padStart(2, "0");
        if (bucketKind === "day") {
          return pad(d.getMonth() + 1) + "/" + pad(d.getDate());
        }
        return pad(d.getMonth() + 1) + "/" + pad(d.getDate()) + " " + pad(d.getHours()) + ":00";
      } catch {
        return row.isoStart;
      }
    }
    return "—";
  }

  function bindToolTableEvents() {
    const body = $("analytics-body");
    if (!body) return;
    for (const row of body.querySelectorAll(".analytics-tool-row")) {
      row.addEventListener("click", () => {
        const tool = row.getAttribute("data-tool");
        state.focusedTool = state.focusedTool === tool ? null : tool;
        resetCallData();
        if (state.focusedTool) void loadCalls({ force: true });
        else renderAll();
      });
    }
  }

  function resetCallData() {
    state.callPage = 1;
    state.callCharacterId = "";
    state.callsData = null;
    state.callsError = null;
    state.callsLoading = false;
    state.callsRequestKey = "";
  }

  function bindToolCallControls() {
    if (!state.focusedTool) return;
    const status = $("analytics-call-status");
    if (status) status.addEventListener("change", (event) => {
      state.callStatus = event.target.value;
      state.callPage = 1;
      state.callCharacterId = "";
      state.callsData = null;
      void loadCalls({ force: true });
    });
    const character = $("analytics-call-character");
    if (character) character.addEventListener("change", (event) => {
      state.callCharacterId = event.target.value;
      state.callPage = 1;
      state.callsData = null;
      void loadCalls({ force: true });
    });
    const pageSize = $("analytics-call-page-size");
    if (pageSize) pageSize.addEventListener("change", (event) => {
      const next = Number(event.target.value);
      state.callPageSize = Number.isFinite(next) ? next : 50;
      state.callPage = 1;
      state.callsData = null;
      void loadCalls({ force: true });
    });
    const reload = $("analytics-calls-reload");
    if (reload) reload.addEventListener("click", () => { void loadCalls({ force: true }); });
    const prev = $("analytics-calls-prev");
    if (prev) prev.addEventListener("click", () => {
      if (state.callPage <= 1) return;
      state.callPage -= 1;
      void loadCalls({ force: true });
    });
    const next = $("analytics-calls-next");
    if (next) next.addEventListener("click", () => {
      state.callPage += 1;
      void loadCalls({ force: true });
    });
  }

  function bindCallRowEvents() {
    const body = $("analytics-body");
    if (!body) return;
    for (const button of body.querySelectorAll(".call-jump")) {
      button.addEventListener("click", (event) => {
        event.stopPropagation();
        const row = button.closest(".analytics-call-row");
        if (!row) return;
        const sessionId = row.getAttribute("data-session");
        if (!sessionId) return;
        const seqAttr = row.getAttribute("data-seq");
        const seq = seqAttr != null && seqAttr !== "" ? Number(seqAttr) : null;
        jumpToSessionMessage(sessionId, seq);
      });
    }
  }

  function bindErrorRowEvents() {
    const body = $("analytics-body");
    if (!body) return;
    for (const button of body.querySelectorAll(".error-jump")) {
      button.addEventListener("click", (event) => {
        event.stopPropagation();
        const row = button.closest(".analytics-error-row");
        if (!row) return;
        const sessionId = row.getAttribute("data-session");
        if (!sessionId) return;
        const seqAttr = row.getAttribute("data-seq");
        const seq = seqAttr != null && seqAttr !== "" ? Number(seqAttr) : null;
        jumpToSessionMessage(sessionId, seq);
      });
    }
  }

  function jumpToSessionMessage(sessionId, seq) {
    // 切回时间轴，pin 这条 session+seq，由 timeline 侧选中具体 turn 并滚到该消息
    const hashParams = new URLSearchParams(window.location.hash.replace(/^#/, ""));
    hashParams.set("session", sessionId);
    if (Number.isFinite(seq)) hashParams.set("seq", String(seq));
    else hashParams.delete("seq");
    window.history.replaceState(null, "", window.location.pathname + window.location.search + "#" + hashParams.toString());
    if (typeof options.onJumpToSession === "function") {
      options.onJumpToSession({ sessionId, seq: Number.isFinite(seq) ? seq : null });
    }
  }

  const options = { onJumpToSession: null };

  function bindControls() {
    const range = $("analytics-time-range");
    if (range) {
      range.value = state.timeRange;
      range.addEventListener("change", (event) => {
        state.timeRange = event.target.value;
        void load({ force: true });
      });
    }
    const bucket = $("analytics-bucket");
    if (bucket) {
      bucket.value = state.bucket;
      bucket.addEventListener("change", (event) => {
        state.bucket = event.target.value;
        void load({ force: true });
      });
    }
    const sort = $("analytics-tool-sort");
    if (sort) {
      sort.value = state.toolSort;
      sort.addEventListener("change", (event) => {
        state.toolSort = event.target.value;
        renderAll();
      });
    }
    const refresh = $("analytics-refresh");
    if (refresh) refresh.addEventListener("click", () => { void load({ force: true }); });
    const focusClear = $("analytics-focus-clear");
    if (focusClear) focusClear.addEventListener("click", () => {
      state.focusedTool = null;
      resetCallData();
      renderAll();
    });
  }

  bindControls();

  return {
    state,
    load,
    refresh: () => load({ force: true }),
    setJumpHandler: (fn) => { options.onJumpToSession = fn; },
  };
}
`;
