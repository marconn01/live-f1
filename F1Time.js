.pragma library

// ---------------------------------------------------------------------------
// The plugin's single timezone/date layer.
//
// Rule, enforced by having exactly one of these files: an F1 session is an
// ABSOLUTE instant, carried everywhere as epoch milliseconds (UTC). Nothing
// downstream — panel, bar pill, countdown, notification, live timing — ever
// stores or compares a formatted string. Conversion to wall-clock happens
// once, here, at the moment of display.
//
// Wall-clock conversion uses this laptop's own zone, never UTC, never the
// API's zone, never the circuit's zone. Two mechanisms combine:
//
//   1. JavaScript `Date` getters, which apply the C library's local rules
//      and therefore get DST transitions right for free.
//   2. `correctionMs`, supplied by TimeService.qml. The QML engine resolves
//      the system zone once and caches it, so if the laptop's zone changes
//      while the shell is running (travel, `timedatectl set-timezone`), the
//      engine keeps formatting in the old zone. TimeService compares the
//      engine's current offset against the offset the OS reports and hands
//      the difference here; adding it to the instant before reading the
//      Date getters lands the printed wall clock back on OS truth.
//
// Every public formatter therefore takes `ctx` = { correctionMs, hour12 },
// and every caller passes the one ctx the panel owns.
// ---------------------------------------------------------------------------

var MINUTE = 60000
var HOUR = 3600000
var DAY = 86400000

var DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var DAY_NAMES_LONG = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
var MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function defaultContext() {
  return { correctionMs: 0, hour12: false }
}

function _ctx(ctx) {
  if (!ctx) return defaultContext()
  return {
    correctionMs: Number(ctx.correctionMs) || 0,
    hour12: ctx.hour12 === true
  }
}

// ------------------------------------------------------------- ingest

// Jolpica/Ergast hand back a UTC date and time as two fields, e.g.
// ("2026-03-08", "04:00:00Z"). A missing time means the schedule only knows
// the day; callers treat those as date-only and never print a clock for them.
function fromErgast(date, time) {
  if (!date) return null
  var d = String(date)
  var t = String(time || "")
  if (t === "") {
    var dayAt = parseIso(d + "T00:00:00Z")
    return dayAt === null ? null : { at: dayAt, dateOnly: true }
  }
  if (t.charAt(t.length - 1) !== "Z" && t.indexOf("+") === -1) t += "Z"
  var at = parseIso(d + "T" + t)
  return at === null ? null : { at: at, dateOnly: false }
}

// OpenF1 uses full ISO-8601 with an explicit offset ("...T13:00:00+00:00").
// Date.parse handles both that and the Z form; anything it rejects becomes
// null so a partial API response degrades into "unknown" rather than NaN
// leaking into arithmetic.
function parseIso(value) {
  if (value === undefined || value === null || value === "") return null
  var ms = Date.parse(String(value))
  return isFinite(ms) ? ms : null
}

function isInstant(value) {
  return typeof value === "number" && isFinite(value)
}

// ------------------------------------------------------------- conversion

// The only place an absolute instant becomes wall-clock. Everything below
// funnels through it.
function localDate(at, ctx) {
  var c = _ctx(ctx)
  return new Date(at + c.correctionMs)
}

function pad2(n) {
  return n < 10 ? "0" + n : String(n)
}

// ------------------------------------------------------------- formatters

function formatTime(at, ctx) {
  if (!isInstant(at)) return "—"
  var c = _ctx(ctx)
  var d = localDate(at, c)
  var h = d.getHours()
  var m = pad2(d.getMinutes())
  if (!c.hour12) return pad2(h) + ":" + m
  var suffix = h >= 12 ? "PM" : "AM"
  var h12 = h % 12
  if (h12 === 0) h12 = 12
  return h12 + ":" + m + " " + suffix
}

function formatDate(at, ctx) {
  if (!isInstant(at)) return "—"
  var d = localDate(at, ctx)
  return DAY_NAMES[d.getDay()] + " " + d.getDate() + " " + MONTH_NAMES[d.getMonth()]
}

function formatDateLong(at, ctx) {
  if (!isInstant(at)) return "—"
  var d = localDate(at, ctx)
  return DAY_NAMES_LONG[d.getDay()] + " " + d.getDate() + " " + MONTH_NAMES[d.getMonth()] + " " + d.getFullYear()
}

function formatDayShort(at, ctx) {
  if (!isInstant(at)) return "—"
  return DAY_NAMES[localDate(at, ctx).getDay()].toUpperCase()
}

function formatDateTime(at, ctx) {
  if (!isInstant(at)) return "—"
  return formatDate(at, ctx) + " · " + formatTime(at, ctx)
}

