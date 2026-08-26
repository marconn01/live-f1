// Tests for circuit-map lookup (F1Circuit.js).
//
// Kept separate from tests/run.js so it can be run on its own:
//   node tests/circuit.js
//
// The lookup is a table, so the tests that matter are the ones a table gets
// wrong: an entry pointing at a file that is not shipped, a calendar entry
// with no table row, and the accented place names that the hand-rolled slug()
// has to fold.

const fs = require("fs")
const path = require("path")

const ROOT = path.join(__dirname, "..")

function load(file) {
  const src = fs
    .readFileSync(path.join(ROOT, file), "utf8")
    .split("\n")
    .filter((line) => !/^\s*\.(pragma|import)\b/.test(line))
    .join("\n")
  const module = { exports: {} }
  new Function("module", "exports", src)(module, module.exports)
  return module.exports
}

const F1Circuit = load("F1Circuit.js")

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

const race = (circuitId, locality) => ({ circuitId, locality })

// The circuits/ directory as actually shipped.
const shipped = fs
  .readdirSync(path.join(ROOT, F1Circuit.MAP_DIR))
  .filter((name) => name.endsWith(".svg"))

check("every mapped circuit id resolves to a file that exists", () => {
  for (const id of F1Circuit.knownCircuitIds()) {
    const file = F1Circuit.mapFileFor(race(id, ""))
    assert(file !== "", `${id} resolved to nothing`)
    assert(shipped.indexOf(file) !== -1, `${id} -> ${file}, which is not in circuits/`)
  }
})

check("every shipped drawing is reachable from some circuit id", () => {
  const used = F1Circuit.knownCircuitIds().map((id) => F1Circuit.mapFileFor(race(id, "")))
  for (const file of shipped) {
    assert(used.indexOf(file) !== -1, `${file} is shipped but no circuit id points at it`)
  }
})

check("the ids the calendar actually uses are covered", () => {
  // Spot checks on the ones whose id looks nothing like their filename —
  // exactly where a hand-written table goes wrong.
  equal(F1Circuit.mapFileFor(race("americas", "Austin")), "austin-1.svg")
  equal(F1Circuit.mapFileFor(race("albert_park", "Melbourne")), "melbourne-2.svg")
  equal(F1Circuit.mapFileFor(race("villeneuve", "Montreal")), "montreal-6.svg")
  equal(F1Circuit.mapFileFor(race("rodriguez", "Mexico City")), "mexico-city-3.svg")
  equal(F1Circuit.mapFileFor(race("red_bull_ring", "Spielberg")), "spielberg-3.svg")
  equal(F1Circuit.mapFileFor(race("losail", "Lusail")), "lusail-1.svg")
  equal(F1Circuit.mapFileFor(race("vegas", "Las Vegas")), "las-vegas-1.svg")
  equal(F1Circuit.mapFileFor(race("marina_bay", "Marina Bay")), "marina-bay-4.svg")
})

check("locality is the fallback when the id is unrecognised", () => {
  // Jolpica has renamed circuit ids before; the city has not moved.
  equal(F1Circuit.mapFileFor(race("las_vegas_strip", "Las Vegas")), "las-vegas-1.svg")
  equal(F1Circuit.mapFileFor(race("", "Monte Carlo")), "monaco-6.svg")
})

check("accented place names fold to their table key", () => {
  equal(F1Circuit.slug("Montmeló"), "montmelo")
  equal(F1Circuit.slug("São Paulo"), "sao-paulo")
  equal(F1Circuit.mapFileFor(race("nope", "Montmeló")), "catalunya-6.svg")
  equal(F1Circuit.mapFileFor(race("nope", "São Paulo")), "interlagos-2.svg")
})

check("a circuit the set does not cover resolves to nothing", () => {
  equal(F1Circuit.mapFileFor(race("some_new_street_track", "Kigali")), "")
  equal(F1Circuit.mapPathFor(race("some_new_street_track", "Kigali")), "")
})

check("paths are relative to the plugin root", () => {
  equal(F1Circuit.mapPathFor(race("monza", "Monza")), "circuits/monza-7.svg")
})

check("everything degrades to empty rather than throwing", () => {
  equal(F1Circuit.mapFileFor(null), "")
  equal(F1Circuit.mapFileFor(undefined), "")
  equal(F1Circuit.mapFileFor({}), "")
  equal(F1Circuit.mapPathFor(null), "")
  equal(F1Circuit.slug(null), "")
  equal(F1Circuit.slug(undefined), "")
})

console.log(`\n${passed} passed, ${failures.length} failed`)
for (const failure of failures) console.log(`  FAIL  ${failure}`)
process.exit(failures.length === 0 ? 0 : 1)
