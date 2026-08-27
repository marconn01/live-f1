import QtQuick
import Quickshell
import Quickshell.Io
import "F1Live.js" as F1Live
import "F1Model.js" as F1Model
import "F1Time.js" as F1Time

// Live timing, from OpenF1.
//
// Polling discipline, because this is the only part of the plugin that talks to
// a network on a seconds cadence:
//
//   * Nothing is polled unless live mode is on AND a session is actually
//     running. Turning the toggle off, or the chequered flag, stops every
//     timer dead — there is no idle background polling.
//   * Each tick is ONE subprocess, not one per endpoint. The fast tick batches
//     the two feeds that change every second (positions, intervals); a slow
//     tick every minute batches the four that do not (driver list, pit stops,
//     race control, lap count).
//   * Requests are windowed with `date>=`. OpenF1 endpoints are append-only
//     logs — an unwindowed intervals query for a finished race returns tens of
//     thousands of rows. Asking only for the last few minutes keeps a tick at a
//     few hundred rows regardless of how long the race has been running.
QtObject {
  id: root

  property double now: Date.now()
  property bool enabled: false
  property int refreshSeconds: 12

  // The session the schedule says is running right now, from DataService.
  property var scheduledSession: null
  // Scheduled race distance, for "LAP 42 / 57".
  property int totalLaps: 0

  // ------------------------------------------------------------ state

  property var driversByNumber: ({})
  property var pitsByDriver: ({})
  // Accumulated feed state, keyed by driver number. Rebuilt into `grid`
  // whenever any feed lands.
  property var positionState: ({})
  property var intervalState: ({})
  property var grid: []
  property var status: ({ label: "RUNNING", kind: "green", messageAt: null })
  property int currentLap: 0
  property double lastUpdateAt: 0
  property double lastPollAt: 0
  property bool polling: false
  property string lastError: ""
  property int consecutiveFailures: 0

  // OpenF1's own view of what is running, used as a backstop when a session
  // over- or under-runs its published schedule.
  property var probedSession: null

  readonly property var probeIsRunning: {
    if (!probedSession) return false
    var startAt = probedSession.startAt
    var endAt = probedSession.endAt
    if (!F1Time.isInstant(startAt)) return false
    // Allow a session to run half an hour past its published end — red flags
    // and long safety-car periods routinely push a race over.
    var until = F1Time.isInstant(endAt) ? endAt + 30 * F1Time.MINUTE : startAt + 3 * F1Time.HOUR
    return now >= startAt && now <= until
  }

  readonly property int activeSessionKey: {
    if (scheduledSession && scheduledSession.sessionKey > 0) return scheduledSession.sessionKey
    if (probeIsRunning && probedSession.sessionKey > 0) return probedSession.sessionKey
    return -1
  }

  readonly property bool hasLiveSession: activeSessionKey > 0
  readonly property bool polls: enabled && hasLiveSession
  readonly property bool hasData: grid.length > 0

  readonly property string sessionName: {
    if (scheduledSession) return scheduledSession.name
    if (probeIsRunning) return probedSession.name
    return ""
  }

  // Freshness, straight from the newest timestamp in the feed rather than from
  // when we happened to ask — a stalled feed must read as stalled.
  readonly property double dataAge: lastUpdateAt > 0 ? Math.max(0, now - lastUpdateAt) : -1
  readonly property bool delayed: dataAge > Math.max(30000, refreshSeconds * 3000)

  // ------------------------------------------------------------ helpers

  // The instant each poll's window is measured back from.
  property double windowEnd: root.now

  function isoAt(millis) {
    return new Date(millis).toISOString().slice(0, 19)
  }

  function windowFrom(millisAgo) {
    return isoAt(root.windowEnd - millisAgo)
  }

  // Windows are bounded at BOTH ends. `date>=` alone is only a lower bound, so
  // a feed that has run on past the moment we asked about — a session still
  // publishing after a long red flag, or any request against a session that
  // has already finished — answers with everything from that point to the end
  // of the session. Measured on a completed race, an open-ended 15-second
  // window returned 450KB where the bounded one returns 10KB.
  function windowTo() {
    return isoAt(root.windowEnd + 1000)
  }

  function endpoint(path, query) {
    return "https://api.openf1.org/v1/" + path + "?session_key=" + root.activeSessionKey + (query || "")
  }

  // Splits the batched response back into its per-endpoint bodies.
  function section(text, name) {
    var marker = "===" + name + "===\n"
    var start = String(text || "").indexOf(marker)
    if (start < 0) return ""
    start += marker.length
    var end = String(text).indexOf("\n===", start)
    return end < 0 ? String(text).slice(start) : String(text).slice(start, end)
  }

  function reset() {
    grid = []
    driversByNumber = ({})
    pitsByDriver = ({})
    positionState = ({})
    intervalState = ({})
    currentLap = 0
    lastUpdateAt = 0
    status = ({ label: "RUNNING", kind: "green", messageAt: null })
    consecutiveFailures = 0
    lastError = ""
  }

  function refreshNow() {
    if (!polls) return
    pollFast()
    pollSlow()
  }

  function pollFast() {
    if (!polls || fastProc.running) return
    root.polling = true
    // Positions change rarely, so a wide window costs almost nothing and
    // repopulates the tower quickly after live mode is switched on. Intervals
    // update several times a second per car, so that window is kept just wider
    // than the poll cadence — accumulated state covers the rest.
    var intervalWindow = Math.max(20, root.refreshSeconds * 2 + 5) * 1000
    fastProc.command = ["sh", "-c", root.batchScript, "omarchy-f1-live",
      String(root.maxBytes),
      "position=" + endpoint("position", "&date%3E=" + windowFrom(20 * F1Time.MINUTE) + "&date%3C=" + windowTo()),
      "intervals=" + endpoint("intervals", "&date%3E=" + windowFrom(intervalWindow) + "&date%3C=" + windowTo())]
    fastProc.running = true
  }

  function pollSlow() {
    if (!polls || slowProc.running) return
    slowProc.command = ["sh", "-c", root.batchScript, "omarchy-f1-live",
      String(root.maxBytes),
      "drivers=" + endpoint("drivers", ""),
      "pit=" + endpoint("pit", ""),
      "race_control=" + endpoint("race_control", "&date%3E=" + windowFrom(45 * F1Time.MINUTE) + "&date%3C=" + windowTo()),
      "laps=" + endpoint("laps", "&lap_number%3E=" + Math.max(1, root.currentLap))]
    slowProc.running = true
  }

  // Every poll body is read into memory whole by the StdioCollector on the
  // other end of this pipe, so each one is capped. The largest real response
  // is a full race's lap feed, measured at ~640KB; the windowed feeds are tens
  // of kilobytes.
  readonly property int maxBytes: 2097152

  // Fetch each "name=url" argument in turn, printing a marker before each body.
  // One process, one set of TLS handshakes, one exit to handle.
  //
  // Each body is spooled through a hard byte cap into an unlinked temporary
  // file, so a response is bounded on disk as well as in memory and never
  // exists under a name anything else can reach. The details are inline below.
  readonly property string batchScript:
    'set -u\n' +
    'export LC_ALL=C\n' +
    'max=$1; shift\n' +
    'for spec in "$@"; do\n' +
    '  name=${spec%%=*}\n' +
    '  url=${spec#*=}\n' +
    '  printf "===%s===\\n" "$name"\n' +
    // The response body never exists under a name anything else can reach.
    // The temporary file is opened for reading and for writing, its identity
    // is confirmed against the name that created it, and then the name is
    // unlinked: from here the body is two descriptors and nothing more, so
    // there is no path left for another process to pre-plant, swap for a
    // symlink or a fifo, or point at a file of its choosing.
    '  tmp=$(mktemp) || exit 1\n' +
    '  exec 5< "$tmp" 4> "$tmp"\n' +
    '  ok=0\n' +
    '  if [ -f /proc/self/fd/5 ] \\\n' +
    '     && [ "$(stat -Lc %d:%i /proc/self/fd/5)" = "$(stat -c %d:%i "$tmp")" ]; then\n' +
    '    ok=1\n' +
    '  fi\n' +
    '  rm -f "$tmp"\n' +
    // No -L: these are fixed https endpoints, and a redirect off them is
    // nothing this plugin should follow.
    //
    // head is the hard byte bound. --max-filesize only refuses a length the
    // server declares up front, so a chunked or unlabelled response walks
    // straight past it, and -o would have spooled all of it to disk before
    // anything could measure it; head closes the pipe at the cap instead,
    // which is a bound the far end cannot talk its way around. curl's own
    // exit status leaves on fd 3 — $? after a pipeline belongs to head, and
    // without it a connection dropped mid-body would be indistinguishable
    // from a complete answer.
    '  rc=$({ { curl -fsS --proto "=https" --max-filesize "$max" --max-time 10 \\\n' +
    '               -H "User-Agent: omarchy-f1-plugin/1.0" "$url" -o - 2>/dev/null\n' +
    '           printf "%s" "$?" >&3\n' +
    '         } | head -c "$(( max + 1 ))" >&4\n' +
    '       } 3>&1)\n' +
    '  exec 4>&-\n' +
    // One byte over the cap is how an oversized body is told apart from one
    // that merely fills it; either way the round trip degrades to "[]".
    '  sz=$(stat -Lc %s /proc/self/fd/5)\n' +
    '  if [ "$ok" = 1 ] && [ "${rc:-1}" = 0 ] && [ "${sz:-0}" -le "$max" ]; then\n' +
    '    head -c "$max" <&5\n' +
    '  else\n' +
    '    printf "[]"\n' +
    '  fi\n' +
    '  exec 5<&-\n' +
    '  printf "\\n"\n' +
    'done\n'

  // The probe is a single fixed endpoint, but it is the same story: curl
  // straight into a StdioCollector has no ceiling at all, so it goes through
  // the same hard byte cap. A failed request yields no output, which
  // applyProbe already reads as "nothing known yet".
  readonly property string probeScript:
    'set -u\n' +
    'curl -fsS --proto "=https" --max-filesize "$1" --max-time 8 \\\n' +
    '  -H "User-Agent: omarchy-f1-plugin/1.0" \\\n' +
    '  "https://api.openf1.org/v1/sessions?session_key=latest" 2>/dev/null \\\n' +
    '  | head -c "$1"\n'

  // Rebuild the tower from whatever state has accumulated. Called after every
  // poll of either cadence, so the roster arriving a minute after the first
  // positions still gets names and liveries onto rows already on screen.
  function rebuildGrid() {
    root.grid = F1Live.buildGrid(root.driversByNumber, root.positionState,
                                 root.intervalState, root.pitsByDriver)
  }

  function applyFast(text) {
    root.polling = false
    root.lastPollAt = Date.now()

    root.positionState = F1Live.mergeLatest(root.positionState, section(text, "position"))
    root.intervalState = F1Live.mergeLatest(root.intervalState, section(text, "intervals"))
    rebuildGrid()

    if (root.grid.length === 0) {
      // A window with no rows is normal between laps; only an unbroken run of
      // empty polls means the feed has actually gone away.
      root.consecutiveFailures = root.consecutiveFailures + 1
      if (root.consecutiveFailures >= 3) root.lastError = "no timing data in the last few polls"
      return
    }

    root.consecutiveFailures = 0
    root.lastError = ""
    var freshest = F1Live.freshestUpdate(root.grid, root.lastPollAt)
    if (F1Time.isInstant(freshest)) root.lastUpdateAt = freshest
  }

  function applySlow(text) {
    var drivers = F1Live.parseDrivers(section(text, "drivers"))
    // Keep the previous roster if a poll comes back empty — losing it would
    // strip every name and colour off a grid that is otherwise fine.
    var count = 0
    for (var key in drivers) count++
    if (count > 0) root.driversByNumber = drivers

    var pits = F1Live.parsePits(section(text, "pit"))
    root.pitsByDriver = pits

    var lap = F1Live.currentLap(section(text, "laps"), root.currentLap)
    if (lap !== null) root.currentLap = lap

    var raceControl = section(text, "race_control")
    if (raceControl.replace(/^\s+|\s+$/g, "") !== "" && raceControl.indexOf("[]") !== 0)
      root.status = F1Live.sessionStatus(raceControl)

    // The roster and the pit tallies just changed the meaning of rows already
    // drawn, so redraw them now rather than at the next fast tick.
    rebuildGrid()
  }

  function applyProbe(text) {
    var parsed = F1Model.parseOpenF1Sessions(text)
    root.probedSession = parsed.length > 0 ? parsed[parsed.length - 1] : null
  }

  // ------------------------------------------------------------ processes

  property Process fastProc: Process {
    id: fastProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyFast(text)
    }
    onExited: function(code) {
      root.polling = false
      if (code !== 0) root.lastError = "live feed unreachable"
    }
  }

  property Process slowProc: Process {
    id: slowProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySlow(text)
    }
  }

  property Process probeProc: Process {
    id: probeProc
    command: ["sh", "-c", root.probeScript, "omarchy-f1-live",
      String(root.maxBytes)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyProbe(text)
    }
  }

  // ------------------------------------------------------------ timers

  property Timer fastTimer: Timer {
    interval: Math.max(5, root.refreshSeconds) * 1000
    running: root.polls
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollFast()
  }

  property Timer slowTimer: Timer {
    interval: 60000
    running: root.polls
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollSlow()
  }

  // Runs while live mode is on even with no session running: it is what
  // notices a session that started late or is over-running, and it is one
  // small request a minute.
  property Timer probeTimer: Timer {
    interval: 60000
    running: root.enabled
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!probeProc.running) probeProc.running = true
  }

  // A new session means the old grid is meaningless. Clear rather than let one
  // race's positions bleed into the next session's view.
  onActiveSessionKeyChanged: reset()
  onEnabledChanged: if (!enabled) root.polling = false
}
