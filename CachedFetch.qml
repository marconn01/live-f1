import QtQuick
import Quickshell
import Quickshell.Io
import "OpenF1Auth.js" as OpenF1Auth

// One network resource, cached on disk, with offline fallback.
//
// Every fetch in the plugin goes through this component, so caching, staleness,
// retry, and TTL behave identically for the calendar, the standings, the
// results, and the circuit metadata rather than being reinvented per call site.
//
// The whole read-through cache is one small shell pipeline, which keeps the
// atomic write (download to a private mktemp file, rename into place) and the
// "serve what we have when the network is down" fallback in a single step:
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
      String(force === true ? 0 : Math.max(0, root.ttlSeconds)),
      String(root.maxBytes)]
    fetchProc.running = true
  }

  function invalidate() {
    root.status = "idle"
    root.retries = 0
  }

  // Cap on both the download and the cache read. Every response this plugin
  // asks for is a few hundred kilobytes at most; anything larger is either a
  // wrong endpoint or something hostile, and it would be read into memory
  // whole by the StdioCollector on the other end of this pipe.
  readonly property int maxBytes: 8388608

  readonly property string script:
    'set -u\n' +
    'export LC_ALL=C\n' +
    // The OpenF1 sessions list goes through here too, and it is refused like
    // everything else on that host while a session is running. of1_auth_for
    // decides per URL, so the bearer token reaches OpenF1 and nothing else —
    // this same script also fetches jolpica.
    OpenF1Auth.PRELUDE +
    'dir="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/f1"\n' +
    'mkdir -p "$dir" || exit 1\n' +
    // The cache is this user's alone; nothing else has business in it.
    'chmod 700 "$dir" 2>/dev/null || true\n' +
    'name="$1"; url="$2"; timeout="$3"; ttl="$4"; max="$5"\n' +
    // The cache key carries API-supplied fields (circuit id, round, season),
    // so it is constrained rather than trusted: a value with a slash or a
    // leading dot-dot would otherwise name a file outside the cache dir.
    'case "$name" in\n' +
    '  "" | "." | ".." | *[!A-Za-z0-9._-]*) printf "MISS 0\\n"; exit 0 ;;\n' +
    'esac\n' +
    'file="$dir/$name.json"\n' +
    // serve <file> <status>: emit the header and the body from ONE open
    // descriptor. Everything the decision rests on — is this a regular file,
    // how big is it, when was it modified — is read back off /proc/self/fd,
    // i.e. off the object we actually opened, never off the pathname. A
    // process that swaps the path for a symlink, a fifo, or a huge file after
    // we opened it cannot change what we are already reading, and a swap made
    // before the open is caught by these checks. The timeout is the guard for
    // the one thing a check cannot cover: open() on a fifo blocks until a
    // writer shows up, which would otherwise wedge the widget forever.
    'serve() {\n' +
    "  timeout 10 sh -c '\n" +
    '    exec 2>/dev/null\n' +
    '    f=$1; st=$2; max=$3\n' +
    '    exec 3< "$f" || exit 1\n' +
    '    [ -f /proc/self/fd/3 ] || exit 1\n' +
    // A descriptor remembers the file it opened, not how it was named, so the
    // fd alone cannot say whether the path was a symlink. Comparing it against
    // an lstat of the path recovers that: for a symlink the two identities
    // differ (lstat describes the link, the fd describes its target), and so
    // do they if anything swapped the path after the open. Both cases refuse.
    '    [ "$(stat -Lc %d:%i /proc/self/fd/3)" = "$(stat -c %d:%i "$f")" ] || exit 1\n' +
    '    sz=$(stat -Lc %s /proc/self/fd/3) || exit 1\n' +
    '    [ "$sz" -gt 0 ] || exit 1\n' +
    '    [ "$sz" -le "$max" ] || exit 1\n' +
    '    printf "%s %s\\n" "$st" "$(stat -Lc %Y /proc/self/fd/3)"\n' +
    '    head -c "$max" <&3\n' +
    "  ' sh \"$1\" \"$2\" \"$max\"\n" +
    '}\n' +
    // The age test is only a hint about whether to spend a request; it reads
    // the path, and that is fine because serve re-derives the mtime it
    // reports from the descriptor it actually streams.
    'if [ "$ttl" -gt 0 ] && [ ! -L "$file" ] && [ -f "$file" ]; then\n' +
    '  now=$(date +%s); mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)\n' +
    '  if [ "$(( now - mtime ))" -lt "$ttl" ] && serve "$file" CACHE; then\n' +
    '    exit 0\n' +
    '  fi\n' +
    'fi\n' +
    'status=STALE\n' +
    // mktemp, not "$file.part": a predictable download path in a directory
    // this process does not own exclusively is a file another local process
    // can pre-create, replace, or point elsewhere between our writes.
    'tmp=$(mktemp "$dir/.$name.XXXXXXXX") || exit 1\n' +
    'trap \'rm -f "$tmp"\' EXIT INT TERM\n' +
    // The download is written through a descriptor, never through the name.
    // fd 4 is opened before curl runs and every byte lands in the object
    // behind it; the pathname is touched again only for the rename, and only
    // once the inode it denotes is confirmed to still be the one we wrote.
    'exec 4> "$tmp" || exit 1\n' +
    '[ -f /proc/self/fd/4 ] || exit 1\n' +
    'tmpid=$(stat -Lc %d:%i /proc/self/fd/4) || exit 1\n' +
    '[ "$tmpid" = "$(stat -c %d:%i "$tmp")" ] || exit 1\n' +
    // https only, on the first request and on every redirect, with a bounded
    // hop count — a 30x answer must not be able to walk this fetch onto
    // file://, onto a local address, or around a redirect loop.
    //
    // curl writes to a pipe, not to the file, because --max-filesize only
    // acts on a length the server declares: a chunked or unlabelled response
    // is not stopped by it, and -o would have written the whole thing to disk
    // before any size check could run. head is the hard bound — it closes the
    // pipe after max+1 bytes, so at most that many bytes ever reach local
    // storage no matter what the endpoint sends.
    //
    // curl's own exit status leaves on fd 3, which the command substitution
    // aims back at its own stdout. $? after a pipeline belongs to head, and
    // without curl's status a connection dropped mid-body would look like a
    // complete answer and get cached as truncated JSON.
    'rc=$({ { curl -fsS -L --proto "=https" --proto-redir "=https" --max-redirs 3 \\\n' +
    '             --max-filesize "$max" --max-time "$timeout" \\\n' +
    '             -H "User-Agent: omarchy-f1-plugin/1.0" \\\n' +
    // curl drops a custom Authorization header when a redirect crosses to
    // another host, so following one cannot carry the token off OpenF1.
    '             -H "@$(of1_auth_for "$url")" "$url" -o - 2>/dev/null\n' +
    '         printf "%s" "$?" >&3\n' +
    '       } | head -c "$(( max + 1 ))" >&4\n' +
    '     } 3>&1)\n' +
    // The size is read off the descriptor that was written, before it closes.
    // Reading back one byte over the cap is how an oversized response is told
    // apart from one that merely fills it.
    'sz=$(stat -Lc %s /proc/self/fd/4)\n' +
    'exec 4>&-\n' +
    'if [ "${rc:-1}" = 0 ] && [ "${sz:-0}" -gt 0 ] && [ "$sz" -le "$max" ] \\\n' +
    '   && [ "$tmpid" = "$(stat -c %d:%i "$tmp")" ]; then\n' +
    // rename(2) replaces whatever the target name denotes, a symlink
    // included, and never writes through one.
    '  mv -f "$tmp" "$file" && status=FRESH\n' +
    'fi\n' +
    'rm -f "$tmp"\n' +
    'serve "$file" "$status" || printf "MISS 0\\n"\n'

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
