.pragma library

.import "F1Time.js" as F1Time

// ---------------------------------------------------------------------------
// Pure normalization of every data source into the shapes the UI renders.
//
// Nothing here touches the network, the filesystem, or QML. Every function is
// total: a partial, truncated, or reshaped API response yields an empty list or
// a null field, never an exception and never NaN. That is what keeps a bad
// response from taking the shell's panel down with it.
//
// Every time value produced here is an absolute instant in epoch milliseconds.
// Wall-clock formatting is F1Time's job alone.
// ---------------------------------------------------------------------------

// Nominal session lengths, used only to decide whether a session is running
// when the schedule source gives a start but no end. OpenF1 supplies real end
// times for the current era and always wins over these.
var NOMINAL_DURATION_MIN = {
  "fp1": 65,
  "fp2": 65,
  "fp3": 65,
  "sq": 50,
  "sprint": 65,
  "quali": 70,
  "race": 140
}

// Ergast field -> session identity. Order is weekend order, which is also the
// order the timeline renders in; actual start times re-sort it afterwards so a
// rescheduled session still lands in the right place.
var ERGAST_SESSIONS = [
  { field: "FirstPractice",   key: "fp1",    short: "FP1",   name: "Practice 1",        group: "Practice" },
  { field: "SecondPractice",  key: "fp2",    short: "FP2",   name: "Practice 2",        group: "Practice" },
  { field: "SprintQualifying", key: "sq",    short: "SQ",    name: "Sprint Qualifying", group: "Sprint" },
  { field: "ThirdPractice",   key: "fp3",    short: "FP3",   name: "Practice 3",        group: "Practice" },
  { field: "Sprint",          key: "sprint", short: "SPR",   name: "Sprint",            group: "Sprint" },
  { field: "Qualifying",      key: "quali",  short: "QUAL",  name: "Qualifying",        group: "Qualifying" }
]

function num(value, fallback) {
  var n = parseFloat(String(value))
  return isFinite(n) ? n : (fallback === undefined ? null : fallback)
}

function int(value, fallback) {
  var n = parseInt(String(value), 10)
  return isFinite(n) ? n : (fallback === undefined ? null : fallback)
}

function str(value) {
  return value === undefined || value === null ? "" : String(value)
}

// Text on its way to the notification helper's command line.
//
// omarchy-notification-send scans its WHOLE argument list for options, not
// just the leading ones, and one of those options is --exec: a command the
// shell runs when the toast is clicked. Titles and bodies here are built from
// names the API supplied, so a name that looks like an option corrupts the
// call — today that costs a dropped notification, and it is one extra argument
// at the call site away from handing --exec a value. So nothing that reaches
// an argument may look like an option, carry a control character, or run on
// unbounded.
function notificationArg(value, fallback) {
  var text = str(value)
    .replace(/[\u0000-\u001f\u007f]+/g, " ")
    .replace(/^[\s-]+/, "")
    .replace(/\s+$/, "")
  if (text.length > 160) text = text.slice(0, 159) + "\u2026"
  return text === "" ? str(fallback) : text
}

function safeParse(raw) {
  try {
    var parsed = JSON.parse(String(raw || ""))
    return parsed && typeof parsed === "object" ? parsed : null
  } catch (e) {
    return null
  }
}

function arrayAt(obj, path) {
  var node = obj
  for (var i = 0; i < path.length; i++) {
    if (!node || typeof node !== "object") return []
    node = node[path[i]]
  }
  return Array.isArray(node) ? node : []
}

// ----------------------------------------------------------------- calendar

