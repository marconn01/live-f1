import QtQuick
import "F1Circuit.js" as F1Circuit

// Circuit map for the current race.
//
// The maps ship with the plugin in circuits/, so this is a table lookup and a
// URL, not a download: no network, no cache directory, no half-written file to
// recover from, and the right track is on screen the instant the panel opens.
//
// A circuit the set does not cover — a new street track on next year's
// calendar — resolves to `ready` false, and the panel renders the circuit's
// name and location on its own. A missing map is never an error.
QtObject {
  id: root

  property var race: null

  // Relative to this file, which is the plugin root — the same directory the
  // installer copies circuits/ into.
  readonly property string mapPath: F1Circuit.mapPathFor(race)
  readonly property url source: mapPath === "" ? "" : Qt.resolvedUrl(mapPath)
  readonly property bool ready: mapPath !== ""
}
