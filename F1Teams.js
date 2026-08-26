.pragma library

// Team identity: constructor id -> livery colour.
//
// Colours are branding constants, not championship data, so they are safe to
// carry locally — nothing here encodes who is winning, who drives for whom, or
// when anyone races. Two safety nets keep an unknown or renamed constructor
// from breaking the UI:
//
//   * OpenF1 reports a `team_colour` per driver during a live session; the
//     live view prefers that over anything in this table.
//   * A constructor with no entry gets a stable colour derived from its id,
//     so a brand-new team still reads as a distinct team rather than as an
//     untinted row.
//
// Colour is never the only carrier of meaning. Every row that uses a livery
// swatch also prints the team name as text, per the accessibility contract.

var TEAM_COLORS = {
  "mclaren":       "#ff8000",
  "ferrari":       "#e8002d",
  "mercedes":      "#27f4d2",
  "red_bull":      "#3671c6",
  "williams":      "#64c4ff",
  "aston_martin":  "#229971",
  "alpine":        "#ff87bc",
  "haas":          "#b6babd",
  "rb":            "#6692ff",
  "sauber":        "#52e252",
  "audi":          "#009597",
  "cadillac":      "#c8b273",
  "alphatauri":    "#6692ff",
  "alfa":          "#52e252",
  "racing_point":  "#229971",
  "renault":       "#ff87bc",
  "toro_rosso":    "#6692ff",
  "force_india":   "#ff87bc"
}

// Also accept the display names the live feed and results use, so a lookup
// works whether the caller holds an Ergast constructorId or a plain name.
var NAME_ALIASES = {
  "mclaren": "mclaren",
  "ferrari": "ferrari",
  "scuderia ferrari": "ferrari",
  "mercedes": "mercedes",
  "red bull racing": "red_bull",
  "red bull": "red_bull",
  "williams": "williams",
  "aston martin": "aston_martin",
  "alpine": "alpine",
  "alpine f1 team": "alpine",
  "haas f1 team": "haas",
  "haas": "haas",
  "racing bulls": "rb",
  "rb f1 team": "rb",
  "visa cash app rb": "rb",
  "kick sauber": "sauber",
  "sauber": "sauber",
  "audi": "audi",
  "cadillac": "cadillac"
}

function normalizeKey(value) {
  return String(value || "")
    .replace(/^\s+|\s+$/g, "")
    .toLowerCase()
}

function canonicalId(constructorId, constructorName) {
  var id = normalizeKey(constructorId)
  if (id !== "" && TEAM_COLORS[id]) return id
  var alias = NAME_ALIASES[normalizeKey(constructorName)]
  if (alias) return alias
  return id
}

// Deterministic fallback hue for a constructor we have no entry for. Same id
// always yields the same colour, and the lightness is pinned high enough to
// stay legible on the shell's dark popup background.
function derivedColor(seed) {
  var key = normalizeKey(seed)
  if (key === "") return "#8a8f98"
  var hash = 0
  for (var i = 0; i < key.length; i++) {
    hash = ((hash << 5) - hash + key.charCodeAt(i)) | 0
  }
  var hue = Math.abs(hash) % 360
  return hslToHex(hue, 0.62, 0.62)
}

function hslToHex(h, s, l) {
  var c = (1 - Math.abs(2 * l - 1)) * s
  var x = c * (1 - Math.abs(((h / 60) % 2) - 1))
  var m = l - c / 2
  var r = 0, g = 0, b = 0
  if (h < 60) { r = c; g = x }
  else if (h < 120) { r = x; g = c }
  else if (h < 180) { g = c; b = x }
  else if (h < 240) { g = x; b = c }
  else if (h < 300) { r = x; b = c }
  else { r = c; b = x }
  return "#" + hex2((r + m) * 255) + hex2((g + m) * 255) + hex2((b + m) * 255)
}

function hex2(v) {
  var n = Math.max(0, Math.min(255, Math.round(v)))
  var s = n.toString(16)
  return s.length === 1 ? "0" + s : s
}

// The one entry point. `liveColour` is OpenF1's `team_colour` ("F47600",
// no leading hash) and takes priority when a session is running.
function colorFor(constructorId, constructorName, liveColour) {
  var live = String(liveColour || "").replace(/^#/, "").replace(/^\s+|\s+$/g, "")
  if (/^[0-9a-fA-F]{6}$/.test(live)) return "#" + live.toLowerCase()

  var id = canonicalId(constructorId, constructorName)
  if (TEAM_COLORS[id]) return TEAM_COLORS[id]
  return derivedColor(id || constructorName)
}

if (typeof module !== "undefined") {
  module.exports = {
    TEAM_COLORS: TEAM_COLORS,
    canonicalId: canonicalId,
    derivedColor: derivedColor,
    colorFor: colorFor
  }
}
