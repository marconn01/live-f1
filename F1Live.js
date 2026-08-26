.pragma library

.import "F1Time.js" as F1Time

// ---------------------------------------------------------------------------
// Live timing reduction.
//
// OpenF1 endpoints are append-only event logs, not snapshots: a poll returns
// every row in the requested window, most of them superseded. These functions
// collapse a window into the current state — one row per driver, latest wins —
// so the panel renders a grid rather than a stream.
//
// Everything is defensive by construction. A truncated response, a driver that
// appears in one feed but not another, a gap the feed reports as a string
// ("+1 LAP") instead of a number: all produce a row that still renders, marked
// unknown where it has to be.
// ---------------------------------------------------------------------------

// Every per-driver map in this file is keyed on a number the feed supplies,
// so the key is checked before it is used. A row arriving as driver_number
// "__proto__" would otherwise reach an object's prototype instead of landing
// in the object: in parsePits below, `byDriver[key].count++` on such a key
// increments a counter on Object.prototype rather than on a driver's tally,
// and every plain object in the QML engine inherits it.
function driverKey(value) {
  if (value === undefined || value === null) return ""
  var key = String(value)
  return /^[0-9]{1,3}$/.test(key) ? key : ""
}

function safeRows(raw) {
  try {
    var parsed = JSON.parse(String(raw || ""))
    return Array.isArray(parsed) ? parsed : []
  } catch (e) {
    return []
  }
}

// Fold a freshly polled window into the state accumulated so far, latest row
// per driver winning.
//
// Accumulating rather than replacing is what makes a narrow polling window
// safe. `position` only emits a row when a car actually changes place, so a
// driver holding station longer than the window simply is not in the response
// — rebuilding from one window alone drops them off the timing tower
// entirely. Merging keeps every driver present while still asking for only
// the last few minutes of data each tick.
function mergeLatest(existing, raw) {
  var merged = {}
  for (var key in existing) merged[key] = existing[key]

  var incoming = latestPerDriver(safeRows(raw))
  for (var number in incoming) {
    var current = merged[number]
    var next = incoming[number]
    if (!current || current.__at === null || next.__at === null || next.__at >= current.__at)
      merged[number] = next
  }
  return merged
}

// Latest row per driver_number, judged by the row's own timestamp so
// out-of-order delivery cannot roll state backwards.
function latestPerDriver(rows) {
  var byDriver = {}
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!row) continue
    var key = driverKey(row.driver_number)
    if (key === "") continue
    var at = F1Time.parseIso(row.date)
    var current = byDriver[key]
    if (!current || at === null || current.__at === null || at >= current.__at) {
      var copy = {}
      for (var k in row) copy[k] = row[k]
      copy.__at = at
      byDriver[key] = copy
    }
  }
  return byDriver
}

function parseDrivers(raw) {
  var rows = safeRows(raw)
  var byNumber = {}
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!row) continue
    var number = driverKey(row.driver_number)
    if (number === "") continue
    byNumber[number] = {
      number: parseInt(number, 10),
      acronym: String(row.name_acronym || ""),
      fullName: String(row.full_name || ""),
      teamName: String(row.team_name || ""),
      teamColour: String(row.team_colour || "")
    }
  }
  return byNumber
}

// Pit stop tally per driver, plus each driver's most recent stop.
function parsePits(raw) {
  var rows = safeRows(raw)
  var byDriver = {}
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!row) continue
    var key = driverKey(row.driver_number)
    if (key === "") continue
    if (!byDriver[key]) byDriver[key] = { count: 0, lastLap: null, lastDuration: null }
    byDriver[key].count++
    var lap = parseInt(row.lap_number, 10)
    if (isFinite(lap) && (byDriver[key].lastLap === null || lap >= byDriver[key].lastLap)) {
      byDriver[key].lastLap = lap
      var duration = parseFloat(row.pit_duration)
      byDriver[key].lastDuration = isFinite(duration) ? duration : null
    }
  }
  return byDriver
}

// The highest lap number anyone has completed in the window we fetched.
function currentLap(raw, previous) {
  var rows = safeRows(raw)
  var max = isFinite(previous) ? previous : 0
  for (var i = 0; i < rows.length; i++) {
    var lap = parseInt(rows[i] && rows[i].lap_number, 10)
    if (isFinite(lap) && lap > max) max = lap
  }
  return max > 0 ? max : null
}