// Jolpica/Ergast `/races` -> the plugin's race shape. Sessions carry absolute
// start instants and, where derivable, absolute end instants.
function parseRaces(raw) {
  var data = safeParse(raw)
  var races = arrayAt(data, ["MRData", "RaceTable", "Races"])
  var out = []

  for (var i = 0; i < races.length; i++) {
    var r = races[i]
    if (!r || typeof r !== "object") continue

    var raceStamp = F1Time.fromErgast(r.date, r.time)
    if (!raceStamp) continue

    var circuit = r.Circuit && typeof r.Circuit === "object" ? r.Circuit : {}
    var location = circuit.Location && typeof circuit.Location === "object" ? circuit.Location : {}

    var sessions = []
    for (var s = 0; s < ERGAST_SESSIONS.length; s++) {
      var spec = ERGAST_SESSIONS[s]
      var field = r[spec.field]
      if (!field || typeof field !== "object") continue
      var stamp = F1Time.fromErgast(field.date, field.time)
      if (!stamp) continue
      sessions.push(makeSession(spec.key, spec.short, spec.name, spec.group, stamp))
    }

    sessions.push(makeSession("race", "RACE", "Race", "Race", raceStamp))
    sessions.sort(function(a, b) { return a.startAt - b.startAt })

    var hasSprint = false
    for (var k = 0; k < sessions.length; k++) {
      if (sessions[k].key === "sprint") hasSprint = true
    }

    out.push({
      season: str(r.season),
      round: int(r.round, 0),
      name: str(r.raceName),
      wikiUrl: str(r.url),
      circuitId: str(circuit.circuitId),
      circuitName: str(circuit.circuitName),
      circuitUrl: str(circuit.url),
      locality: str(location.locality),
      country: str(location.country),
      latitude: num(location.lat),
      longitude: num(location.long),
      raceStartAt: raceStamp.at,
      raceDateOnly: raceStamp.dateOnly === true,
      sessions: sessions,
      isSprintWeekend: hasSprint,
      weekendStartAt: sessions.length > 0 ? sessions[0].startAt : raceStamp.at,
      weekendEndAt: sessions.length > 0 ? sessions[sessions.length - 1].endAt : raceStamp.at
    })
  }

  out.sort(function(a, b) { return a.raceStartAt - b.raceStartAt })
  return out
}

function makeSession(key, short, name, group, stamp) {
  var duration = (NOMINAL_DURATION_MIN[key] || 60) * F1Time.MINUTE
  return {
    key: key,
    short: short,
    name: name,
    group: group,
    startAt: stamp.at,
    // A date-only entry has no meaningful clock, so it gets no end either;
    // the UI prints the date and omits the time rather than inventing one.
    endAt: stamp.dateOnly ? stamp.at : stamp.at + duration,
    dateOnly: stamp.dateOnly === true,
    // Set true once a real end time arrives from OpenF1.
    exactEnd: false,
    sessionKey: null
  }
}

// ------------------------------------------------- schedule refinement

// OpenF1 `/sessions?year=N` -> per-session real start/end plus the session_key
// the live feed is addressed by. Matching is by circuit-agnostic time: a
// session whose start is within a few hours of a scheduled one, inside the same
// meeting window, is the same session. That tolerates schedule revisions
// without needing the two sources to agree on names or circuit ids.
function parseOpenF1Sessions(raw) {
  var rows = safeParse(raw)
  if (!Array.isArray(rows)) return []
  var out = []
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!row || row.is_cancelled === true) continue
    var startAt = F1Time.parseIso(row.date_start)
    if (startAt === null) continue
    out.push({
      sessionKey: int(row.session_key),
      meetingKey: int(row.meeting_key),
      type: str(row.session_type),
      name: str(row.session_name),
      startAt: startAt,
      endAt: F1Time.parseIso(row.date_end),
      circuitShortName: str(row.circuit_short_name),
      countryName: str(row.country_name),
      location: str(row.location)
    })
  }
  out.sort(function(a, b) { return a.startAt - b.startAt })
  return out
}

// Returns a copy of `race` with exact end times and session keys folded in.
// Missing OpenF1 data leaves the nominal schedule untouched.
function refineRace(race, openF1Sessions) {
  if (!race) return race
  if (!Array.isArray(openF1Sessions) || openF1Sessions.length === 0) return race

  var tolerance = 6 * F1Time.HOUR
  var sessions = []
  var meetingKey = null

  for (var i = 0; i < race.sessions.length; i++) {
    var scheduled = race.sessions[i]
    var best = null
    var bestDelta = tolerance

    for (var j = 0; j < openF1Sessions.length; j++) {
      var live = openF1Sessions[j]
      if (!sessionTypesMatch(scheduled, live)) continue
      var delta = Math.abs(live.startAt - scheduled.startAt)
      if (delta < bestDelta) {
        bestDelta = delta
        best = live
      }
    }

    if (!best) {
      sessions.push(scheduled)
      continue
    }

    if (meetingKey === null) meetingKey = best.meetingKey
    sessions.push({
      key: scheduled.key,
      short: scheduled.short,
      name: scheduled.name,
      group: scheduled.group,
      startAt: best.startAt,
      endAt: best.endAt !== null ? best.endAt : scheduled.endAt,
      dateOnly: false,
      exactEnd: best.endAt !== null,
      sessionKey: best.sessionKey
    })
  }

  sessions.sort(function(a, b) { return a.startAt - b.startAt })

  var refined = {}
  for (var key in race) refined[key] = race[key]
  refined.sessions = sessions
  refined.meetingKey = meetingKey
  refined.weekendStartAt = sessions.length > 0 ? sessions[0].startAt : race.weekendStartAt
  refined.weekendEndAt = sessions.length > 0 ? sessions[sessions.length - 1].endAt : race.weekendEndAt
  for (var s = 0; s < sessions.length; s++) {
    if (sessions[s].key === "race") refined.raceStartAt = sessions[s].startAt
  }
  return refined
}

