// Node harness for the plugin's pure JS modules.
//
// The QML engine loads these as `.pragma library` files with `.import`
// statements, which node cannot parse; the loader below strips those two
// QML-only directives and injects the dependency by name instead. Everything
// else — every function under test — is the exact source the shell runs.
//
//   node tests/run.js            (uses recorded fixtures)
//   node tests/run.js --refresh  (re-downloads fixtures from the live APIs)

const fs = require("fs")
const path = require("path")
const { execFileSync, spawnSync } = require("child_process")

// Pin the harness to UTC. The formatters deliberately read the host's local
// zone (that is the whole point of the time layer), so assertions about
// printed wall clocks would otherwise depend on where the machine happens to
// be. Under TZ=UTC the "engine zone" is UTC and `correctionMs` alone stands in
// for the laptop's zone, which is exactly the relationship being tested.
if (process.env.TZ !== "UTC") {
  const child = spawnSync(process.execPath, [__filename, ...process.argv.slice(2)], {
    stdio: "inherit",
    env: { ...process.env, TZ: "UTC" }
  })
  process.exit(child.status === null ? 1 : child.status)
}

const ROOT = path.join(__dirname, "..")
const FIXTURES = path.join(__dirname, "fixtures")

function load(file, deps = {}) {
  const src = fs
    .readFileSync(path.join(ROOT, file), "utf8")
    .split("\n")
    .filter((line) => !/^\s*\.(pragma|import)\b/.test(line))
    .join("\n")
  const module = { exports: {} }
  const names = Object.keys(deps)
  const fn = new Function("module", "exports", ...names, src)
  fn(module, module.exports, ...names.map((n) => deps[n]))
  return module.exports
}

const F1Time = load("F1Time.js")
const F1Model = load("F1Model.js", { F1Time })
const F1Live = load("F1Live.js", { F1Time })
const F1Teams = load("F1Teams.js")

// ------------------------------------------------------------------ fixtures

const SOURCES = {
  "races.json": "https://api.jolpi.ca/ergast/f1/current/races/?format=json&limit=100",
  "driver-standings.json": "https://api.jolpi.ca/ergast/f1/current/driverstandings/?format=json&limit=100",
  "constructor-standings.json": "https://api.jolpi.ca/ergast/f1/current/constructorstandings/?format=json&limit=100",
  "last-results.json": "https://api.jolpi.ca/ergast/f1/current/last/results/?format=json",
  "last-qualifying.json": "https://api.jolpi.ca/ergast/f1/current/last/qualifying/?format=json",
  "openf1-sessions.json": `https://api.openf1.org/v1/sessions?year=${new Date().getUTCFullYear()}`,
  "openf1-drivers.json": "https://api.openf1.org/v1/drivers?session_key=latest",
  "openf1-position.json": "https://api.openf1.org/v1/position?session_key=latest",
  "openf1-pit.json": "https://api.openf1.org/v1/pit?session_key=latest",
  "openf1-race-control.json": "https://api.openf1.org/v1/race_control?session_key=latest"
}

if (process.argv.includes("--refresh")) {
  fs.mkdirSync(FIXTURES, { recursive: true })
  for (const [name, url] of Object.entries(SOURCES)) {
    process.stdout.write(`fetching ${name} … `)
    const body = execFileSync("curl", ["-fsS", "--max-time", "30", url], { maxBuffer: 1 << 28 })
    fs.writeFileSync(path.join(FIXTURES, name), body)
    console.log(`${body.length} bytes`)
  }
}

function fixture(name) {
  const file = path.join(FIXTURES, name)
  if (!fs.existsSync(file)) {
    console.error(`missing fixture ${name} — run: node tests/run.js --refresh`)
    process.exit(2)
  }
  return fs.readFileSync(file, "utf8")
}

// -------------------------------------------------------------------- runner

let passed = 0
const failures = []

