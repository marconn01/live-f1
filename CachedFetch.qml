import QtQuick
import Quickshell
import Quickshell.Io

// One network resource, cached on disk, with offline fallback.
//
// Every fetch in the plugin goes through this component, so caching, staleness,
// retry, and TTL behave identically for the calendar, the standings, the
// results, and the circuit metadata rather than being reinvented per call site.
//
// The whole read-through cache is one small shell pipeline, which keeps the
// atomic write (download to .tmp, rename into place) and the "serve what we
// have when the network is down" fallback in a single step:
//
//   CACHE  the file on disk is younger than ttlSeconds — no request was made
//   FRESH  the network answered and the cache was replaced
//   STALE  the request failed; the previous cached copy is being served
//   MISS   the request failed and there is nothing cached to fall back on
//
// A STALE result still emits its payload. That is the point: a flaky network
// or a rate-limited API degrades the panel to "last known good, labelled as
// such" instead of to an empty box.
QtObject {
  id: root

  // Cache file name (without extension) under ~/.cache/omarchy/f1.
  property string name: ""
  property string url: ""
  property int ttlSeconds: 900
  property int timeoutSeconds: 15
  property int maxRetries: 3
  property int retryDelayMs: 4000

  // "idle" | "loading" | "ok" | "stale" | "empty"
  property string status: "idle"
  property bool loading: false
  property bool everLoaded: false
  property double lastSuccessAt: 0
  property string lastError: ""
  property int retries: 0

  readonly property bool isStale: status === "stale"

  signal payload(string text, bool fresh, double fetchedAt)
  signal failed(string reason)

  // `force: true` ignores the TTL — used by the manual refresh binding and
  // whenever the panel opens onto data that may have aged out.
  function fetch(force) {
    if (root.url === "" || root.name === "") return
    if (fetchProc.running) return
    root.loading = true
    if (root.status === "idle") root.status = "loading"
    fetchProc.command = ["sh", "-c", root.script, "omarchy-f1",
      root.name, root.url,
      String(root.timeoutSeconds),
      String(force === true ? 0 : Math.max(0, root.ttlSeconds))]
    fetchProc.running = true
  }

  function invalidate() {
    root.status = "idle"
    root.retries = 0
  }

  readonly property string script:
    'set -u\n' +
    'dir="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/f1"\n' +
    'mkdir -p "$dir" || exit 1\n' +
    'file="$dir/$1.json"\n' +
    'url="$2"; timeout="$3"; ttl="$4"\n' +
    'if [ -f "$file" ] && [ "$ttl" -gt 0 ]; then\n' +
    '  age=$(( $(date +%s) - $(stat -c %Y "$file") ))\n' +
    '  if [ "$age" -lt "$ttl" ]; then\n' +
    '    printf "CACHE %s\\n" "$(stat -c %Y "$file")"\n' +
    '    cat "$file"\n' +
    '    exit 0\n' +
    '  fi\n' +
    'fi\n' +
    'status=STALE\n' +
    'if curl -fsSL --max-time "$timeout" -H "User-Agent: omarchy-f1-plugin/1.0" "$url" -o "$file.part" 2>/dev/null && [ -s "$file.part" ]; then\n' +
    '  mv -f "$file.part" "$file" && status=FRESH\n' +
    'else\n' +
    '  rm -f "$file.part"\n' +
    'fi\n' +
    'if [ ! -f "$file" ]; then\n' +
    '  printf "MISS 0\\n"\n' +
    '  exit 0\n' +
    'fi\n' +
    'printf "%s %s\\n" "$status" "$(stat -c %Y "$file")"\n' +
    'cat "$file"\n'

  function handle(raw) {
    root.loading = false

    var text = String(raw || "")
    var split = text.indexOf("\n")
    if (split < 0) {
      root.status = root.everLoaded ? "stale" : "empty"
      root.lastError = "no response from cache pipeline"
      root.failed(root.lastError)
      scheduleRetry()
      return
    }

    var header = text.slice(0, split).replace(/^\s+|\s+$/g, "").split(" ")
    var body = text.slice(split + 1)
    var kind = header[0] || "MISS"
    // stat reports seconds; the rest of the plugin speaks milliseconds.
    var fetchedAt = (parseInt(header[1], 10) || 0) * 1000

    if (kind === "MISS") {
      root.status = "empty"
      root.lastError = "no data and no cache"
      root.failed(root.lastError)
      scheduleRetry()
      return
    }

    root.everLoaded = true
    if (fetchedAt > 0) root.lastSuccessAt = fetchedAt

    if (kind === "STALE") {
      root.status = "stale"
      root.lastError = "network unavailable — serving cached data"
      root.payload(body, false, fetchedAt)
      scheduleRetry()
      return
    }

    root.status = "ok"
    root.lastError = ""
    root.retries = 0
    root.payload(body, kind === "FRESH", fetchedAt)
  }

  // Back off on repeated failure instead of hammering an API that is down or
  // rate-limiting us. Once the budget is spent the periodic refresh timer in
  // the owning service is the only thing that tries again.
  function scheduleRetry() {
    if (root.retries >= root.maxRetries) return
    root.retries = root.retries + 1
    retryTimer.interval = root.retryDelayMs * root.retries
    retryTimer.restart()
  }

  property Timer retryTimer: Timer {
    id: retryTimer
    repeat: false
    onTriggered: root.fetch(true)
  }

  property Process fetchProc: Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handle(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.loading) {
        root.loading = false
        root.status = root.everLoaded ? "stale" : "empty"
        root.failed("cache pipeline exited " + exitCode)
        root.scheduleRetry()
      }
    }
  }
}
