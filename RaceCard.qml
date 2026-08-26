import QtQuick
import qs.Commons

// A later round, kept deliberately compact: name, where, when in local time,
// how long away, and whether it is a sprint weekend. No session breakdown —
// that detail belongs only to the race actually coming next.
Rectangle {
  id: root

  property var race: null
  property string dateText: ""
  property string timeText: ""
  property string countdownText: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  implicitHeight: content.implicitHeight + Style.space(14)
  radius: Math.max(2, Style.cornerRadius)
  color: Util.alpha(foreground, 0.03)

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(12)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(4)

    Item {
      width: parent.width
      height: Math.max(title.implicitHeight, sprintChip.implicitHeight)

      Row {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(8)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.race ? "R" + root.race.round : ""
          color: Qt.darker(root.foreground, 2.0)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          id: title
          anchors.verticalCenter: parent.verticalCenter
          text: root.race ? root.race.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        }
      }

      StatusChip {
        id: sprintChip
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: root.race && root.race.isSprintWeekend
        text: "SPRINT"
        tone: "accent"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }
    }

    Item {
      width: parent.width
      height: Math.max(where.implicitHeight, when.implicitHeight)

      Text {
        id: where
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width * 0.5
        text: root.race ? root.race.locality + " · " + root.race.country : ""
        color: Qt.darker(root.foreground, 1.6)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Row {
        id: when
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(10)

        Text {
          text: root.dateText + " · " + root.timeText
          color: Qt.darker(root.foreground, 1.3)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          text: "in " + root.countdownText
          color: Qt.darker(root.foreground, 1.9)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  Accessible.role: Accessible.ListItem
  Accessible.name: root.race
    ? root.race.name + ", " + root.race.locality + ", " + root.dateText + " at " + root.timeText
      + ", in " + root.countdownText + (root.race.isSprintWeekend ? ", sprint weekend" : "")
    : ""
}