// A gap is a number of seconds, a lapped-car string, or absent. Normalize to
// { text, seconds } so the row renders identically in all three cases and the
// unknown case is visibly unknown rather than silently zero.
function formatGap(value, isLeader) {
  if (isLeader) return { text: "LEADER", seconds: 0, known: true }
  if (value === undefined || value === null || value === "") return { text: "—", seconds: null, known: false }
  if (typeof value === "string") {
    var trimmed = value.replace(/^\s+|\s+$/g, "")
    var asNumber = parseFloat(trimmed)
    if (/^[+-]?\d+(\.\d+)?$/.test(trimmed) && isFinite(asNumber))
      return { text: "+" + asNumber.toFixed(3), seconds: asNumber, known: true }
    return { text: trimmed.toUpperCase(), seconds: null, known: true }
  }
  var n = parseFloat(value)
  if (!isFinite(n)) return { text: "—", seconds: null, known: false }
  return { text: "+" + n.toFixed(3), seconds: n, known: true }
}

// Merge the accumulated feed state into the ordered grid the live view
// renders. Takes already-merged dictionaries (see mergeLatest) so that the
// grid can be rebuilt whenever ANY feed lands — the fast poll bringing new
// positions, or the slow poll bringing the driver roster — rather than only
// when positions happen to arrive.
function buildGrid(driversByNumber, positions, intervals, pitsByDriver) {
  var rows = []

  for (var key in positions) {
    var pos = parseInt(positions[key].position, 10)
    if (!isFinite(pos)) continue

    var driver = driversByNumber[key] || {
      number: parseInt(key, 10), acronym: "", fullName: "", teamName: "", teamColour: ""
    }
    var interval = intervals[key] || {}
    var pit = pitsByDriver[key] || { count: 0, lastLap: null, lastDuration: null }
    var isLeader = pos === 1

    rows.push({
      position: pos,
      number: driver.number,
      acronym: driver.acronym || ("#" + key),
      fullName: driver.fullName,
      teamName: driver.teamName,
      teamColour: driver.teamColour,
      interval: formatGap(interval.interval, isLeader),
      gapToLeader: formatGap(interval.gap_to_leader, isLeader),
      pitStops: pit.count,
      lastPitLap: pit.lastLap,
      updatedAt: interval.__at !== undefined ? interval.__at : positions[key].__at
    })
  }

  rows.sort(function(a, b) { return a.position - b.position })
  return rows
}

// Most recent meaningful race-control state. Flags are the truth about whether
// the race is green, neutralised, or stopped, and the label is always text —
// never a bare colour — so the state is readable without seeing the tint.
function sessionStatus(raw) {
  var rows = safeRows(raw)
  var status = { label: "RUNNING", kind: "green", messageAt: null }

  for (var i = rows.length - 1; i >= 0; i--) {
    var row = rows[i]
    if (!row) continue
    var category = String(row.category || "").toUpperCase()
    var flag = String(row.flag || "").toUpperCase()
    var scope = String(row.scope || "").toUpperCase()
    var message = String(row.message || "").toUpperCase()
    var at = F1Time.parseIso(row.date)

    if (category === "SAFETYCAR" || message.indexOf("SAFETY CAR") !== -1) {
      if (message.indexOf("VIRTUAL") !== -1)
        return { label: message.indexOf("ENDING") !== -1 ? "VSC ENDING" : "VIRTUAL SAFETY CAR", kind: "caution", messageAt: at }
      if (message.indexOf("IN THIS LAP") !== -1 || message.indexOf("DEPLOYED") !== -1 || message.indexOf("SAFETY CAR") !== -1)
        return { label: "SAFETY CAR", kind: "caution", messageAt: at }
    }
    if (category === "FLAG" && scope === "TRACK") {
      if (flag === "RED") return { label: "RED FLAG", kind: "stopped", messageAt: at }
      if (flag === "CHEQUERED") return { label: "CHEQUERED FLAG", kind: "finished", messageAt: at }
      if (flag === "YELLOW" || flag === "DOUBLE YELLOW") return { label: "YELLOW FLAG", kind: "caution", messageAt: at }
      if (flag === "GREEN" || flag === "CLEAR") return { label: "RUNNING", kind: "green", messageAt: at }
    }
  }

  return status
}

// The newest timestamp anywhere in the merged grid: what "Updated 8s ago" is
// measured from. Falls back to the poll time when the feed carries no usable
// timestamps, so freshness is never reported as unknown while data is on screen.
function freshestUpdate(grid, fallbackAt) {
  var newest = null
  for (var i = 0; i < grid.length; i++) {
    var at = grid[i].updatedAt
    if (F1Time.isInstant(at) && (newest === null || at > newest)) newest = at
  }
  return newest !== null ? newest : (fallbackAt || null)
}

if (typeof module !== "undefined") {
  module.exports = {
    driverKey: driverKey,
    safeRows: safeRows,
    latestPerDriver: latestPerDriver,
    mergeLatest: mergeLatest,
    parseDrivers: parseDrivers,
    parsePits: parsePits,
    currentLap: currentLap,
    formatGap: formatGap,
    buildGrid: buildGrid,
    sessionStatus: sessionStatus,
    freshestUpdate: freshestUpdate
  }
}