function check(name, fn) {
  try {
    fn()
    passed++
  } catch (error) {
    failures.push(`${name}: ${error.message}`)
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message || "assertion failed")
}

function equal(actual, expected, message) {
  if (actual !== expected)
    throw new Error(`${message || "expected"}: got ${JSON.stringify(actual)}, want ${JSON.stringify(expected)}`)
}

// ---------------------------------------------------------------- time layer

const UTC_INSTANT = Date.parse("2026-09-01T14:00:00Z")

check("fromErgast builds an absolute instant from a UTC date+time pair", () => {
  const stamp = F1Time.fromErgast("2026-09-01", "14:00:00Z")
  equal(stamp.at, UTC_INSTANT)
  equal(stamp.dateOnly, false)
})

check("fromErgast tolerates a time with no zone suffix by reading it as UTC", () => {
  equal(F1Time.fromErgast("2026-09-01", "14:00:00").at, UTC_INSTANT)
})

check("fromErgast marks a date with no time as date-only", () => {
  const stamp = F1Time.fromErgast("2026-09-01", "")
  equal(stamp.dateOnly, true)
  equal(stamp.at, Date.parse("2026-09-01T00:00:00Z"))
})

check("fromErgast returns null rather than NaN for junk", () => {
  equal(F1Time.fromErgast("", ""), null)
  equal(F1Time.fromErgast(null, null), null)
  equal(F1Time.fromErgast("not-a-date", "x"), null)
  equal(F1Time.fromErgast("not-a-date", ""), null)
})

check("parseIso handles OpenF1's explicit-offset form", () => {
  equal(F1Time.parseIso("2026-08-23T13:00:00+00:00"), Date.parse("2026-08-23T13:00:00Z"))
  equal(F1Time.parseIso(null), null)
  equal(F1Time.parseIso("garbage"), null)
})

check("a zone correction shifts the printed wall clock, not the instant", () => {
  // Pretend the engine is stuck on UTC while the OS has moved to UTC+05:45.
  const engineUtc = { correctionMs: 0, hour12: false }
  const kathmandu = { correctionMs: (5 * 60 + 45) * 60000, hour12: false }
  equal(F1Time.formatTime(UTC_INSTANT, engineUtc), "14:00")
  equal(F1Time.formatTime(UTC_INSTANT, kathmandu), "19:45")
  // The instant itself is untouched, so the countdown is identical either way.
  const now = UTC_INSTANT - 3 * 3600000
  equal(F1Time.countdown(UTC_INSTANT, now), F1Time.countdown(UTC_INSTANT, now))
  equal(F1Time.countdown(UTC_INSTANT, now), "3h 00m 00s")
})

check("12-hour formatting handles both midnights and noon", () => {
  const ctx = { correctionMs: 0, hour12: true }
  equal(F1Time.formatTime(Date.parse("2026-09-01T00:30:00Z"), ctx), "12:30 AM")
  equal(F1Time.formatTime(Date.parse("2026-09-01T12:00:00Z"), ctx), "12:00 PM")
  equal(F1Time.formatTime(Date.parse("2026-09-01T13:05:00Z"), ctx), "1:05 PM")
})

check("countdown formats each magnitude band", () => {
  const t = UTC_INSTANT
  equal(F1Time.countdown(t, t - 2 * 86400000 - 14 * 3600000 - 6 * 60000), "2d 14h 06m")
  equal(F1Time.countdown(t, t - 65000), "1m 05s")
  equal(F1Time.countdown(t, t - 9000), "9s")
  equal(F1Time.countdown(t, t + 1000), "under way")
})

check("shortCountdown stays compact for the bar pill", () => {
  const t = UTC_INSTANT
  equal(F1Time.shortCountdown(t, t - 9 * 86400000), "9d")
  equal(F1Time.shortCountdown(t, t - 2 * 86400000 - 5 * 3600000), "2d 05h")
  equal(F1Time.shortCountdown(t, t - 3 * 3600000 - 4 * 60000), "3h 04m")
  equal(F1Time.shortCountdown(t, t - 65000), "01:05")
  equal(F1Time.shortCountdown(t, t + 1), "live")
})

