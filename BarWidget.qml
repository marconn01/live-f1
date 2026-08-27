import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "F1Model.js" as F1Model

// The bar pill.
//
// A text label rather than an icon, deliberately: the useful thing to show at
// a glance is "how long until the next session", which is a value, not a
// symbol — and a text label renders correctly whatever the user's monospace
// font resolves to, where a Nerd Font glyph would be a blank box on a plain
// font. It turns the bar's active colour while a session is running.
//
// Left click opens the dashboard, right click sends the next-session summary
// as a notification, middle click forces a refresh.
BarWidget {
  id: root
  moduleName: "nocram.f1"

  readonly property string label: panelLoader.item ? panelLoader.item.label : "F1 ⋯"
  readonly property bool sessionLive: panelLoader.item
    ? panelLoader.item.dataSvc.liveSession !== null
    : false

  // Vertical bars get a two-line stack; a horizontal countdown would be
  // unreadable rotated into a 28px-wide column.
  readonly property var verticalLines: {
    var parts = String(label).split(" ")
    if (parts.length <= 1) return ["F1"]
    return ["F1", parts.slice(1).join(" ").split(" ")[0]]
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function toggleLive() {
    if (panelLoader.item) panelLoader.item.toggleLive()
  }

  // The tooltip is built from names the calendar API supplied, and bar.run
  // hands this whole string to `bash -lc`, so it gets the same treatment the
  // scheduled notifications get in Notifier.send — for the same reason,
  // spelled out in F1Model.notificationArg.
  //
  // shellQuote alone is not that treatment. It stops the text from breaking
  // out of its quotes, which is the only thing it claims to do, and a quoted
  // argument is still an argument: omarchy-notification-send hands any token
  // it does not recognise straight to notify-send, and a race name beginning
  // "--hint=string:omarchy-exec:" is then a click-to-run command attached to
  // our own toast. notificationArg is what makes the text stop looking like
  // an option in the first place.
  function announce() {
    if (!root.bar || !panelLoader.item) return
    var text = F1Model.notificationArg(panelLoader.item.tooltipText, "Formula 1")
    root.bar.run("omarchy-notification-send --app-name 'Formula 1' 'Formula 1' "
      + Util.shellQuote(text))
  }

  // Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Dashboard.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "nocram.f1.widget"

    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function toggleLive(): void { root.toggleLive() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.label
    labelVisible: !root.vertical
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : text !== ""
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75
    // The bar's own "something is happening" colour, so a running session
    // reads the same way every other urgent bar state does.
    active: root.sessionLive
    tooltipText: panelLoader.item ? panelLoader.item.tooltipText : ""

    onPressed: function(b) {
      if (b === Qt.RightButton) root.announce()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData.length > 3 ? button.fontSize * 0.85 : button.fontSize
          color: button.active ? button.activeColor : button.foreground
        }
      }
    }

    Accessible.role: Accessible.Button
    Accessible.name: "Formula 1"
    Accessible.description: panelLoader.item ? panelLoader.item.tooltipText : "Formula 1 dashboard"
  }
}
