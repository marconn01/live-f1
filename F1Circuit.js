.pragma library

// ---------------------------------------------------------------------------
// Choosing which circuit picture to show.
//
// The maps ship with the plugin, in circuits/. They are hand-drawn SVG track
// layouts (from julesr0y/f1-circuits-svg), all on the same 500x500 canvas with
// the same stroke treatment, so every round looks like it belongs to the same
// set — which is more than could ever be said for Wikipedia lead images, where
// one round got a layout diagram, the next a venue roundel, and the next a
// photograph of a driver.
//
// Nothing here touches the network. Resolving a circuit is a table lookup, so
// the map is on screen the moment the panel opens, offline included.
//
// Pure functions only: no QML, no I/O. CircuitImage.qml turns the filename
// this returns into a path the panel can render.
// ---------------------------------------------------------------------------

// The directory, relative to the plugin root, that the SVGs live in.
var MAP_DIR = "circuits"

// Jolpica-F1 circuit id -> shipped filename. The numeric suffix in each
// filename is the upstream set's layout revision, not something we choose, so
// these are spelled out rather than derived.
var BY_ID = {
  "albert_park": "melbourne-2.svg",
  "americas": "austin-1.svg",
  "bahrain": "bahrain-1.svg",
  "baku": "baku-1.svg",
  "catalunya": "catalunya-6.svg",
  "hungaroring": "hungaroring-3.svg",
  "interlagos": "interlagos-2.svg",
  "jeddah": "jeddah-1.svg",
  "losail": "lusail-1.svg",
  "madring": "madring-1.svg",
  "marina_bay": "marina-bay-4.svg",
  "miami": "miami-1.svg",
  "monaco": "monaco-6.svg",
  "monza": "monza-7.svg",
  "red_bull_ring": "spielberg-3.svg",
  "rodriguez": "mexico-city-3.svg",
  "sepang": "sepang-1.svg",
  "shanghai": "shanghai-1.svg",
  "silverstone": "silverstone-8.svg",
  "spa": "spa-francorchamps-4.svg",
  "suzuka": "suzuka-2.svg",
  "vegas": "las-vegas-1.svg",
  "villeneuve": "montreal-6.svg",
  "yas_marina": "yas-marina-2.svg",
  "zandvoort": "zandvoort-5.svg"
}

// Second chance, keyed on the race's locality. Circuit ids are the API's own
// invention and it has renamed them before ("vegas" was "las_vegas"); the city
// a race is held in does not change under us. Accents are folded by slug(), so
// "Montmeló" and "São Paulo" arrive here as plain ASCII.
var BY_LOCALITY = {
  "melbourne": "melbourne-2.svg",
  "austin": "austin-1.svg",
  "sakhir": "bahrain-1.svg",
  "baku": "baku-1.svg",
  "montmelo": "catalunya-6.svg",
  "barcelona": "catalunya-6.svg",
  "budapest": "hungaroring-3.svg",
  "sao-paulo": "interlagos-2.svg",
  "jeddah": "jeddah-1.svg",
  "lusail": "lusail-1.svg",
  "al-daayen": "lusail-1.svg",
  "doha": "lusail-1.svg",
  "madrid": "madring-1.svg",
  "marina-bay": "marina-bay-4.svg",
  "singapore": "marina-bay-4.svg",
  "miami": "miami-1.svg",
  "monte-carlo": "monaco-6.svg",
  "monaco": "monaco-6.svg",
  "monza": "monza-7.svg",
  "spielberg": "spielberg-3.svg",
  "mexico-city": "mexico-city-3.svg",
  "kuala-lumpur": "sepang-1.svg",
  "shanghai": "shanghai-1.svg",
  "silverstone": "silverstone-8.svg",
  "spa": "spa-francorchamps-4.svg",
  "suzuka": "suzuka-2.svg",
  "las-vegas": "las-vegas-1.svg",
  "montreal": "montreal-6.svg",
  "abu-dhabi": "yas-marina-2.svg",
  "zandvoort": "zandvoort-5.svg"
}

// Lowercase, accent-folded, hyphen-joined: the shape both tables are keyed in.
function slug(value) {
  var text = String(value === undefined || value === null ? "" : value).toLowerCase()

  // QML's JS engine has no String.normalize, so fold the handful of accented
  // characters that actually appear in F1 place names by hand.
  var accents = "àáâãäåçèéêëìíîïñòóôõöùúûüýÿ"
  var plain = "aaaaaaceeeeiiiinooooouuuuyy"
  var folded = ""
  for (var i = 0; i < text.length; i++) {
    var at = accents.indexOf(text.charAt(i))
    folded += at === -1 ? text.charAt(i) : plain.charAt(at)
  }

  return folded
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
}

// The shipped map filename for a race, or "" when this circuit has no drawing
// in the set — a one-off street track on a new calendar, say. The caller shows
// the circuit's name and location instead; a missing map is never an error.
function mapFileFor(race) {
  if (!race) return ""

  var byId = BY_ID[slug(race.circuitId).replace(/-/g, "_")]
  if (byId) return byId

  var byLocality = BY_LOCALITY[slug(race.locality)]
  if (byLocality) return byLocality

  return ""
}

// Where that file sits relative to the plugin root. "" stays "" so the caller
// never builds a path to nothing.
function mapPathFor(race) {
  var file = mapFileFor(race)
  return file === "" ? "" : MAP_DIR + "/" + file
}

// Every circuit the set covers, for the tests to assert the calendar against.
function knownCircuitIds() {
  var out = []
  for (var id in BY_ID) out.push(id)
  return out.sort()
}

if (typeof module !== "undefined") {
  module.exports = {
    MAP_DIR: MAP_DIR,
    slug: slug,
    mapFileFor: mapFileFor,
    mapPathFor: mapPathFor,
    knownCircuitIds: knownCircuitIds
  }
}
