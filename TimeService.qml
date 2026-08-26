import QtQuick
import Quickshell
import Quickshell.Io
import "F1Time.js" as F1Time

// Owns "what time is it, and what zone is this laptop in right now".
//
// Two jobs:
//
//   `now` — a single ticking clock for the whole plugin. Every countdown,
//   every session state, every freshness label reads this one property, so
//   the panel repaints once per tick instead of once per component, and a
//   closed panel costs one wakeup every 15s instead of one per second.
//
//   `correctionMs` / `zoneId` — the laptop's live IANA zone. The QML engine
//   caches the system zone when it starts, so a zone change mid-session
//   (travel, `timedatectl set-timezone`) would otherwise keep printing the
//   old wall clock forever. Asking the OS for its current UTC offset and
//   diffing it against the engine's gives F1Time the correction it needs,
//   and `revision` ticks so every binding that formats a time re-evaluates.
QtObject {
  id: root

  // Poll fast enough for a seconds-resolution countdown only when something
  // is actually showing one.
  property bool fastTick: false

  property double now: Date.now()
  property string zoneId: ""
  property string zoneAbbrev: ""
  property int correctionMs: 0

  // Bumped whenever the zone or its offset changes. Formatting bindings
  // depend on it so they recompute on a zone change even though the instant
  // they format did not move.
  property int revision: 0

  readonly property var context: ({
    correctionMs: root.correctionMs,
    hour12: root.hour12,
    // Unused by the formatters, present so `context` itself changes identity
    // on a zone change and every binding reading it re-evaluates.
    revision: root.revision
  })

  property bool hour12: false

  // Human-readable zone for the panel footer, e.g. "Asia/Kathmandu +0545".
  readonly property string zoneLabel: {
    var id = zoneId || "local time"
    return offsetText === "" ? id : id + " " + offsetText
  }
  property string offsetText: ""

  function refreshZone() {
    if (!zoneProc.running) zoneProc.running = true
  }

  function applyZone(raw) {
    var lines = String(raw || "").split("\n")
    var offset = String(lines[0] || "").replace(/^\s+|\s+$/g, "")   // +0545
    var abbrev = String(lines[1] || "").replace(/^\s+|\s+$/g, "")   // +0545 or CEST
    var id = String(lines[2] || "").replace(/^\s+|\s+$/g, "")       // Asia/Kathmandu

    var match = offset.match(/^([+-])(\d{2})(\d{2})$/)
    if (!match) return

    var sign = match[1] === "-" ? -1 : 1
    var osOffsetMinutes = sign * (parseInt(match[2], 10) * 60 + parseInt(match[3], 10))
    // getTimezoneOffset() is minutes to ADD to local to reach UTC, i.e. the
    // negation of the usual "UTC+05:45" reading.
    var engineOffsetMinutes = -new Date().getTimezoneOffset()
    var nextCorrection = (osOffsetMinutes - engineOffsetMinutes) * 60000

    var changed = (nextCorrection !== root.correctionMs) || (id !== "" && id !== root.zoneId)
    root.correctionMs = nextCorrection
    root.offsetText = offset
    if (abbrev !== "") root.zoneAbbrev = abbrev
    if (id !== "") root.zoneId = id
    if (changed) root.revision = root.revision + 1
  }

  property Process zoneProc: Process {
    id: zoneProc
    command: ["sh", "-c",
      "date +%z; date +%Z; (timedatectl show -p Timezone --value 2>/dev/null || readlink -f /etc/localtime | sed 's|.*/zoneinfo/||')"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyZone(text)
    }
  }

  property Timer tick: Timer {
    interval: root.fastTick ? 1000 : 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.now = Date.now()
  }

  // A suspend/resume or a `timedatectl` change is not something we get an
  // event for, so re-ask the OS periodically. Cheap: one tiny subprocess
  // every five minutes. The panel also calls refreshZone() when it opens.
  property Timer zonePoll: Timer {
    interval: 300000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshZone()
  }

  // A tick that jumps far more than the interval means the machine was
  // suspended; the zone may well have changed while it slept.
  onNowChanged: {
    if (_lastNow > 0 && now - _lastNow > 120000) refreshZone()
    _lastNow = now
  }
  property double _lastNow: 0
}