check("countdown across a DST boundary counts real elapsed time", () => {
  // Europe/Berlin loses an hour on 2026-03-29. Instant arithmetic must not
  // care: 25 wall-clock hours before a 12:00 instant is still 25 hours.
  const race = Date.parse("2026-03-29T13:00:00Z")
  equal(F1Time.countdown(race, race - 25 * 3600000), "1d 01h 00m")
})

check("agoText describes freshness in every band", () => {
  const now = UTC_INSTANT
  equal(F1Time.agoText(now - 1000, now), "just now")
  equal(F1Time.agoText(now - 8000, now), "8s ago")
  equal(F1Time.agoText(now - 4 * 60000, now), "4m ago")
  equal(F1Time.agoText(now - 3 * 3600000, now), "3h ago")
  equal(F1Time.agoText(null, now), "never")
})

// ------------------------------------------------------------------ calendar

const races = F1Model.parseRaces(fixture("races.json"))

check("the season calendar parses into races with sessions", () => {
  assert(races.length > 0, "no races parsed")
  for (const race of races) {
    assert(race.name !== "", "race with no name")
    assert(Number.isFinite(race.raceStartAt), `${race.name} has no absolute race start`)
    assert(race.sessions.length > 0, `${race.name} has no sessions`)
    assert(race.sessions.some((s) => s.key === "race"), `${race.name} has no race session`)
  }
})

check("sessions are ordered by their absolute start time", () => {
  for (const race of races) {
    for (let i = 1; i < race.sessions.length; i++)
      assert(race.sessions[i].startAt >= race.sessions[i - 1].startAt, `${race.name} sessions out of order`)
  }
})

check("the race is the last session of its own weekend", () => {
  for (const race of races) {
    const last = race.sessions[race.sessions.length - 1]
    equal(last.key, "race", `${race.name} does not end with the race`)
  }
})

check("sprint weekends are detected and carry a sprint session", () => {
  const sprints = races.filter((r) => r.isSprintWeekend)
  assert(sprints.length > 0, "no sprint weekend found in the calendar")
  for (const race of sprints) assert(race.sessions.some((s) => s.key === "sprint"), `${race.name} flagged sprint with no sprint session`)
  // A sprint weekend drops FP2/FP3 for sprint sessions — never both formats.
  for (const race of sprints) assert(!race.sessions.some((s) => s.key === "fp3"), `${race.name} has both a sprint and FP3`)
})

check("a non-sprint weekend has the three practices", () => {
  const normal = races.find((r) => !r.isSprintWeekend)
  assert(normal, "no non-sprint weekend in the calendar")
  for (const key of ["fp1", "fp2", "fp3", "quali"])
    assert(normal.sessions.some((s) => s.key === key), `${normal.name} missing ${key}`)
})

check("parseRaces survives truncated, empty, and malformed input", () => {
  equal(F1Model.parseRaces("").length, 0)
  equal(F1Model.parseRaces("{").length, 0)
  equal(F1Model.parseRaces('{"MRData":{}}').length, 0)
  equal(F1Model.parseRaces('{"MRData":{"RaceTable":{"Races":[{"raceName":"X"}]}}}').length, 0)
  equal(F1Model.parseRaces(fixture("races.json").slice(0, 5000)).length, 0)
})

// -------------------------------------------------------- schedule refinement

const openF1Sessions = F1Model.parseOpenF1Sessions(fixture("openf1-sessions.json"))

check("OpenF1 sessions parse with absolute start and end instants", () => {
  assert(openF1Sessions.length > 0, "no OpenF1 sessions parsed")
  for (const s of openF1Sessions) assert(Number.isFinite(s.startAt), "session with no start")
})