function sessionTypesMatch(scheduled, live) {
  var name = String(live.name || "").toLowerCase()
  var type = String(live.type || "").toLowerCase()
  switch (scheduled.key) {
    case "fp1": return name === "practice 1"
    case "fp2": return name === "practice 2"
    case "fp3": return name === "practice 3"
    case "quali": return type === "qualifying" && name.indexOf("sprint") === -1
    case "sq": return name.indexOf("sprint") !== -1 && (name.indexOf("qualif") !== -1 || name.indexOf("shootout") !== -1)
    case "sprint": return name === "sprint" || (type === "race" && name.indexOf("sprint") !== -1)
    case "race": return type === "race" && name.indexOf("sprint") === -1
  }
  return false
}

// ----------------------------------------------------------------- state

// "done" | "live" | "soon" | "upcoming". `soon` is the hour before a session,
// which is what the weekend timeline and the notifier both key off.
function sessionState(session, nowMs) {
  if (!session || !F1Time.isInstant(session.startAt)) return "upcoming"
  if (session.dateOnly) return nowMs > session.startAt + F1Time.DAY ? "done" : "upcoming"
  if (nowMs >= session.endAt) return "done"
  if (nowMs >= session.startAt) return "live"
  if (session.startAt - nowMs <= F1Time.HOUR) return "soon"
  return "upcoming"
}

function liveSession(race, nowMs) {
  if (!race || !race.sessions) return null
  for (var i = 0; i < race.sessions.length; i++) {
    if (sessionState(race.sessions[i], nowMs) === "live") return race.sessions[i]
  }
  return null
}

function nextSession(race, nowMs) {
  if (!race || !race.sessions) return null
  for (var i = 0; i < race.sessions.length; i++) {
    var s = race.sessions[i]
    if (s.startAt > nowMs) return s
  }
  return null
}

function sessionByKey(race, key) {
  if (!race || !race.sessions) return null
  for (var i = 0; i < race.sessions.length; i++) {
    if (race.sessions[i].key === key) return race.sessions[i]
  }
  return null
}

// The banner headline. Adapts to where in the weekend we are, which is what
// tells the user at a glance whether to expect a countdown or live timing.
function weekendState(race, nowMs) {
  if (!race) return { label: "OFF SEASON", kind: "idle" }

  var live = liveSession(race, nowMs)
  if (live) {
    var headline = live.key === "quali" ? "QUALIFYING"
      : live.key === "sq" ? "SPRINT QUALIFYING"
      : live.key === "sprint" ? "SPRINT"
      : live.short
    return { label: headline + " LIVE", kind: "live", session: live }
  }

  var raceSession = sessionByKey(race, "race")
  if (raceSession && nowMs >= raceSession.endAt) return { label: "RACE FINISHED", kind: "finished", session: raceSession }

  var soon = null
  for (var i = 0; i < race.sessions.length; i++) {
    if (sessionState(race.sessions[i], nowMs) === "soon") { soon = race.sessions[i]; break }
  }
  if (soon) return { label: soon.short + " STARTS SOON", kind: "soon", session: soon }

  if (nowMs >= race.weekendStartAt) return { label: "RACE WEEKEND", kind: "weekend", session: nextSession(race, nowMs) }
  return { label: "NEXT RACE", kind: "upcoming", session: raceSession }
}

// The race the dashboard is about: the first whose race session has not
// finished. A race that ended stays current until its result has been on
// screen for a day, so a Sunday-evening glance still shows what just happened
// instead of jumping to a circuit three weeks out.
function currentRaceIndex(races, nowMs) {
  if (!Array.isArray(races) || races.length === 0) return -1
  for (var i = 0; i < races.length; i++) {
    var raceSession = sessionByKey(races[i], "race")
    var endAt = raceSession ? raceSession.endAt : races[i].raceStartAt
    if (nowMs < endAt + F1Time.DAY) return i
  }
  return -1
}

