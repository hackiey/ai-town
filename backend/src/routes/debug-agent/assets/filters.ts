export const DEBUG_AGENT_FILTERS_MODULE = String.raw`
import { compareZhText, escapeHtml, formatCostUsd, formatGroupNames, formatTokenCount, getGroupSortKey } from "./shared.js";

export function renderTopbarInfo(app) {
  const totalTokens = app.state.characters.reduce((sum, character) => (
    Number.isFinite(character.totalTokens) ? sum + character.totalTokens : sum
  ), 0);
  const hasTokenStats = app.state.characters.some((character) => Number.isFinite(character.totalTokens));
  const totalCostUsd = app.state.characters.reduce((sum, character) => (
    Number.isFinite(character.totalCostUsd) ? sum + character.totalCostUsd : sum
  ), 0);
  const hasCostStats = app.state.characters.some((character) => Number.isFinite(character.totalCostUsd));
  const info = app.state.truncated
    ? app.state.turns.length + " turns（已截断）"
    : app.state.turns.length + " turns";
  const stats = [];
  if (hasTokenStats) stats.push(formatTokenCount(totalTokens));
  if (hasCostStats) stats.push(formatCostUsd(totalCostUsd));
  app.$("turns-info").textContent = stats.length > 0 ? info + " · " + stats.join(" · ") : info;
}

export function renderNpcFilterPop(app, handlers) {
  const pop = app.$("npc-filter-pop");
  const selectedGroupIds = app.state.selectedGroupIds;
  const characters = app.state.characters
    .filter((character) => {
      if (selectedGroupIds.size === 0) return true;
      const groups = Array.isArray(character.groups) ? character.groups : [];
      return groups.some((group) => selectedGroupIds.has(group.groupId));
    })
    .slice()
    .sort((a, b) => {
      const ak = getGroupSortKey(a.groups);
      const bk = getGroupSortKey(b.groups);
      if (ak && !bk) return -1;
      if (!ak && bk) return 1;
      const cmp = compareZhText(ak, bk);
      if (cmp !== 0) return cmp;
      return compareZhText(a.displayName || a.characterId, b.displayName || b.characterId);
    });
  const rowHtml = ""
    + '<div class="row">'
    + '<button data-action="all">全选</button>'
    + '<button data-action="none">清空</button>'
    + "</div>";

  if (characters.length === 0) {
    pop.innerHTML = rowHtml + '<div class="empty" style="padding:8px">没有角色</div>';
  } else {
    pop.innerHTML = rowHtml + characters.map((character) => {
      const checked = app.state.selectedCharacterIds.has(character.characterId) ? " checked" : "";
      const secondary = [
        character.characterId,
        character.turnCount > 0 ? character.turnCount + " turns" : null,
        Number.isFinite(character.totalTokens) ? formatTokenCount(character.totalTokens) : null,
        Number.isFinite(character.totalCostUsd) ? formatCostUsd(character.totalCostUsd) : null,
        formatGroupNames(character.groups),
        character.agentKind,
      ].filter(Boolean).join(" · ");
      return ""
        + '<label><input type="checkbox" value="' + escapeHtml(character.characterId) + '"' + checked + " />"
        + '<span class="filter-text">'
        + '<span class="primary">' + escapeHtml(character.displayName || character.characterId) + "</span>"
        + '<span class="secondary">' + escapeHtml(secondary) + "</span>"
        + "</span></label>";
    }).join("");
  }

  for (const checkbox of pop.querySelectorAll('input[type="checkbox"]')) {
    checkbox.addEventListener("change", (event) => {
      const id = event.target.value;
      if (event.target.checked) app.state.selectedCharacterIds.add(id);
      else app.state.selectedCharacterIds.delete(id);
      updateNpcFilterBtn(app);
      handlers.onChange();
    });
  }

  for (const button of pop.querySelectorAll("button[data-action]")) {
    button.addEventListener("click", (event) => {
      if (event.target.dataset.action === "all") {
        for (const character of characters) {
          app.state.selectedCharacterIds.add(character.characterId);
        }
      } else {
        app.state.selectedCharacterIds.clear();
      }
      renderNpcFilterPop(app, handlers);
      updateNpcFilterBtn(app);
      handlers.onChange();
    });
  }

  updateNpcFilterBtn(app);
}

function updateNpcFilterBtn(app) {
  const count = app.state.selectedCharacterIds.size;
  app.$("npc-filter-btn").textContent = count === 0 ? "角色: 全部" : "角色: " + count + " 选中";
}

export function renderGroupFilterPop(app, handlers) {
  const pop = app.$("group-filter-pop");
  const groups = app.state.groups.slice().sort((a, b) => compareZhText(
    a.displayName || a.groupId,
    b.displayName || b.groupId,
  ));
  const rowHtml = ""
    + '<div class="row">'
    + '<button data-action="all">全选</button>'
    + '<button data-action="none">清空</button>'
    + "</div>";

  if (groups.length === 0) {
    pop.innerHTML = rowHtml + '<div class="empty" style="padding:8px">没有 group</div>';
  } else {
    pop.innerHTML = rowHtml + groups.map((group) => {
      const checked = app.state.selectedGroupIds.has(group.groupId) ? " checked" : "";
      return ""
        + '<label><input type="checkbox" value="' + escapeHtml(group.groupId) + '"' + checked + " />"
        + '<span class="filter-text">'
        + '<span class="primary">' + escapeHtml(group.displayName || group.groupId) + "</span>"
        + '<span class="secondary">' + escapeHtml(group.groupId) + "</span>"
        + "</span></label>";
    }).join("");
  }

  for (const checkbox of pop.querySelectorAll('input[type="checkbox"]')) {
    checkbox.addEventListener("change", (event) => {
      const id = event.target.value;
      if (event.target.checked) app.state.selectedGroupIds.add(id);
      else app.state.selectedGroupIds.delete(id);
      updateGroupFilterBtn(app);
      handlers.onChange();
    });
  }

  for (const button of pop.querySelectorAll("button[data-action]")) {
    button.addEventListener("click", (event) => {
      if (event.target.dataset.action === "all") {
        for (const group of app.state.groups) {
          app.state.selectedGroupIds.add(group.groupId);
        }
      } else {
        app.state.selectedGroupIds.clear();
      }
      renderGroupFilterPop(app, handlers);
      updateGroupFilterBtn(app);
      handlers.onChange();
    });
  }

  updateGroupFilterBtn(app);
}

function updateGroupFilterBtn(app) {
  const count = app.state.selectedGroupIds.size;
  app.$("group-filter-btn").textContent = count === 0 ? "Group: 全部" : "Group: " + count + " 选中";
}
`;
