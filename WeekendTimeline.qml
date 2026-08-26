import QtQuick
import qs.Commons

// The weekend at a glance: FP1 → FP2 → FP3 → QUAL → RACE, or the sprint
// variant, in the order the sessions actually run.
//
// Each stop states its own status in text under the label, so the timeline is
// readable without decoding the tint: a completed session is struck through and
// dimmed, the running one is bold and marked LIVE, the rest carry their local
// start time. Only the current race gets this treatment — later rounds stay
// compact cards.
Item {
  id: root

  property var sessions: []
  property double now: 0
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  // Injected by the panel so every time in here goes through the one time layer.
  property var stateOf: null
  property var timeOf: null

  implicitHeight: row.implicitHeight
  implicitWidth: row.implicitWidth

  Row {
    id: row
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: 0

    Repeater {
      model: root.sessions

      Row {
        id: stop
        required property var modelData
        required property int index

        readonly property string state: root.stateOf ? root.stateOf(modelData) : "upcoming"
        spacing: 0

        Column {
          spacing: Style.space(3)
          anchors.verticalCenter: parent.verticalCenter

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: stop.modelData.short
            color: stop.state === "live" ? Color.urgent
              : stop.state === "done" ? Qt.darker(root.foreground, 2.2)
              : stop.state === "soon" ? Color.accent
              : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: stop.state === "live" || stop.state === "soon"
            font.letterSpacing: 0.5
            font.strikeout: stop.state === "done"
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: stop.state === "live" ? "LIVE"
              : stop.state === "done" ? "DONE"
              : (root.timeOf ? root.timeOf(stop.modelData.startAt) : "")
            color: stop.state === "live" ? Color.urgent : Qt.darker(root.foreground, 1.8)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: stop.state === "live"
          }
        }

        // Connector, drawn between stops rather than after the last one.
        Text {
          visible: stop.index < root.sessions.length - 1
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: -Style.space(5)
          text: "  →  "
          color: Qt.darker(root.foreground, 2.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  Accessible.role: Accessible.List
  Accessible.name: "Weekend session timeline"
}
