export const DEBUG_AGENT_TIME_MODULE = String.raw`
const GAME_DAYS_PER_YEAR = 360;
const GAME_HOURS_PER_DAY = 24;

export function formatGameTime(gameTime, options) {
  const normalized = normalizeGameTime(gameTime);
  if (!normalized) return "—";
  const pad = (n) => String(n).padStart(2, "0");

  if (options && options.short) {
    return "D" + normalized.dayOfYear + " " + pad(normalized.hour) + ":" + pad(normalized.minute);
  }
  return "Y" + normalized.year + " D" + normalized.dayOfYear + " " + pad(normalized.hour) + ":" + pad(normalized.minute);
}

export function formatGameDuration(startGameTime, endGameTime) {
  const start = gameTimeTotalMinutes(startGameTime);
  const end = gameTimeTotalMinutes(endGameTime);
  if (start == null || end == null) return "—";
  const deltaMinutes = Math.max(0, end - start);
  if (deltaMinutes < 1) return Math.round(deltaMinutes * 60) + " game-s";
  if (deltaMinutes < 60) return deltaMinutes.toFixed(1) + " game-min";
  const hours = Math.floor(deltaMinutes / 60);
  const minutes = Math.round(deltaMinutes % 60);
  return hours + "h " + minutes + "m";
}

export function gameDayIndex(gameTime) {
  const minutes = gameTimeTotalMinutes(gameTime);
  if (minutes == null) return null;
  return Math.floor(minutes / (GAME_HOURS_PER_DAY * 60));
}

export function formatGameDayLabel(dayIndex) {
  if (!Number.isFinite(dayIndex)) return "—";
  const totalDays = Math.floor(dayIndex);
  const year = Math.floor(totalDays / GAME_DAYS_PER_YEAR) + 1;
  const dayOfYear = ((totalDays % GAME_DAYS_PER_YEAR) + GAME_DAYS_PER_YEAR) % GAME_DAYS_PER_YEAR + 1;
  return "Y" + year + " D" + dayOfYear;
}

export function gameTimeTotalMinutes(gameTime) {
  if (!gameTime || typeof gameTime !== "object") return null;
  const direct = numberValue(gameTime.totalGameMinutes ?? gameTime.total_game_minutes);
  if (direct != null) return direct;

  const minute = numberValue(gameTime.minute ?? gameTime.gameMinute ?? gameTime.game_minute) ?? 0;
  const totalHours = numberValue(gameTime.totalGameHours ?? gameTime.total_game_hours);
  if (totalHours != null) return totalHours * 60 + minute;

  const hour = numberValue(gameTime.hour ?? gameTime.gameHour ?? gameTime.game_hour) ?? 0;
  const day = numberValue(gameTime.day ?? gameTime.gameDay ?? gameTime.game_day);
  if (day != null) return (((day * GAME_HOURS_PER_DAY) + hour) * 60) + minute;

  const year = numberValue(gameTime.year ?? gameTime.reignYear ?? gameTime.reign_year);
  const dayOfYear = numberValue(gameTime.dayOfYear ?? gameTime.day_of_year);
  if (year != null && dayOfYear != null) {
    const zeroBasedYear = year > 0 ? year - 1 : year;
    const zeroBasedDayOfYear = dayOfYear > 0 ? dayOfYear - 1 : dayOfYear;
    return ((((zeroBasedYear * GAME_DAYS_PER_YEAR) + zeroBasedDayOfYear) * GAME_HOURS_PER_DAY) + hour) * 60 + minute;
  }

  return null;
}

export function formatDuration(ms) {
  if (ms < 1000) return ms + " ms";
  if (ms < 60000) return (ms / 1000).toFixed(2) + " s";
  const minutes = Math.floor(ms / 60000);
  const seconds = Math.floor((ms % 60000) / 1000);
  return minutes + "m " + seconds + "s";
}

export function computeGameTimeTicks(minGameMinutes, maxGameMinutes, target) {
  const span = maxGameMinutes - minGameMinutes;
  const rough = span / Math.max(1, target);
  const candidates = [
    1, 5, 15, 30,
    60, 2 * 60, 4 * 60, 6 * 60, 12 * 60,
    24 * 60, 2 * 24 * 60, 7 * 24 * 60,
  ];
  let step = candidates[candidates.length - 1];
  for (const candidate of candidates) {
    if (candidate >= rough) {
      step = candidate;
      break;
    }
  }

  const first = Math.ceil(minGameMinutes / step) * step;
  const ticks = [];
  for (let gameMinutes = first; gameMinutes <= maxGameMinutes; gameMinutes += step) {
    ticks.push({ gameMinutes, label: gameTickLabel(gameMinutes, step) });
  }
  return ticks;
}

export function computeRealTimeTicks(minRealMs, maxRealMs, target) {
  return computeTimeTicks(minRealMs, maxRealMs, target).map((ms) => ({
    realMs: ms,
    label: formatTickShort(ms),
  }));
}

function normalizeGameTime(gameTime) {
  if (!gameTime || typeof gameTime !== "object") return null;
  const totalMinutes = gameTimeTotalMinutes(gameTime);
  if (totalMinutes == null) return null;

  const minuteTotal = Math.floor(totalMinutes);
  const minute = numberValue(gameTime.minute ?? gameTime.gameMinute ?? gameTime.game_minute)
    ?? (((minuteTotal % 60) + 60) % 60);
  const totalHours = Math.floor(minuteTotal / 60);
  const hour = numberValue(gameTime.hour ?? gameTime.gameHour ?? gameTime.game_hour)
    ?? (((totalHours % GAME_HOURS_PER_DAY) + GAME_HOURS_PER_DAY) % GAME_HOURS_PER_DAY);
  const totalDays = Math.floor(totalHours / GAME_HOURS_PER_DAY);
  const year = numberValue(gameTime.year ?? gameTime.reignYear ?? gameTime.reign_year)
    ?? Math.floor(totalDays / GAME_DAYS_PER_YEAR) + 1;
  const dayOfYear = numberValue(gameTime.dayOfYear ?? gameTime.day_of_year)
    ?? (((totalDays % GAME_DAYS_PER_YEAR) + GAME_DAYS_PER_YEAR) % GAME_DAYS_PER_YEAR + 1);

  return {
    totalMinutes,
    year: Math.floor(year),
    dayOfYear: Math.floor(dayOfYear),
    hour: Math.floor(hour),
    minute: Math.floor(minute),
  };
}

function gameTickLabel(gameMinutes, stepMinutes) {
  const minuteTotal = Math.floor(gameMinutes);
  const minute = ((minuteTotal % 60) + 60) % 60;
  const totalHours = Math.floor(minuteTotal / 60);
  const hour = ((totalHours % GAME_HOURS_PER_DAY) + GAME_HOURS_PER_DAY) % GAME_HOURS_PER_DAY;
  const totalDays = Math.floor(totalHours / GAME_HOURS_PER_DAY);
  const year = Math.floor(totalDays / GAME_DAYS_PER_YEAR) + 1;
  const dayOfYear = ((totalDays % GAME_DAYS_PER_YEAR) + GAME_DAYS_PER_YEAR) % GAME_DAYS_PER_YEAR + 1;
  const pad = (n) => String(n).padStart(2, "0");
  if (stepMinutes >= 24 * 60) return "Y" + year + " D" + dayOfYear;
  if (stepMinutes >= 60) return "D" + dayOfYear + " " + pad(hour) + ":00";
  return "D" + dayOfYear + " " + pad(hour) + ":" + pad(minute);
}

function computeTimeTicks(minT, maxT, target) {
  const span = maxT - minT;
  const rough = span / Math.max(1, target);
  const candidates = [
    1000, 5000, 15000, 30000,
    60000, 5 * 60000, 15 * 60000, 30 * 60000,
    3600000, 6 * 3600000, 12 * 3600000,
    24 * 3600000, 7 * 24 * 3600000,
  ];
  let step = candidates[candidates.length - 1];
  for (const candidate of candidates) {
    if (candidate >= rough) {
      step = candidate;
      break;
    }
  }
  const first = Math.ceil(minT / step) * step;
  const ticks = [];
  for (let value = first; value <= maxT; value += step) ticks.push(value);
  return ticks;
}

function formatTickShort(ms) {
  const d = new Date(ms);
  const pad = (n) => String(n).padStart(2, "0");
  return pad(d.getMonth() + 1) + "/" + pad(d.getDate()) + " "
    + pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds());
}

function numberValue(value) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const n = Number(value);
    if (Number.isFinite(n)) return n;
  }
  return null;
}
`;