function upcomingRaces(races, currentIndex, count) {
  if (!Array.isArray(races) || currentIndex < 0) return []
  return races.slice(currentIndex + 1, currentIndex + 1 + (count || 3))
}

// --------------------------------------------------------------- standings

function parseDriverStandings(raw) {
  var data = safeParse(raw)
  var lists = arrayAt(data, ["MRData", "StandingsTable", "StandingsLists"])
  var rows = lists.length > 0 && Array.isArray(lists[0].DriverStandings) ? lists[0].DriverStandings : []
  var out = []

  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    var driver = row && row.Driver ? row.Driver : {}
    var constructors = row && Array.isArray(row.Constructors) ? row.Constructors : []
    var team = constructors.length > 0 ? constructors[constructors.length - 1] : {}
    out.push({
      position: int(row.position, i + 1),
      points: num(row.points, 0),
      wins: int(row.wins, 0),
      driverId: str(driver.driverId),
      code: str(driver.code) || str(driver.familyName).slice(0, 3).toUpperCase(),
      givenName: str(driver.givenName),
      familyName: str(driver.familyName),
      fullName: (str(driver.givenName) + " " + str(driver.familyName)).replace(/^\s+|\s+$/g, ""),
      constructorId: str(team.constructorId),
      constructorName: str(team.name)
    })
  }

  out.sort(function(a, b) { return a.position - b.position })
  return out
}

function parseConstructorStandings(raw) {
  var data = safeParse(raw)
  var lists = arrayAt(data, ["MRData", "StandingsTable", "StandingsLists"])
  var rows = lists.length > 0 && Array.isArray(lists[0].ConstructorStandings) ? lists[0].ConstructorStandings : []
  var out = []

  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    var team = row && row.Constructor ? row.Constructor : {}
    out.push({
      position: int(row.position, i + 1),
      points: num(row.points, 0),
      wins: int(row.wins, 0),
      constructorId: str(team.constructorId),
      constructorName: str(team.name)
    })
  }

  out.sort(function(a, b) { return a.position - b.position })
  return out
}

// Top N, plus the always-visible driver pinned underneath when they fall
// outside it. Returns the pin already annotated with the gap to the leader so
// the row can say "47 pts behind leader" without recomputing anything.
function standingsWithPin(standings, topCount, pinQuery) {
  var list = Array.isArray(standings) ? standings : []
  var top = list.slice(0, topCount || 5)
  var query = String(pinQuery || "").replace(/^\s+|\s+$/g, "").toLowerCase()
  if (query === "" || list.length === 0) return { top: top, pinned: null }

  var found = null
  for (var i = 0; i < list.length; i++) {
    var d = list[i]
    if (d.driverId.toLowerCase() === query
        || d.code.toLowerCase() === query
        || d.familyName.toLowerCase() === query
        || d.fullName.toLowerCase() === query
        || d.fullName.toLowerCase().indexOf(query) !== -1) {
      found = d
      break
    }
  }
  if (!found) return { top: top, pinned: null }

  for (var t = 0; t < top.length; t++) {
    if (top[t].driverId === found.driverId) return { top: top, pinned: null }
  }

  var leaderPoints = list[0].points
  var pinned = {}
  for (var key in found) pinned[key] = found[key]
  pinned.gapToLeader = Math.max(0, leaderPoints - found.points)
  return { top: top, pinned: pinned }
}

// ----------------------------------------------------------------- results

function parseRaceResults(raw) {
  var data = safeParse(raw)
  var races = arrayAt(data, ["MRData", "RaceTable", "Races"])
  if (races.length === 0) return null
  var race = races[0]
  var rows = Array.isArray(race.Results) ? race.Results : []
  var out = []

  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    var driver = row.Driver || {}
    var team = row.Constructor || {}
    var timeText = row.Time && row.Time.time ? str(row.Time.time) : ""
    var status = str(row.status)
    out.push({
      position: int(row.position, i + 1),
      positionText: str(row.positionText),
      classified: /^\d+$/.test(str(row.positionText)),
      points: num(row.points, 0),
      grid: int(row.grid, 0),
      laps: int(row.laps, 0),
      status: status,
      // Winner shows total time, everyone else the gap; retirements show why.
      resultText: timeText !== "" ? timeText : status,
      driverId: str(driver.driverId),
      code: str(driver.code) || str(driver.familyName).slice(0, 3).toUpperCase(),
      fullName: (str(driver.givenName) + " " + str(driver.familyName)).replace(/^\s+|\s+$/g, ""),
      familyName: str(driver.familyName),
      constructorId: str(team.constructorId),
      constructorName: str(team.name),
      fastestLap: row.FastestLap && row.FastestLap.Time ? str(row.FastestLap.Time.time) : "",
      fastestLapRank: row.FastestLap ? int(row.FastestLap.rank, 0) : 0
    })
  }

  out.sort(function(a, b) { return a.position - b.position })

  var stamp = F1Time.fromErgast(race.date, race.time)
  return {
    season: str(race.season),
    round: int(race.round, 0),
    name: str(race.raceName),
    circuitName: race.Circuit ? str(race.Circuit.circuitName) : "",
    startAt: stamp ? stamp.at : null,
    // Winner's lap count is the scheduled distance, which is what the live
    // view needs for "LAP 42 / 57" — OpenF1 does not publish a total.
    totalLaps: out.length > 0 ? out[0].laps : null,
    results: out
  }
}