check("refineRace folds exact end times and session keys into the schedule", () => {
  let refinedSessions = 0
  for (const race of races) {
    const refined = F1Model.refineRace(race, openF1Sessions)
    equal(refined.sessions.length, race.sessions.length, `${race.name} lost or gained a session`)
    for (const s of refined.sessions) {
      if (s.exactEnd) {
        refinedSessions++
        assert(s.endAt > s.startAt, `${race.name} ${s.short} ends before it starts`)
        assert(Number.isFinite(s.sessionKey), `${race.name} ${s.short} refined without a session key`)
      }
    }
  }
  assert(refinedSessions > 0, "no session was refined against OpenF1")
})

check("refineRace matches each session type to the right counterpart", () => {
  const sprintWeekend = races.find((r) => r.isSprintWeekend)
  const refined = F1Model.refineRace(sprintWeekend, openF1Sessions)
  const sprint = refined.sessions.find((s) => s.key === "sprint")
  const race = refined.sessions.find((s) => s.key === "race")
  // The sprint must not have been matched to the grand prix, or vice versa.
  if (sprint.sessionKey !== null && race.sessionKey !== null)
    assert(sprint.sessionKey !== race.sessionKey, "sprint and race matched the same OpenF1 session")
})

check("refineRace is a no-op when OpenF1 is unavailable", () => {
  const before = races[0]
  equal(F1Model.refineRace(before, []).sessions.length, before.sessions.length)
  equal(F1Model.refineRace(before, null), before)
})

// -------------------------------------------------------------- weekend state

check("session states walk done -> live -> soon -> upcoming", () => {
  const session = { key: "race", startAt: UTC_INSTANT, endAt: UTC_INSTANT + 2 * 3600000, dateOnly: false }
  equal(F1Model.sessionState(session, UTC_INSTANT - 5 * 3600000), "upcoming")
  equal(F1Model.sessionState(session, UTC_INSTANT - 30 * 60000), "soon")
  equal(F1Model.sessionState(session, UTC_INSTANT), "live")
  equal(F1Model.sessionState(session, UTC_INSTANT + 3600000), "live")
  equal(F1Model.sessionState(session, UTC_INSTANT + 3 * 3600000), "done")
})

check("the weekend headline adapts to each phase", () => {
  const race = F1Model.refineRace(races.find((r) => !r.isSprintWeekend), openF1Sessions)
  const fp1 = race.sessions.find((s) => s.key === "fp1")
  const quali = race.sessions.find((s) => s.key === "quali")
  const grandPrix = race.sessions.find((s) => s.key === "race")

  equal(F1Model.weekendState(race, race.weekendStartAt - 7 * 86400000).label, "NEXT RACE")
  equal(F1Model.weekendState(race, fp1.startAt - 20 * 60000).label, "FP1 STARTS SOON")
  equal(F1Model.weekendState(race, fp1.startAt + 60000).label, "FP1 LIVE")
  equal(F1Model.weekendState(race, quali.startAt + 60000).label, "QUALIFYING LIVE")
  equal(F1Model.weekendState(race, grandPrix.startAt + 60000).label, "RACE LIVE")
  equal(F1Model.weekendState(race, grandPrix.endAt + 3600000).label, "RACE FINISHED")
  equal(F1Model.weekendState(null, Date.now()).label, "OFF SEASON")
})

check("a sprint weekend reports its own session headlines", () => {
  const race = F1Model.refineRace(races.find((r) => r.isSprintWeekend), openF1Sessions)
  const sprint = race.sessions.find((s) => s.key === "sprint")
  equal(F1Model.weekendState(race, sprint.startAt + 60000).label, "SPRINT LIVE")
})

