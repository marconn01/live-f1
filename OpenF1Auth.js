.pragma library

// ---------------------------------------------------------------------------
// OpenF1 authentication.
//
// OpenF1 changed policy: while a session is actually running, EVERY endpoint —
// the historical ones included — answers 401 to an unauthenticated caller:
//
//   {"detail":"Live F1 session in progress. Global API access (including past
//    sessions) is restricted to authenticated users until the session ends."}
//
// So the one moment the timing tower exists to cover is the one moment the
// free API refuses to answer, and it refuses with an error this plugin used to
// swallow into an empty grid. Real-time access now needs an OpenF1 account:
// client credentials are exchanged at POST /token for a short-lived bearer
// token (cf. br-g/openf1, src/openf1/util/openf1_client.py).
//
// This is the shell half of that exchange, shared by every process in the
// plugin that talks to OpenF1. It is shell rather than QML for one reason: the
// secret then never enters the QML engine, never lands in the plugin's
// settings file, and never appears in any process's argv — /proc/PID/cmdline
// is world-readable, so a credential passed as an argument is readable by
// every other account on the machine. It goes from a 0600 file, through a
// 0600 file, into curl, and nowhere else: curl's own `@file` forms for both
// --data-urlencode and -H are what make that possible, and they also mean no
// value is ever quoted or escaped on its way through a shell.
//
// Credentials are read from, in order:
//
//   $OPENF1_CLIENT_ID / $OPENF1_CLIENT_SECRET
//   ${XDG_CONFIG_HOME:-~/.config}/omarchy/f1/credentials, as
//       client_id=...
//       client_secret=...
//
// With neither set the prelude is inert: no token request is made, curl runs
// exactly as it did before, and everything outside a live session keeps
// working unauthenticated. That is the common case and it stays free of cost.
// ---------------------------------------------------------------------------

