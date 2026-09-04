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
      // Copy field by field, skipping "__proto__". JSON.parse makes it a
      // real own key, and `copy[k] = row[k]` on that key is an assignment to
      // the prototype slot, not a field: it hands a feed row a prototype of
      // the server's choosing. Nothing downstream reads a driver row through
      // its prototype, so today that buys an attacker nothing they could not
      // get by sending the field outright — but driverKey above exists
      // because this object graph is built from a network response, and this
      // is the same reasoning one level in.
      var copy = {}
      for (var k in row) {
        if (k === "__proto__") continue
        copy[k] = row[k]
      }
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

// A poll that failed carries the reason back in place of the body. OpenF1 now
// answers 401 to everything while a session is running unless the caller is
// authenticated, and a 401 rendered as an empty grid is indistinguishable
// from a quiet track — which is exactly the wrong thing to show at 200mph.
function feedError(raw) {
  var text = String(raw || "").replace(/^\s+|\s+$/g, "")
  if (text.indexOf('"openf1_error"') < 0) return null
  try {
    var parsed = JSON.parse(text)
    if (!parsed || !parsed.openf1_error) return null
    var http = parseInt(parsed.http, 10)
    var curl = parseInt(parsed.curl, 10)
    return { http: isFinite(http) ? http : 0, curl: isFinite(curl) ? curl : 0 }
  } catch (e) {
    return null
  }
}

// The first section of a batched response that came back as a failure. One
// message is worth showing; six copies of it are not.
function firstFeedError(sections) {
  for (var i = 0; i < sections.length; i++) {
    var err = feedError(sections[i])
    if (err) return err
  }
  return null
}

// Whether the poller had credentials, and whether they worked. Reported by the
// shell prelude so the message below can tell "not set up" apart from
// "rejected" — two problems with completely different fixes.
function authState(raw) {
  var value = String(raw || "").replace(/^\s+|\s+$/g, "")
  return (value === "ok" || value === "failed") ? value : "none"
}

// What to actually put in front of the user. Every branch names the thing they
// would have to change; none of them is "an error occurred".
function feedErrorMessage(err, state) {
  if (!err) return ""
  var http = err.http
  if (http === 401 || http === 403) {
    if (state === "ok")
      return "OpenF1 refused this account's live access (HTTP " + http + ")."
    if (state === "failed")
      return "OpenF1 rejected these credentials — check client_id and client_secret in ~/.config/omarchy/f1/credentials."
    return "OpenF1 restricts every endpoint to paid accounts while a session is running. Add credentials to ~/.config/omarchy/f1/credentials for live timing."
  }
  if (http === 429) return "OpenF1 is rate-limiting this client — backing off."
  if (http >= 500) return "OpenF1 is unavailable right now (HTTP " + http + ")."
  if (http > 0) return "OpenF1 returned HTTP " + http + "."
  return "Live feed unreachable."
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
    feedError: feedError,
    firstFeedError: firstFeedError,
    authState: authState,
    feedErrorMessage: feedErrorMessage,
    formatGap: formatGap,
    buildGrid: buildGrid,
    sessionStatus: sessionStatus,
    freshestUpdate: freshestUpdate
  }
}