check("the current race stays current through the race and one day after", () => {
  const index = 3
  const race = races[index]
  const grandPrix = race.sessions.find((s) => s.key === "race")
  equal(F1Model.currentRaceIndex(races, race.weekendStartAt), index, "not current at the start of its weekend")
  equal(F1Model.currentRaceIndex(races, grandPrix.startAt + 60000), index, "not current during the race")
  equal(F1Model.currentRaceIndex(races, grandPrix.endAt + 3600000), index, "not current just after the race")
  equal(F1Model.currentRaceIndex(races, grandPrix.endAt + 2 * 86400000), index + 1, "did not roll over the next day")
})

check("the season ending is reported rather than wrapping around", () => {
  const last = races[races.length - 1]
  equal(F1Model.currentRaceIndex(races, last.raceStartAt + 10 * 86400000), -1)
  equal(F1Model.currentRaceIndex([], Date.now()), -1)
})

check("exactly three upcoming races are offered, and fewer at season end", () => {
  equal(F1Model.upcomingRaces(races, 0, 3).length, 3)
  equal(F1Model.upcomingRaces(races, races.length - 2, 3).length, 1)
  equal(F1Model.upcomingRaces(races, races.length - 1, 3).length, 0)
  equal(F1Model.upcomingRaces(races, -1, 3).length, 0)
})

// ------------------------------------------------------------------ standings

const drivers = F1Model.parseDriverStandings(fixture("driver-standings.json"))
const constructors = F1Model.parseConstructorStandings(fixture("constructor-standings.json"))

check("driver standings parse in championship order", () => {
  assert(drivers.length > 0, "no driver standings")
  for (let i = 1; i < drivers.length; i++) {
    assert(drivers[i].position === drivers[i - 1].position + 1, "positions are not consecutive")
    assert(drivers[i].points <= drivers[i - 1].points, "points are not descending")
  }
  for (const d of drivers) {
    assert(d.fullName !== "", "driver with no name")
    assert(d.code !== "", "driver with no abbreviation")
    assert(d.constructorName !== "", `${d.fullName} has no team`)
  }
})

check("constructor standings parse in championship order", () => {
  assert(constructors.length > 0, "no constructor standings")
  for (let i = 1; i < constructors.length; i++)
    assert(constructors[i].points <= constructors[i - 1].points, "constructor points are not descending")
})

check("the pinned driver is added when outside the top five", () => {
  const outside = drivers.find((d) => d.position > 5)
  const result = F1Model.standingsWithPin(drivers, 5, outside.familyName)
  equal(result.top.length, 5)
  assert(result.pinned, "pinned driver missing")
  equal(result.pinned.driverId, outside.driverId)
  equal(result.pinned.gapToLeader, drivers[0].points - outside.points)
})

check("the pinned driver is never duplicated when already in the top five", () => {
  const inside = drivers[2]
  const result = F1Model.standingsWithPin(drivers, 5, inside.familyName)
  equal(result.pinned, null)
})

check("the pin matches on surname, code, or driver id alike", () => {
  const outside = drivers.find((d) => d.position > 5)
  for (const query of [outside.familyName, outside.code, outside.driverId, outside.fullName])
    assert(F1Model.standingsWithPin(drivers, 5, query).pinned, `no match for ${query}`)
  equal(F1Model.standingsWithPin(drivers, 5, "nobody-by-that-name").pinned, null)
  equal(F1Model.standingsWithPin(drivers, 5, "").pinned, null)
  equal(F1Model.standingsWithPin([], 5, "verstappen").pinned, null)
})

// -------------------------------------------------------------------- results

const results = F1Model.parseRaceResults(fixture("last-results.json"))
const qualifying = F1Model.parseQualifying(fixture("last-qualifying.json"))

check("the latest race result parses with a winner and a lap count", () => {
  assert(results, "no result parsed")
  equal(results.results[0].position, 1)
  assert(results.results[0].fullName !== "", "winner has no name")
  assert(results.totalLaps > 0, "no total lap count derived")
  assert(Number.isFinite(results.startAt), "result has no absolute start instant")
})

