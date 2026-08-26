import QtQuick
import qs.Commons

// Small labelled pill used for every state the dashboard reports: session
// states, the live badge, the sprint marker, stale data, flags.
//
// The label is always a word, never a bare dot. Tone tints the pill, but the
// text carries the meaning on its own, so the state survives a monochrome
// theme, a low-contrast display, and colour-blind vision alike.
Rectangle {
  id: root

  property string text: ""
  // "live" | "soon" | "done" | "upcoming" | "accent" | "warn" | "neutral"
  property string tone: "neutral"
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.caption
  property bool filled: false

  readonly property color toneColor: {
    switch (tone) {
      case "live": return Color.urgent
      case "warn": return Color.urgent
      case "soon": return Color.accent
      case "accent": return Color.accent
      case "done": return Qt.darker(foreground, 1.9)
      case "upcoming": return Qt.darker(foreground, 1.4)
    }
    return Qt.darker(foreground, 1.4)
  }

  readonly property bool emphasised: tone === "live" || tone === "warn" || filled

  implicitWidth: label.implicitWidth + Style.space(14)
  implicitHeight: label.implicitHeight + Style.space(6)
  radius: Math.max(2, Style.cornerRadius)
  color: emphasised ? Util.alpha(toneColor, 0.18) : Util.alpha(toneColor, 0.07)
  border.width: emphasised ? Math.max(1, Style.normalBorderWidth) : 0
  border.color: Util.alpha(toneColor, 0.5)

  // A live session is the one thing on the panel worth animating: a slow,
  // low-amplitude pulse reads as "this is updating" without becoming a
  // distraction in the corner of a screen someone is working on.
  SequentialAnimation on opacity {
    running: root.tone === "live" && root.visible
    loops: Animation.Infinite
    NumberAnimation { from: 1.0; to: 0.62; duration: 1100; easing.type: Easing.InOutSine }
    NumberAnimation { from: 0.62; to: 1.0; duration: 1100; easing.type: Easing.InOutSine }
  }

  Text {
    id: label
    anchors.centerIn: parent
    text: root.text
    color: root.emphasised ? root.toneColor : Qt.darker(root.foreground, 1.25)
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    font.bold: root.emphasised
    font.letterSpacing: 0.8
  }

  Accessible.role: Accessible.StaticText
  Accessible.name: root.text
}