function parseQualifying(raw) {
  var data = safeParse(raw)
  var races = arrayAt(data, ["MRData", "RaceTable", "Races"])
  if (races.length === 0) return null
  var race = races[0]
  var rows = Array.isArray(race.QualifyingResults) ? race.QualifyingResults : []
  var out = []

  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    var driver = row.Driver || {}
    var team = row.Constructor || {}
    var best = str(row.Q3) || str(row.Q2) || str(row.Q1)
    out.push({
      position: int(row.position, i + 1),
      driverId: str(driver.driverId),
      code: str(driver.code) || str(driver.familyName).slice(0, 3).toUpperCase(),
      fullName: (str(driver.givenName) + " " + str(driver.familyName)).replace(/^\s+|\s+$/g, ""),
      familyName: str(driver.familyName),
      constructorId: str(team.constructorId),
      constructorName: str(team.name),
      q1: str(row.Q1),
      q2: str(row.Q2),
      q3: str(row.Q3),
      bestTime: best
    })
  }

  out.sort(function(a, b) { return a.position - b.position })
  return {
    season: str(race.season),
    round: int(race.round, 0),
    name: str(race.raceName),
    positions: out
  }
}

// The Wikipedia article title a circuit's image is looked up by, taken from
// the article URL Ergast already hands us rather than guessed from the name.
function wikiTitleFromUrl(url) {
  var value = str(url)
  var match = value.match(/\/wiki\/([^?#]+)/)
  if (!match) return ""
  return match[1]
}

// Is this Wikimedia image plausibly a track layout diagram rather than a
// photograph?
//
// A season's race article usually leads with the current circuit map, which is
// exactly the image the dashboard wants — but early in a season it often leads
// with a photo of a driver instead. Two signals separate them reliably:
// layout diagrams are vector art rendered from SVG, and their file names name
// the circuit. A photo of a car passes neither.
//
// Getting this wrong is cheap in one direction and expensive in the other: a
// rejected map just falls back to the circuit article, while an accepted photo
// would put a random driver where the track should be. The test is therefore
// deliberately strict.
function looksLikeTrackMap(imageUrl) {
  var url = str(imageUrl)
  if (url === "") return false

  var name = url.split("?")[0].split("/").pop().toLowerCase()
  if (name === "") return false
  if (/\.(jpg|jpeg)$/.test(name)) return false
  if (/\.svg\.png$/.test(name)) return true
  return /(circuit|track|layout|autodro|speedway|raceway|grand[_ -]?prix)/.test(name)
}

if (typeof module !== "undefined") {
  module.exports = {
    NOMINAL_DURATION_MIN: NOMINAL_DURATION_MIN,
    safeParse: safeParse,
    notificationArg: notificationArg,
    parseRaces: parseRaces,
    parseOpenF1Sessions: parseOpenF1Sessions,
    refineRace: refineRace,
    sessionState: sessionState,
    liveSession: liveSession,
    nextSession: nextSession,
    sessionByKey: sessionByKey,
    weekendState: weekendState,
    currentRaceIndex: currentRaceIndex,
    upcomingRaces: upcomingRaces,
    parseDriverStandings: parseDriverStandings,
    parseConstructorStandings: parseConstructorStandings,
    standingsWithPin: standingsWithPin,
    parseRaceResults: parseRaceResults,
    parseQualifying: parseQualifying,
    wikiTitleFromUrl: wikiTitleFromUrl,
    looksLikeTrackMap: looksLikeTrackMap
  }
}