check("classified and retired finishers are distinguished", () => {
  for (const row of results.results) {
    assert(row.resultText !== "", `${row.fullName} has no result text`)
    if (!row.classified) assert(row.status !== "", "unclassified row with no status")
  }
})

check("qualifying results parse into grid order", () => {
  assert(qualifying, "no qualifying parsed")
  equal(qualifying.positions[0].position, 1)
  for (const row of qualifying.positions) {
    assert(row.code !== "", "qualifying row with no abbreviation")
    assert(row.bestTime !== "" || row.q1 === "", `${row.fullName} has no session time at all`)
  }
})

check("results and qualifying degrade to null on an empty response", () => {
  equal(F1Model.parseRaceResults('{"MRData":{"RaceTable":{"Races":[]}}}'), null)
  equal(F1Model.parseQualifying(""), null)
  equal(F1Model.parseQualifying("<html>rate limited</html>"), null)
})

check("track maps are told apart from photographs", () => {
  // Real lead images observed on the corresponding Wikipedia articles.
  const maps = [
    "https://upload.wikimedia.org/.../720px-Albert_Park_Circuit_2021.svg.png",
    "https://upload.wikimedia.org/.../720px-Sepang.svg.png",
    "https://upload.wikimedia.org/.../720px-Zandvoort_Circuit.png",
    "https://upload.wikimedia.org/.../Autodromo_Nazionale_Monza_circuit_logo.png?utm_source=en.wikipedia.org"
  ]
  const photos = [
    "https://upload.wikimedia.org/.../330px-FIA_F1_Austria_2026_Nr._12_Antonelli_%283%29.jpg",
    "https://upload.wikimedia.org/.../330px-Lewis_Hamilton_2024.jpg",
    "https://upload.wikimedia.org/.../podium.jpeg"
  ]
  for (const url of maps) assert(F1Model.looksLikeTrackMap(url), `rejected a map: ${url}`)
  for (const url of photos) assert(!F1Model.looksLikeTrackMap(url), `accepted a photo: ${url}`)
  equal(F1Model.looksLikeTrackMap(""), false)
  equal(F1Model.looksLikeTrackMap(null), false)
})

check("a circuit's Wikipedia title comes from the URL the API supplies", () => {
  equal(F1Model.wikiTitleFromUrl("https://en.wikipedia.org/wiki/Albert_Park_Circuit"), "Albert_Park_Circuit")
  equal(F1Model.wikiTitleFromUrl("http://en.wikipedia.org/wiki/Circuit_de_Spa-Francorchamps#Layout"), "Circuit_de_Spa-Francorchamps")
  equal(F1Model.wikiTitleFromUrl(""), "")
  equal(F1Model.wikiTitleFromUrl(null), "")
})

// ---------------------------------------------------------------- live timing

const liveDrivers = F1Live.parseDrivers(fixture("openf1-drivers.json"))
const livePits = F1Live.parsePits(fixture("openf1-pit.json"))
const positionRaw = fixture("openf1-position.json")

check("the live driver list parses with team identity", () => {
  const numbers = Object.keys(liveDrivers)
  assert(numbers.length > 0, "no live drivers")
  for (const key of numbers) {
    assert(liveDrivers[key].acronym !== "", "driver with no abbreviation")
    assert(liveDrivers[key].teamName !== "", "driver with no team name")
  }
})

check("an append-only feed collapses to one row per driver, latest wins", () => {
  const rows = [
    { driver_number: 1, position: 3, date: "2026-08-23T13:00:00+00:00" },
    { driver_number: 1, position: 1, date: "2026-08-23T14:00:00+00:00" },
    // Delivered out of order: must not roll the state backwards.
    { driver_number: 1, position: 9, date: "2026-08-23T13:30:00+00:00" },
    { driver_number: 4, position: 2, date: "2026-08-23T14:00:00+00:00" }
  ]
  const latest = F1Live.latestPerDriver(rows)
  equal(Object.keys(latest).length, 2)
  equal(latest["1"].position, 1)
})

