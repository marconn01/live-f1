import QtQuick
import Quickshell
import Quickshell.Io
import "F1Time.js" as F1Time
import "F1Model.js" as F1Model

// Optional desktop notifications for session starts and finishes.
//
// Scheduling is done entirely in absolute instants and only rendered into
// local wall-clock text at the moment the notification is written, so a
// notification says "Race starts 19:45" in the zone the laptop is in when it
// fires — not the zone it was in when the reminder was scheduled.
//
// De-duplication is persisted. Each notification has a stable key
// (season-round-session-lead), and fired keys are written to
// ~/.local/state/omarchy/f1/notified.json, so restarting the shell — or
// opening and closing the panel all weekend — cannot make it announce the
// same session twice. A slot whose moment passed more than fifteen minutes
// ago is retired unfired, so a laptop waking on Sunday evening does not
// deliver a burst of Friday's reminders.
QtObject {
  id: root

  property double now: Date.now()
  property bool enabled: true
  property var race: null
  property var timeContext: ({ correctionMs: 0, hour12: false })

  // Comma-separated lead times in minutes, e.g. "30,15".
  property string leadMinutes: "30,15"
  // Which session groups to announce: "Race", "Qualifying", "Sprint", "Practice".
  property var sessionGroups: ["Race", "Qualifying", "Sprint"]

  property var fired: ({})
  property bool stateLoaded: false

  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/f1/notified.json"

  readonly property var leads: {
    var out = []
    var parts = String(leadMinutes || "").split(",")
    for (var i = 0; i < parts.length; i++) {
      var n = parseInt(String(parts[i]).replace(/^\s+|\s+$/g, ""), 10)
      if (isFinite(n) && n > 0 && out.indexOf(n) === -1) out.push(n)
    }
    out.sort(function(a, b) { return b - a })
    return out
  }

  function wantsSession(session) {
    if (!session) return false
    return sessionGroups.indexOf(session.group) !== -1
  }

  function keyFor(session, tag) {
    if (!race) return ""
    return race.season + "-" + race.round + "-" + session.key + "-" + tag
  }

  // Every notification this weekend still owes, as { at, key, title, body }.
  // Recomputed on each tick, which is cheap and means a settings change or a
  // rescheduled session takes effect immediately.
  function pendingSlots() {
    var slots = []
    if (!race || !race.sessions) return slots

    for (var i = 0; i < race.sessions.length; i++) {
      var session = race.sessions[i]
      if (!wantsSession(session) || session.dateOnly) continue

      var label = sessionLabel(session)
      for (var l = 0; l < leads.length; l++) {
        var lead = leads[l]
        slots.push({
          at: session.startAt - lead * F1Time.MINUTE,
          key: keyFor(session, "t" + lead),
          title: label + " starts in " + lead + " minutes",
          body: startBody(session)
        })
      }

      slots.push({
        at: session.startAt,
        key: keyFor(session, "start"),
        title: label + " has started",
        body: race.name + " · " + race.circuitName
      })

      if (session.key === "race") {
        slots.push({
          at: session.endAt,
          key: keyFor(session, "finish"),
          title: "Race has finished",
          body: race.name + " · results shortly"
        })
      }
    }
    return slots
  }

  function sessionLabel(session) {
    if (session.key === "race") return "Race"
    if (session.key === "quali") return "Qualifying"
    if (session.key === "sq") return "Sprint qualifying"
    if (session.key === "sprint") return "Sprint"
    return session.name
  }

  function startBody(session) {
    return race.name + " · " + F1Time.formatDayTime(session.startAt, timeContext)
  }

  function tick() {
    if (!enabled || !stateLoaded || !race) return

    var slots = pendingSlots()
    var changed = false

    for (var i = 0; i < slots.length; i++) {
      var slot = slots[i]
      if (slot.key === "" || fired[slot.key]) continue
      if (now < slot.at) continue

      // Too old to be useful — retire it silently so it never fires late.
      var overdue = now - slot.at > 15 * F1Time.MINUTE
      if (!overdue) send(slot.title, slot.body)
      fired[slot.key] = slot.at
      changed = true
    }

    if (changed) persist()
  }

  function send(title, body) {
    notifyProc.command = ["omarchy-notification-send", "--app-name", "Formula 1", String(title), String(body)]
    notifyProc.running = true
  }

  // Keep the persisted set small: anything older than a fortnight belongs to a
  // weekend that is long gone.
  function persist() {
    var kept = {}
    for (var key in fired) {
      if (now - fired[key] < 14 * F1Time.DAY) kept[key] = fired[key]
    }
    fired = kept
    stateFile.setText(JSON.stringify({ version: 1, fired: kept }, null, 2) + "\n")
  }

  function loadState(raw) {
    var parsed = F1Model.safeParse(raw)
    fired = parsed && parsed.fired && typeof parsed.fired === "object" ? parsed.fired : ({})
    stateLoaded = true
  }

  property FileView stateFile: FileView {
    path: root.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("")
  }

  property Process notifyProc: Process {
    id: notifyProc
  }

  // FileView writes the file, not the path to it. Make the state directory
  // once at startup, then load whatever is already there.
  property Process mkdirProc: Process {
    id: mkdirProc
    running: true
    command: ["mkdir", "-p", Quickshell.env("HOME") + "/.local/state/omarchy/f1"]
    onExited: stateFile.reload()
  }

  onNowChanged: tick()
}
