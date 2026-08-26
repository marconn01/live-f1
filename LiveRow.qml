import QtQuick
import qs.Commons

// One car in the live timing tower.
//
// Monospaced, fixed-width columns: position, livery marker, abbreviation, gap
// to the car ahead, gap to the leader, pit stops. Fixed widths matter more here
// than anywhere else on the panel — during a race these values change every
// tick, and columns that reflow on each update are unreadable.
Rectangle {
  id: root

  property var entry: null
  property color teamColor: Color.accent
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool showLeaderGap: true

  readonly property bool isLeader: entry && entry.position === 1

  implicitHeight: content.implicitHeight + Style.space(7)
  radius: Math.max(2, Style.cornerRadius)
  color: isLeader ? Util.alpha(foreground, 0.06) : "transparent"

  Row {
    id: content
    anchors.left: parent.left
    anchors.leftMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(10)

    Text {
      width: Style.space(26)
      anchors.verticalCenter: parent.verticalCenter
      text: root.entry ? "P" + root.entry.position : ""
      color: root.isLeader ? root.foreground : Qt.darker(root.foreground, 1.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: root.isLeader
    }

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(3)
      height: Style.space(14)
      radius: width / 2
      color: root.teamColor
    }

    Text {
      width: Style.space(38)
      anchors.verticalCenter: parent.verticalCenter
      text: root.entry ? root.entry.acronym : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      font.letterSpacing: 0.5
    }

    Text {
      width: Style.space(88)
      anchors.verticalCenter: parent.verticalCenter
      text: root.entry ? root.entry.teamName : ""
      color: Qt.darker(root.foreground, 1.8)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  Row {
    anchors.right: parent.right
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(14)

    // Pit stop count. Blank rather than "0" so the column only draws attention
    // once a car has actually stopped.
    Text {
      width: Style.space(26)
      horizontalAlignment: Text.AlignRight
      anchors.verticalCenter: parent.verticalCenter
      text: root.entry && root.entry.pitStops > 0 ? root.entry.pitStops + "×" : ""
      color: Qt.darker(root.foreground, 2.0)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // Interval to the car ahead.
    Text {
      width: Style.space(72)
      horizontalAlignment: Text.AlignRight
      anchors.verticalCenter: parent.verticalCenter
      text: root.entry ? root.entry.interval.text : ""
      color: root.entry && !root.entry.interval.known
        ? Qt.darker(root.foreground, 2.2)
        : root.isLeader ? Qt.darker(root.foreground, 1.5) : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    // Cumulative gap to the leader.
    Text {
      visible: root.showLeaderGap
      width: Style.space(72)
      horizontalAlignment: Text.AlignRight
      anchors.verticalCenter: parent.verticalCenter
      text: root.entry && !root.isLeader ? root.entry.gapToLeader.text : ""
      color: Qt.darker(root.foreground, 1.7)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Accessible.role: Accessible.ListItem
  Accessible.name: root.entry
    ? "Position " + root.entry.position + ", " + root.entry.acronym
      + (root.entry.teamName !== "" ? ", " + root.entry.teamName : "")
      + ", interval " + root.entry.interval.text
      + (root.isLeader ? "" : ", gap to leader " + root.entry.gapToLeader.text)
      + (root.entry.pitStops > 0 ? ", " + root.entry.pitStops + " pit stops" : "")
    : ""
}
