import QtQuick
import qs.Commons

// One row of the next race's weekend schedule.
//
// Layout is a fixed three-column grid — session, local day and time, state —
// so the times line up down the column and can be scanned without reading the
// labels. Everything time-shaped is handed in already formatted by the panel's
// time layer; this component never converts anything itself.
Rectangle {
  id: root

  property var session: null
  property string state: "upcoming"
  property string dayText: ""
  property string timeText: ""
  property string countdownText: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property bool isLive: state === "live"
  readonly property bool isDone: state === "done"

  implicitHeight: content.implicitHeight + Style.space(10)
  radius: Math.max(2, Style.cornerRadius)
  color: isLive ? Util.alpha(Color.urgent, 0.10) : "transparent"

  Row {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(10)

    // Session identity.
    Item {
      width: Style.space(52)
      height: shortLabel.implicitHeight
      anchors.verticalCenter: parent.verticalCenter

      Text {
        id: shortLabel
        anchors.left: parent.left
        text: root.session ? root.session.short : ""
        color: root.isLive ? Color.urgent : root.isDone ? Qt.darker(root.foreground, 2.1) : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: root.isLive
        font.letterSpacing: 0.5
      }
    }

    Text {
      width: Style.space(120)
      anchors.verticalCenter: parent.verticalCenter
      text: root.session ? root.session.name : ""
      color: root.isDone ? Qt.darker(root.foreground, 2.1) : Qt.darker(root.foreground, 1.3)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    // Local day + time. The whole reason the panel exists in this shape.
    Row {
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        width: Style.space(30)
        text: root.dayText
        color: Qt.darker(root.foreground, 1.9)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        text: root.timeText
        color: root.isDone ? Qt.darker(root.foreground, 1.9) : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: root.isLive
      }
    }
  }

  // State, right-aligned so the column reads as a single stack of badges.
  StatusChip {
    anchors.right: parent.right
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    foreground: root.foreground
    fontFamily: root.fontFamily
    tone: root.state
    text: root.state === "live" ? "LIVE"
      : root.state === "done" ? "DONE"
      : root.state === "soon" ? "SOON"
      : root.countdownText
  }

  Accessible.role: Accessible.ListItem
  Accessible.name: root.session
    ? root.session.name + ", " + root.dayText + " " + root.timeText + ", " + root.state
    : ""
}
