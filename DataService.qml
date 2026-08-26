import QtQuick
import "F1Model.js" as F1Model
import "F1Time.js" as F1Time

// Everything the dashboard shows except live timing.
//
// The UI never touches an API or a cache file: it binds to the properties
// here, which are always in one of the states the panel knows how to draw
// (loading / loaded / stale / empty). Swapping data providers means rewriting
// this file and nothing else — the parsers it calls are already isolated in
// F1Model.js, and the fetch/cache mechanics in CachedFetch.qml.
//
// Sources, both free, public, and key-less:
//   Jolpica-F1 (the maintained Ergast successor) — calendar, driver
//     standings, qualifying classifications, race distance.
//   OpenF1 — exact session start/end times and the session keys that address
//     the live feed.
//
// Refresh cadence is per-resource, because the data ages at wildly different
// rates: a season calendar changes a few times a year, standings change a few
// times a season, a live race changes every second (which LiveService owns).
QtObject {
  id: root

  property double now: Date.now()
  property int refreshMinutes: 15
  // Pinned below the top five when they are not in it.
  property string highlightDriver: "Verstappen"

  // ------------------------------------------------------------ raw state

  property var races: []
  property var openF1Sessions: []
  property var driverStandings: []
  property var qualifying: null
  property int knownRaceDistance: 0

  property string season: ""
  property bool seasonRolledOver: false

  // ------------------------------------------------------------ derived

  readonly property int currentIndex: F1Model.currentRaceIndex(races, now)

  // The race the dashboard is about, with OpenF1's exact session times folded
  // in. Recomputed whenever either source changes; null off-season.
  readonly property var race: currentIndex >= 0
    ? F1Model.refineRace(races[currentIndex], openF1Sessions)
    : null

  readonly property var upcoming: F1Model.upcomingRaces(races, currentIndex, 3)
  readonly property var weekend: F1Model.weekendState(race, now)
  readonly property var liveSession: race ? F1Model.liveSession(race, now) : null
  readonly property var raceSession: race ? F1Model.sessionByKey(race, "race") : null
  readonly property var qualiSession: race ? F1Model.sessionByKey(race, "quali") : null

  readonly property var standingsView: F1Model.standingsWithPin(driverStandings, 5, highlightDriver)

  // Qualifying is only worth showing once it has actually happened, and only
  // for the race being displayed — a stale grid from a previous round would be
  // worse than none.
  readonly property bool qualifyingAvailable: qualifying !== null
    && race !== null
    && qualifying.round === race.round
    && qualifying.positions.length > 0

  readonly property bool offSeason: races.length > 0 && currentIndex < 0

  // ------------------------------------------------------------ health

  // Any source serving from a cache it could not refresh puts the whole panel
  // into its "stale" presentation, with the age of the newest good data.
  readonly property bool stale: calendar.isStale || standings.isStale
  readonly property bool loaded: races.length > 0
  readonly property bool failed: !loaded && (calendar.status === "empty" || calendar.status === "stale")
  readonly property double lastUpdatedAt: Math.max(calendar.lastSuccessAt, standings.lastSuccessAt)

  readonly property string ergastBase: "https://api.jolpi.ca/ergast/f1"
  // Rolled forward from the season field of a calendar the API sent us, so it
  // is kept to digits: it lands in both a request path and a cache file name.
  readonly property string seasonPath: /^[0-9]{4}$/.test(season) ? season : "current"

  // ------------------------------------------------------------ control

  function refresh(force) {
    calendar.fetch(force)
    sessions.fetch(force)
    standings.fetch(force)
    refreshQualifying(force)
    refreshRaceDistance(force)
  }

  // Only ask for a qualifying classification once qualifying has run. Before
  // that the endpoint answers with an empty race list, and asking repeatedly
  // is just noise against a rate-limited API.
  function refreshQualifying(force) {
    if (!race || !qualiSession) return
    if (F1Model.sessionState(qualiSession, now) !== "done") return
    qualifyingFetch.fetch(force)
  }

  // OpenF1 publishes no scheduled race distance, so the live view's "LAP 42 /
  // 57" total comes from the most recent running of this same circuit. Cached
  // for a month: it is effectively a constant per circuit.
  function refreshRaceDistance(force) {
    if (!race || race.circuitId === "") return
    raceDistance.fetch(force)
  }

  // ------------------------------------------------------------ sources

  property CachedFetch calendar: CachedFetch {
    id: calendar
    name: "calendar-" + root.seasonPath
    url: root.ergastBase + "/" + root.seasonPath + "/races/?format=json&limit=100"
    ttlSeconds: 12 * 3600
    onPayload: function(text) {
      var parsed = F1Model.parseRaces(text)
      if (parsed.length === 0) return
      root.races = parsed

      // The season ended: roll forward to next year's calendar so the panel
      // shows the season opener instead of an empty dashboard. Done once, and
      // only when this year's calendar really is exhausted.
      if (!root.seasonRolledOver && F1Model.currentRaceIndex(parsed, root.now) < 0) {
        root.seasonRolledOver = true
        var lastRace = parsed[parsed.length - 1]
        var nextSeason = parseInt(lastRace.season, 10) + 1
        if (isFinite(nextSeason)) {
          root.season = String(nextSeason)
          Qt.callLater(function() { root.refresh(true) })
        }
      }
    }
  }

  property CachedFetch sessions: CachedFetch {
    id: sessions
    name: "openf1-sessions-" + root.sessionsYear
    url: "https://api.openf1.org/v1/sessions?year=" + root.sessionsYear
    ttlSeconds: 6 * 3600
    onPayload: function(text) {
      var parsed = F1Model.parseOpenF1Sessions(text)
      if (parsed.length > 0) root.openF1Sessions = parsed
    }
  }

  readonly property int sessionsYear: {
    if (races.length > 0) {
      var y = parseInt(races[0].season, 10)
      if (isFinite(y)) return y
    }
    return new Date(now).getUTCFullYear()
  }

  property CachedFetch standings: CachedFetch {
    id: standings
    name: "driver-standings-" + root.seasonPath
    url: root.ergastBase + "/" + root.seasonPath + "/driverstandings/?format=json&limit=100"
    ttlSeconds: Math.max(300, root.refreshMinutes * 60)
    onPayload: function(text) {
      var parsed = F1Model.parseDriverStandings(text)
      if (parsed.length > 0) root.driverStandings = parsed
    }
  }

  property CachedFetch qualifyingFetch: CachedFetch {
    id: qualifyingFetch
    name: "qualifying-" + root.seasonPath + "-" + (root.race ? root.race.round : 0)
    url: root.race
      ? root.ergastBase + "/" + root.seasonPath + "/"
        + encodeURIComponent(root.race.round) + "/qualifying/?format=json"
      : ""
    ttlSeconds: 900
    onPayload: function(text) {
      var parsed = F1Model.parseQualifying(text)
      if (parsed && parsed.positions.length > 0) root.qualifying = parsed
    }
  }

  property CachedFetch raceDistance: CachedFetch {
    id: raceDistance
    name: "distance-" + (root.race ? root.race.circuitId : "none")
    url: root.race && root.race.circuitId !== ""
      // Every winning result ever recorded at this circuit, oldest first; the
      // last row is the most recent running and therefore the current distance.
      ? root.ergastBase + "/circuits/" + encodeURIComponent(root.race.circuitId)
        + "/results/1/?format=json&limit=100"
      : ""
    ttlSeconds: 30 * 86400
    onPayload: function(text) {
      var data = F1Model.safeParse(text)
      if (!data) return
      var list = data.MRData && data.MRData.RaceTable ? data.MRData.RaceTable.Races : null
      if (!Array.isArray(list) || list.length === 0) return
      // Most recent running of this circuit wins.
      var winner = list[list.length - 1].Results
      if (!Array.isArray(winner) || winner.length === 0) return
      var laps = parseInt(winner[0].laps, 10)
      if (isFinite(laps) && laps > 0) root.knownRaceDistance = laps
    }
  }

  // ------------------------------------------------------------ scheduling

  // Standings are re-checked on the user's interval; the calendar and the
  // OpenF1 session list ride their own much longer TTLs, so calling fetch() on
  // them here is nearly always a no-op that returns the cache.
  property Timer refreshTimer: Timer {
    interval: Math.max(300, root.refreshMinutes * 60) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  // A session boundary is the one moment the slow-moving data is guaranteed to
  // be wrong: qualifying has just produced a grid, or a race has just moved
  // the championship. Watch for the transition and pull once, rather than
  // polling hard all weekend for a change that happens twice.
  property string lastWeekendKind: ""
  onWeekendChanged: {
    var kind = weekend ? weekend.kind : ""
    if (kind === lastWeekendKind) return
    var previous = lastWeekendKind
    lastWeekendKind = kind
    if (previous === "") return

    if (kind === "finished") {
      standings.invalidate()
      Qt.callLater(function() { standings.fetch(true) })
    } else if (previous === "live") {
      qualifyingFetch.invalidate()
      Qt.callLater(function() { root.refreshQualifying(true) })
    }
  }

  onRaceChanged: {
    if (race) Qt.callLater(function() {
      root.refreshQualifying(false)
      root.refreshRaceDistance(false)
    })
  }
}