// Defines, for the script that includes it:
//
//   $OPENF1_AUTH        file holding the Authorization header, or /dev/null
//                       when there is nothing to send
//   $OPENF1_AUTH_STATE  "none" | "ok" | "failed" — reported up to the UI so it
//                       can tell "you have not set this up" apart from "your
//                       credentials were rejected"
//   of1_auth_for URL    the header file to use for ONE url: /dev/null for any
//                       host that is not OpenF1, so a token minted for OpenF1
//                       is never handed to jolpica or to a redirect target
var PRELUDE =
  'of1_cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/f1"\n' +
  'of1_state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/f1"\n' +
  'of1_auth_file="$of1_state_dir/openf1.auth"\n' +
  'of1_exp_file="$of1_state_dir/openf1.expires"\n' +
  'OPENF1_AUTH=/dev/null\n' +
  'OPENF1_AUTH_STATE=none\n' +
  'of1_id=""\n' +
  'of1_secret=""\n' +
  'of1_loaded=0\n' +
  '\n' +
  'of1_credentials() {\n' +
  '  of1_id=${OPENF1_CLIENT_ID:-}\n' +
  '  of1_secret=${OPENF1_CLIENT_SECRET:-}\n' +
  '  if [ -z "$of1_id" ] || [ -z "$of1_secret" ]; then\n' +
  '    [ -f "$of1_cfg_dir/credentials" ] && [ ! -L "$of1_cfg_dir/credentials" ] || return 1\n' +
  '    of1_id=$(sed -n "s/^[[:space:]]*client_id[[:space:]]*=[[:space:]]*//p" \\\n' +
  '      "$of1_cfg_dir/credentials" | head -n1)\n' +
  '    of1_secret=$(sed -n "s/^[[:space:]]*client_secret[[:space:]]*=[[:space:]]*//p" \\\n' +
  '      "$of1_cfg_dir/credentials" | head -n1)\n' +
  '  fi\n' +
  '  [ -n "$of1_id" ] && [ -n "$of1_secret" ]\n' +
  '}\n' +
  '\n' +
  // The credentials go to curl in files, so neither the id, the secret, nor
  // the token it buys is ever an argument, and none of them passes through a
  // layer that would need them quoted. Every file is created 0600 in the
  // plugin's own state directory and unlinked as soon as curl has exited.
  'of1_mint() {\n' +
  '  OPENF1_AUTH_STATE=failed\n' +
  '  ( umask 077; mkdir -p "$of1_state_dir" ) 2>/dev/null || return 1\n' +
  '  of1_u=$(umask 077; mktemp "$of1_state_dir/.u.XXXXXXXX") || return 1\n' +
  '  of1_p=$(umask 077; mktemp "$of1_state_dir/.p.XXXXXXXX") || { rm -f "$of1_u"; return 1; }\n' +
  // No trailing newline: --data-urlencode name@file encodes the file whole,
  // and a newline would be encoded into the credential rather than ignored.
  '  printf "%s" "$of1_id" > "$of1_u"\n' +
  '  printf "%s" "$of1_secret" > "$of1_p"\n' +
  '  of1_body=$(curl -fs --proto "=https" --max-time 10 \\\n' +
  '    -H "User-Agent: omarchy-f1-plugin/1.0" \\\n' +
  '    --data-urlencode "username@$of1_u" --data-urlencode "password@$of1_p" \\\n' +
  '    "https://api.openf1.org/token" -o - 2>/dev/null | head -c 8192)\n' +
  '  rm -f "$of1_u" "$of1_p"\n' +
  '  of1_token=$(printf "%s" "$of1_body" \\\n' +
  '    | sed -n \'s/.*"access_token"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p\' \\\n' +
  '    | head -n1)\n' +
  '  of1_ttl=$(printf "%s" "$of1_body" \\\n' +
  '    | sed -n \'s/.*"expires_in"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p\' \\\n' +
  '    | head -n1)\n' +
  '  case "$of1_ttl" in "" | *[!0-9]*) of1_ttl=3600 ;; esac\n' +
  '  of1_new=$(umask 077; mktemp "$of1_state_dir/.auth.XXXXXXXX") || return 1\n' +
  '  if [ -n "$of1_token" ]; then\n' +
  // Refreshed a minute early, so a token cannot expire mid-poll.
  '    printf "Authorization: Bearer %s\\n" "$of1_token" > "$of1_new"\n' +
  '    of1_until=$(( $(date +%s) + of1_ttl - 60 ))\n' +
  '    OPENF1_AUTH_STATE=ok\n' +
  '  else\n' +
  // A rejected or unreachable /token still writes the pair of files, with an
  // empty header file and a short expiry. It is a negative cache: without it,
  // credentials that are simply wrong would bolt a second failed request onto
  // every single poll for as long as live mode stays on.
  '    : > "$of1_new"\n' +
  '    of1_until=$(( $(date +%s) + 300 ))\n' +
  '  fi\n' +
  '  mv -f "$of1_new" "$of1_auth_file" || { rm -f "$of1_new"; return 1; }\n' +
  '  ( umask 077; printf "%s\\n" "$of1_until" > "$of1_exp_file" ) 2>/dev/null || true\n' +
  '  [ "$OPENF1_AUTH_STATE" = ok ] || return 1\n' +
  '  OPENF1_AUTH=$of1_auth_file\n' +
  '}\n' +
  '\n' +
  'of1_auth_load() {\n' +
  '  of1_credentials || { OPENF1_AUTH_STATE=none; return 1; }\n' +
  '  of1_exp=0\n' +
  '  if [ -f "$of1_exp_file" ] && [ ! -L "$of1_exp_file" ]; then\n' +
  '    of1_exp=$(head -n1 "$of1_exp_file" 2>/dev/null)\n' +
  '    case "$of1_exp" in "" | *[!0-9]*) of1_exp=0 ;; esac\n' +
  '  fi\n' +
  '  if [ "$of1_exp" -gt "$(date +%s)" ] \\\n' +
  '     && [ -f "$of1_auth_file" ] && [ ! -L "$of1_auth_file" ]; then\n' +
  '    if [ -s "$of1_auth_file" ]; then\n' +
  '      OPENF1_AUTH=$of1_auth_file\n' +
  '      OPENF1_AUTH_STATE=ok\n' +
  '      return 0\n' +
  '    fi\n' +
  '    OPENF1_AUTH_STATE=failed\n' +
  '    return 1\n' +
  '  fi\n' +
  '  of1_mint\n' +
  '}\n' +
  '\n' +
  // A bearer token is a credential for exactly one host. CachedFetch is
  // generic and also fetches jolpica, so the host is checked at the point of
  // use rather than assumed at the point of minting.
  'of1_auth_for() {\n' +
  '  case "$1" in\n' +
  '    https://api.openf1.org/*)\n' +
  // Loaded on first OpenF1 use, not up front: this prelude is also included
  // by the generic cache pipeline, which spends most of its requests on
  // jolpica, and those have no business touching an OpenF1 token.
  '      [ "$of1_loaded" = 1 ] || { of1_auth_load >/dev/null 2>&1 || true; of1_loaded=1; }\n' +
  '      printf "%s" "$OPENF1_AUTH" ;;\n' +
  '    *) printf "%s" /dev/null ;;\n' +
  '  esac\n' +
  '}\n'

if (typeof module !== "undefined") {
  module.exports = { PRELUDE: PRELUDE }
}
