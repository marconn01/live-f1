import QtQuick
import qs.Commons

// The shared row for every ranked list on the panel: driver standings,
// constructor standings, the qualifying grid, and the latest race result.
//
// One component for all four keeps the columns aligned across sections, so the
// eye can move down the panel without re-learning a layout each time.
//
// The team livery appears as a bar at the row's leading edge, and the team's
// name is always printed next to it. Colour is decoration; the text is the
// information.
Rectangle {
  id: root

  property int position: 0
  property string positionPrefix: "P"
  property string code: ""
  property string name: ""
  property string teamName: ""
  property color teamColor: Color.accent
  property string valueText: ""
  property string noteText: ""
  property bool pinned: false
  property bool showTeam: true
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  implicitHeight: Math.max(content.implicitHeight, note.visible ? note.implicitHeight : 0) + Style.space(9)
  radius: Math.max(2, Style.cornerRadius)
  // A pinned row is the one exception to the flat list, because its whole
  // purpose is to be findable at a glance somewhere it does not belong.
  color: pinned ? Util.alpha(Color.accent, 0.10) : "transparent"
  border.width: pinned ? Math.max(1, Style.normalBorderWidth) : 0
  border.color: Util.alpha(Color.accent, 0.35)

  Row {
    id: content
    anchors.left: parent.left
    anchors.leftMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(10)

    Text {
      width: Style.space(24)
      anchors.verticalCenter: parent.verticalCenter
      text: root.positionPrefix + root.position
      color: root.position === 1 ? root.foreground : Qt.darker(root.foreground, 1.7)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: root.position === 1
    }

    // Livery marker. Purely supplementary to the team name printed below.
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(3)
      height: Style.space(16)
      radius: width / 2
      color: root.teamColor
      visible: root.showTeam
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Row {
        spacing: Style.space(8)

        Text {
          text: root.name
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          visible: root.code !== ""
          text: root.code
          color: Qt.darker(root.foreground, 1.9)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 0.6
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Text {
        visible: root.showTeam && root.teamName !== ""
        text: root.teamName
        color: Qt.darker(root.foreground, 1.7)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  Column {
    anchors.right: parent.right
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Text {
      anchors.right: parent.right
      text: root.valueText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: root.pinned || root.position === 1
    }

    Text {
      id: note
      anchors.right: parent.right
      visible: root.noteText !== ""
      text: root.noteText
      color: root.pinned ? Color.accent : Qt.darker(root.foreground, 1.8)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Accessible.role: Accessible.ListItem
  Accessible.name: root.positionPrefix + root.position + ", " + root.name
    + (root.teamName !== "" ? ", " + root.teamName : "")
    + ", " + root.valueText
    + (root.noteText !== "" ? ", " + root.noteText : "")
}