function formatDayTime(at, ctx) {
  if (!isInstant(at)) return "—"
  return formatDayShort(at, ctx) + " " + formatTime(at, ctx)
}

// "Fri 6 Mar" or "Fri 6 – Sun 8 Mar" for a weekend spanning several days.
function formatDateRange(fromAt, toAt, ctx) {
  if (!isInstant(fromAt)) return "—"
  if (!isInstant(toAt)) return formatDate(fromAt, ctx)
  var a = localDate(fromAt, ctx)
  var b = localDate(toAt, ctx)
  if (a.getMonth() === b.getMonth() && a.getDate() === b.getDate()) return formatDate(fromAt, ctx)
  if (a.getMonth() === b.getMonth())
    return DAY_NAMES[a.getDay()] + " " + a.getDate() + " – " + DAY_NAMES[b.getDay()] + " " + b.getDate() + " " + MONTH_NAMES[b.getMonth()]
  return formatDate(fromAt, ctx) + " – " + formatDate(toAt, ctx)
}

// Same local calendar day, judged in the laptop's zone rather than UTC — the
// weekend schedule groups sessions by the day the user will experience.
function isSameLocalDay(a, b, ctx) {
  if (!isInstant(a) || !isInstant(b)) return false
  var da = localDate(a, ctx)
  var db = localDate(b, ctx)
  return da.getFullYear() === db.getFullYear() && da.getMonth() === db.getMonth() && da.getDate() === db.getDate()
}

// ------------------------------------------------------------- countdowns

// Countdowns are pure instant arithmetic — a difference of two UTC
// milliseconds. They never touch the local zone, so a DST jump or a zone
// change cannot make "time until lights out" wrong.
function breakdown(at, nowMs) {
  if (!isInstant(at) || !isInstant(nowMs)) return null
  var remaining = at - nowMs
  var past = remaining < 0
  var abs = Math.abs(remaining)
  return {
    past: past,
    total: remaining,
    days: Math.floor(abs / DAY),
    hours: Math.floor((abs % DAY) / HOUR),
    minutes: Math.floor((abs % HOUR) / MINUTE),
    seconds: Math.floor((abs % MINUTE) / 1000)
  }
}

// Long form for the hero countdown: "2d 14h 06m" / "14h 06m 22s" / "06m 22s".
function countdown(at, nowMs) {
  var b = breakdown(at, nowMs)
  if (!b) return "—"
  if (b.past) return "under way"
  if (b.days > 0) return b.days + "d " + pad2(b.hours) + "h " + pad2(b.minutes) + "m"
  if (b.hours > 0) return b.hours + "h " + pad2(b.minutes) + "m " + pad2(b.seconds) + "s"
  if (b.minutes > 0) return b.minutes + "m " + pad2(b.seconds) + "s"
  return b.seconds + "s"
}

// Compact form for the bar pill and the upcoming-race cards: "12d", "2d 14h",
// "14h 06m", "06:22". Width-stable enough not to make the bar jitter.
function shortCountdown(at, nowMs) {
  var b = breakdown(at, nowMs)
  if (!b) return "—"
  if (b.past) return "live"
  if (b.days >= 7) return b.days + "d"
  if (b.days > 0) return b.days + "d " + pad2(b.hours) + "h"
  if (b.hours > 0) return b.hours + "h " + pad2(b.minutes) + "m"
  return pad2(b.minutes) + ":" + pad2(b.seconds)
}

// Freshness label for live timing and cached data: "8s ago", "4m ago".
function agoText(at, nowMs) {
  if (!isInstant(at) || !isInstant(nowMs)) return "never"
  var delta = Math.max(0, nowMs - at)
  if (delta < 5000) return "just now"
  if (delta < MINUTE) return Math.floor(delta / 1000) + "s ago"
  if (delta < HOUR) return Math.floor(delta / MINUTE) + "m ago"
  if (delta < DAY) return Math.floor(delta / HOUR) + "h ago"
  return Math.floor(delta / DAY) + "d ago"
}

if (typeof module !== "undefined") {
  module.exports = {
    MINUTE: MINUTE, HOUR: HOUR, DAY: DAY,
    defaultContext: defaultContext,
    fromErgast: fromErgast,
    parseIso: parseIso,
    isInstant: isInstant,
    localDate: localDate,
    formatTime: formatTime,
    formatDate: formatDate,
    formatDateLong: formatDateLong,
    formatDayShort: formatDayShort,
    formatDateTime: formatDateTime,
    formatDayTime: formatDayTime,
    formatDateRange: formatDateRange,
    isSameLocalDay: isSameLocalDay,
    breakdown: breakdown,
    countdown: countdown,
    shortCountdown: shortCountdown,
    agoText: agoText
  }
}