check("accumulated state keeps drivers a narrow window left out", () => {
  // A driver who changed position early and then held station appears in the
  // first window and in no later one. Rebuilding from the latest window alone
  // would drop them; merging must not.
  const early = JSON.stringify([
    { driver_number: 1, position: 1, date: "2026-08-23T13:10:00+00:00" },
    { driver_number: 4, position: 2, date: "2026-08-23T13:10:00+00:00" }
  ])
  const later = JSON.stringify([{ driver_number: 4, position: 3, date: "2026-08-23T14:00:00+00:00" }])

  let state = F1Live.mergeLatest({}, early)
  equal(Object.keys(state).length, 2)
  state = F1Live.mergeLatest(state, later)
  equal(Object.keys(state).length, 2, "a driver absent from the newer window was dropped")
  equal(state["1"].position, 1, "the held-station driver lost their position")
  equal(state["4"].position, 3, "the moving driver did not advance")

  // An empty poll must leave the accumulated state untouched.
  state = F1Live.mergeLatest(state, "[]")
  equal(Object.keys(state).length, 2)
  state = F1Live.mergeLatest(state, "garbage")
  equal(Object.keys(state).length, 2)
})

check("merging never rolls state backwards on out-of-order delivery", () => {
  let state = F1Live.mergeLatest({}, JSON.stringify([
    { driver_number: 1, position: 1, date: "2026-08-23T14:00:00+00:00" }
  ]))
  state = F1Live.mergeLatest(state, JSON.stringify([
    { driver_number: 1, position: 8, date: "2026-08-23T13:00:00+00:00" }
  ]))
  equal(state["1"].position, 1)
})

check("the grid rebuilds with names once a late roster arrives", () => {
  const positions = F1Live.mergeLatest({}, positionRaw)
  // Positions land first, before the slow poll has fetched the driver list.
  const before = F1Live.buildGrid({}, positions, {}, {})
  assert(before.length > 0, "empty grid")
  assert(before[0].acronym.charAt(0) === "#", "expected a placeholder before the roster lands")
  // The roster arrives on the next slow poll; the same state must now render names.
  const after = F1Live.buildGrid(liveDrivers, positions, {}, {})
  equal(after.length, before.length)
  assert(after[0].acronym.charAt(0) !== "#", "roster did not reach the grid")
  assert(after[0].teamName !== "", "team name did not reach the grid")
})

check("the live grid builds in position order from the real feed", () => {
  const grid = F1Live.buildGrid(liveDrivers, F1Live.mergeLatest({}, positionRaw), {}, livePits)
  assert(grid.length > 0, "empty grid")
  equal(grid[0].position, 1)
  for (let i = 1; i < grid.length; i++) assert(grid[i].position > grid[i - 1].position, "grid out of order")
  for (const row of grid) {
    assert(row.acronym !== "", "grid row with no abbreviation")
    assert(row.interval.text !== "", "grid row with no interval text")
  }
})

check("gaps render for numbers, lapped cars, the leader, and missing data", () => {
  equal(F1Live.formatGap(1.842, false).text, "+1.842")
  equal(F1Live.formatGap("1.842", false).text, "+1.842")
  equal(F1Live.formatGap(0, true).text, "LEADER")
  equal(F1Live.formatGap("+2 LAPS", false).text, "+2 LAPS")
  equal(F1Live.formatGap(null, false).text, "—")
  equal(F1Live.formatGap(null, false).known, false)
  equal(F1Live.formatGap(undefined, false).known, false)
})

check("a driver missing from one feed still renders a row", () => {
  const positions = F1Live.mergeLatest({}, JSON.stringify([
    { driver_number: 99, position: 1, date: "2026-08-23T14:00:00+00:00" }
  ]))
  const grid = F1Live.buildGrid({}, positions, {}, {})
  equal(grid.length, 1)
  equal(grid[0].acronym, "#99")
  equal(grid[0].interval.text, "LEADER")
})

