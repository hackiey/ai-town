export const DEBUG_AGENT_ANALYTICS_MODULE = String.raw`
import { escapeHtml } from "./shared.js";
import { formatGameDayLabel } from "./time.js";

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
    lastRequestKey: "",
  };

  const $ = (id) => document.getElementById(id);

  function computeSince() {
    const ms = TIME_PRESETS[state.timeRange];
    if (!ms) return null;
    return new Date(Date.now() - ms).toISOString();
  }

  function buildUrl() {
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
    params.set("bucket", state.bucket);
    params.set("limit", "20000");
    return "/debug/api/tool-analytics?" + params.toString();
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
      + renderErrorList(data.perToolErrors)
      + renderCharacterTable(data.perCharacter)
      + renderTimeBuckets(data.timeBuckets, data.bucket);

    bindToolTableEvents();
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
        renderAll();
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
        // 切回时间轴，pin 这条 session+seq，由 timeline 侧选中具体 turn 并滚到该消息
        const hashParams = new URLSearchParams(window.location.hash.replace(/^#/, ""));
        hashParams.set("session", sessionId);
        if (Number.isFinite(seq)) hashParams.set("seq", String(seq));
        else hashParams.delete("seq");
        window.history.replaceState(null, "", window.location.pathname + window.location.search + "#" + hashParams.toString());
        if (typeof options.onJumpToSession === "function") {
          options.onJumpToSession({ sessionId, seq: Number.isFinite(seq) ? seq : null });
        }
      });
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