check("pit stops are tallied per driver", () => {
  const keys = Object.keys(livePits)
  assert(keys.length > 0, "no pit stops parsed")
  for (const key of keys) assert(livePits[key].count >= 1, "driver with zero-count pit entry")
})

check("the current lap only ever advances", () => {
  const laps = JSON.stringify([{ lap_number: 40 }, { lap_number: 42 }, { lap_number: 41 }])
  equal(F1Live.currentLap(laps, 0), 42)
  equal(F1Live.currentLap("[]", 42), 42, "a poll with no new laps must not reset the counter")
  equal(F1Live.currentLap("garbage", 42), 42)
  equal(F1Live.currentLap("[]", 0), null)
})

check("race control resolves to a textual session status", () => {
  const status = F1Live.sessionStatus(fixture("openf1-race-control.json"))
  assert(status.label !== "", "no status label")
  equal(F1Live.sessionStatus('[{"category":"Flag","scope":"Track","flag":"RED","date":"2026-08-23T14:00:00+00:00"}]').label, "RED FLAG")
  equal(F1Live.sessionStatus('[{"category":"SafetyCar","message":"SAFETY CAR DEPLOYED","date":"2026-08-23T14:00:00+00:00"}]').label, "SAFETY CAR")
  equal(F1Live.sessionStatus('[{"category":"SafetyCar","message":"VIRTUAL SAFETY CAR DEPLOYED","date":"2026-08-23T14:00:00+00:00"}]').label, "VIRTUAL SAFETY CAR")
  equal(F1Live.sessionStatus("[]").label, "RUNNING")
  equal(F1Live.sessionStatus("not json").label, "RUNNING")
})

check("every live feed tolerates a truncated response", () => {
  const truncated = positionRaw.slice(0, 400)
  equal(F1Live.safeRows(truncated).length, 0)
  equal(Object.keys(F1Live.mergeLatest({}, truncated)).length, 0)
  equal(F1Live.buildGrid(liveDrivers, F1Live.mergeLatest({}, truncated), {}, {}).length, 0)
  equal(Object.keys(F1Live.parseDrivers(truncated)).length, 0)
})

// -------------------------------------------------------------------- liveries

check("known constructors get their livery colour", () => {
  equal(F1Teams.colorFor("ferrari", "Ferrari", ""), "#e8002d")
  equal(F1Teams.colorFor("", "Red Bull Racing", ""), F1Teams.TEAM_COLORS["red_bull"])
})

check("a live team colour overrides the local table", () => {
  equal(F1Teams.colorFor("mclaren", "McLaren", "F47600"), "#f47600")
  equal(F1Teams.colorFor("mclaren", "McLaren", "#F47600"), "#f47600")
  equal(F1Teams.colorFor("mclaren", "McLaren", "nonsense"), F1Teams.TEAM_COLORS["mclaren"])
})

check("an unknown constructor gets a stable derived colour", () => {
  const first = F1Teams.colorFor("brand_new_team", "Brand New Team", "")
  equal(first, F1Teams.colorFor("brand_new_team", "Brand New Team", ""))
  assert(/^#[0-9a-f]{6}$/.test(first), `not a hex colour: ${first}`)
  assert(first !== F1Teams.colorFor("another_team", "Another Team", ""), "two teams collided")
})

check("every constructor in the live standings resolves to a colour", () => {
  for (const team of constructors) {
    const colour = F1Teams.colorFor(team.constructorId, team.constructorName, "")
    assert(/^#[0-9a-f]{6}$/i.test(colour), `${team.constructorName} -> ${colour}`)
  }
})

// --------------------------------------------------------------------- report

console.log(`\n${passed} passed, ${failures.length} failed`)
for (const failure of failures) console.log(`  FAIL  ${failure}`)
process.exit(failures.length === 0 ? 0 : 1)
