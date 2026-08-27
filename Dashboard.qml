import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "F1Time.js" as F1Time
import "F1Model.js" as F1Model
import "F1Teams.js" as F1Teams

// The F1 Live dashboard.
//
// This file is presentation and wiring only. It owns no parsing, no fetching,
// no caching, and — most deliberately — no timezone arithmetic: every instant
// it draws goes through the handful of helpers below, which are the panel's
// only door to F1Time. That is what makes "every time is laptop-local" a
// property of the plugin rather than a habit each component has to remember.
Panel {
  id: root
  moduleName: "nocram.f1"
  ipcTarget: "nocram.f1"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ------------------------------------------------------------ settings

  readonly property bool hour12: String(setting("timeFormat", "24-hour")) === "12-hour"
  readonly property bool autoLive: setting("autoLive", true) === true
  readonly property int liveRefreshSec: Math.max(5, Math.min(120, parseInt(setting("liveRefreshSec", 12), 10) || 12))
  readonly property int refreshMinutes: Math.max(5, parseInt(setting("refreshMinutes", 15), 10) || 15)
  readonly property bool notificationsEnabled: setting("notifications", true) === true
  readonly property string notifyLeadMinutes: String(setting("notifyLeadMinutes", "30,15"))
  readonly property var notifySessions: {
    var value = setting("notifySessions", ["Race", "Qualifying", "Sprint"])
    return Array.isArray(value) ? value : ["Race", "Qualifying", "Sprint"]
  }
  readonly property string highlightDriver: String(setting("highlightDriver", "Verstappen"))

  // ------------------------------------------------------- the time layer

  readonly property double now: timeSvc.now
  readonly property var timeCtx: timeSvc.context

  function fmtTime(at) { return F1Time.formatTime(at, timeCtx) }
  function fmtDate(at) { return F1Time.formatDate(at, timeCtx) }
  function fmtDateLong(at) { return F1Time.formatDateLong(at, timeCtx) }
  function fmtDay(at) { return F1Time.formatDayShort(at, timeCtx) }
  function fmtDayTime(at) { return F1Time.formatDayTime(at, timeCtx) }
  function fmtRange(from, to) { return F1Time.formatDateRange(from, to, timeCtx) }
  function countdownTo(at) { return F1Time.countdown(at, now) }
  function shortCountdownTo(at) { return F1Time.shortCountdown(at, now) }
  function agoOf(at) { return F1Time.agoText(at, now) }
  function stateOf(session) { return F1Model.sessionState(session, now) }

  function teamColor(constructorId, constructorName, liveColour) {
    return F1Teams.colorFor(constructorId, constructorName, liveColour)
  }

  // ------------------------------------------------------------ services

  property TimeService timeSvc: TimeService {
    hour12: root.hour12
    // A seconds-resolution clock is only needed while something on screen
    // counts in seconds.
    fastTick: root.opened || live.polls
  }

  property DataService dataSvc: DataService {
    now: root.now
    refreshMinutes: root.refreshMinutes
    highlightDriver: root.highlightDriver
  }

  property LiveService live: LiveService {
    now: root.now
    enabled: root.liveMode
    refreshSeconds: root.liveRefreshSec
    scheduledSession: root.liveTimingSession
    totalLaps: root.dataSvc.knownRaceDistance
  }

  property CircuitImage circuit: CircuitImage {
    race: root.dataSvc.race
  }

  property Notifier notifier: Notifier {
    now: root.now
    enabled: root.notificationsEnabled
    race: root.dataSvc.race
    timeContext: root.timeCtx
    leadMinutes: root.notifyLeadMinutes
    sessionGroups: root.notifySessions
  }

  // ------------------------------------------------------------ live mode

  // "" follows the automatic rule; "on"/"off" is the user overriding it. The
  // override is cleared when the session it applied to ends, so a manual
  // choice never silently governs next week's race.
  property string liveOverride: ""

  // Sessions worth a timing tower: a race or a sprint.
  readonly property var liveTimingSession: {
    var session = dataSvc.liveSession
    if (!session) return null
    if (session.group === "Race" || session.group === "Sprint" || session.group === "Qualifying") return session
    return null
  }

  readonly property bool autoLiveActive: autoLive && liveTimingSession !== null
    && (liveTimingSession.group === "Race" || liveTimingSession.group === "Sprint")

  readonly property bool liveMode: liveOverride === "on" ? true
    : liveOverride === "off" ? false
    : autoLiveActive

  function toggleLive() {
    liveOverride = liveMode ? "off" : "on"
  }

  onAutoLiveActiveChanged: liveOverride = ""

  // ------------------------------------------------------------ bar pill

  // What the bar shows. Short, and never empty once anything is known, so the
  // pill does not appear and disappear as data loads.
  readonly property string label: {
    if (!dataSvc.loaded) return dataSvc.failed ? "F1 —" : "F1 ⋯"
    if (dataSvc.offSeason) return "F1 OFF"
    var running = dataSvc.liveSession
    if (running) return "F1 " + running.short
    var next = dataSvc.race ? F1Model.nextSession(dataSvc.race, now) : null
    if (!next) return "F1 —"
    return "F1 " + shortCountdownTo(next.startAt)
  }

  readonly property string tooltipText: {
    if (!dataSvc.loaded) return "F1 Live — loading"
    if (dataSvc.offSeason) return "F1 Live — off season"
    var running = dataSvc.liveSession
    if (running) return running.name + " is live — " + dataSvc.race.name
    var next = dataSvc.race ? F1Model.nextSession(dataSvc.race, now) : null
    if (!next || !dataSvc.race) return "F1 Live"
    return dataSvc.race.name + " · " + next.name + " " + fmtDayTime(next.startAt) + " (" + countdownTo(next.startAt) + ")"
  }

  // ------------------------------------------------------ panel lifecycle

  property bool openedFromHotkey: false

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    onOpened()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    onOpened()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function onOpened() {
    // The zone could have changed while the panel was closed; re-ask before
    // drawing a single time.
    timeSvc.refreshZone()
    dataSvc.refresh(false)
    if (live.polls) live.refreshNow()
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function refresh() {
    dataSvc.refresh(true)
    if (live.polls) live.refreshNow()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function live(mode: string): string {
      if (mode === "on" || mode === "off") root.liveOverride = mode
      else if (mode === "auto") root.liveOverride = ""
      else root.toggleLive()
      return root.liveMode ? "on" : "off"
    }
    function status(): string {
      if (!root.dataSvc.loaded) return "loading"
      if (root.dataSvc.offSeason) return "off season"
      var running = root.dataSvc.liveSession
      if (running) return running.name + " live at " + root.dataSvc.race.name
      var next = F1Model.nextSession(root.dataSvc.race, root.now)
      if (!next) return root.dataSvc.race.name
      return root.dataSvc.race.name + " — " + next.name + " " + root.fmtDayTime(next.startAt)
        + " (in " + root.countdownTo(next.startAt) + ")"
    }
  }

  // ------------------------------------------------------------ the panel

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.6)
  readonly property color dimmer: Qt.darker(fg, 2.0)

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // Enter / Space is the panel's primary action: flip live mode.
      onActivateRequested: root.toggleLive()
      onMoveRequested: function(dx, dy) {
        if (dy === 0) return
        scroll.contentY = Math.max(0, Math.min(scroll.contentHeight - scroll.height,
                                               scroll.contentY + dy * Style.space(48)))
      }
      onTextKey: function(text) {
        if (text === "r") root.refresh()
        else if (text === "g") scroll.contentY = 0
        else if (text === "G") scroll.contentY = Math.max(0, scroll.contentHeight - scroll.height)
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroll.width
          spacing: Style.space(12)

          // ---------------------------------------------------- header

          Item {
            width: parent.width
            height: Math.max(headline.implicitHeight, liveToggle.implicitHeight)

            Row {
              id: headline
              anchors.left: parent.left
              anchors.leftMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              StatusChip {
                anchors.verticalCenter: parent.verticalCenter
                text: root.liveMode ? "LIVE TIMING" : (root.dataSvc.weekend ? root.dataSvc.weekend.label : "FORMULA 1")
                tone: root.liveMode ? "live"
                  : root.dataSvc.weekend && root.dataSvc.weekend.kind === "live" ? "live"
                  : root.dataSvc.weekend && root.dataSvc.weekend.kind === "soon" ? "soon"
                  : "accent"
                foreground: root.fg
                fontFamily: root.fontFamily
                filled: true
              }

              Text {
                visible: root.dataSvc.race !== null && !root.liveMode
                anchors.verticalCenter: parent.verticalCenter
                text: root.dataSvc.race
                  ? "ROUND " + root.dataSvc.race.round + " · " + root.dataSvc.race.season
                  : ""
                color: root.dimmer
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 0.8
              }
            }

            // Live toggle. A real button with a state word inside it, so its
            // condition is legible without interpreting a colour.
            Rectangle {
              id: liveToggle
              anchors.right: parent.right
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              implicitWidth: toggleLabel.implicitWidth + Style.space(20)
              implicitHeight: toggleLabel.implicitHeight + Style.space(9)
              radius: Math.max(2, Style.cornerRadius)
              color: root.liveMode
                ? Util.alpha(Color.urgent, 0.18)
                : Style.controlFill(false, toggleArea.containsMouse, root.fg, Color.accent)
              border.width: Style.controlBorderWidth(false, toggleArea.containsMouse)
              border.color: root.liveMode
                ? Util.alpha(Color.urgent, 0.55)
                : Style.controlBorder(false, toggleArea.containsMouse, root.fg, Color.accent)

              Text {
                id: toggleLabel
                anchors.centerIn: parent
                text: root.liveMode ? "LIVE RACE · ON" : "LIVE RACE · OFF"
                color: root.liveMode ? Color.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: root.liveMode
                font.letterSpacing: 0.8
              }

              MouseArea {
                id: toggleArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleLive()
              }

              Accessible.role: Accessible.Button
              Accessible.name: "Live race mode"
              Accessible.description: root.liveMode
                ? "Live race dashboard is on. Activate to return to the race overview."
                : "Live race dashboard is off. Activate to show live timing."
              Accessible.checkable: true
              Accessible.checked: root.liveMode
              Accessible.onPressAction: root.toggleLive()
            }
          }

          // ------------------------------------------- loading / failure

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: !root.dataSvc.loaded

            Text {
              text: root.dataSvc.failed
                ? "Could not reach the F1 data service."
                : "Loading the season calendar…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              leftPadding: Style.space(4)
            }

            Text {
              visible: root.dataSvc.failed
              text: "Retrying automatically. Press r to try again now."
              color: root.dimmer
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              leftPadding: Style.space(4)
            }
          }

          Text {
            width: parent.width
            visible: root.dataSvc.loaded && root.dataSvc.offSeason
            text: "The season has finished. Waiting for the next calendar to be published."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            leftPadding: Style.space(4)
            wrapMode: Text.WordWrap
          }

          // =================================================== LIVE VIEW

          Loader {
            width: parent.width
            active: root.liveMode && root.dataSvc.loaded
            visible: active
            sourceComponent: liveView
          }

          // ================================================ NORMAL VIEW

          Loader {
            width: parent.width
            active: !root.liveMode && root.dataSvc.loaded && !root.dataSvc.offSeason
            visible: active
            sourceComponent: raceView
          }

          // ---------------------------------------------------- footer

          PanelSeparator {
            width: parent.width
            visible: root.dataSvc.loaded
          }

          Item {
            width: parent.width
            height: footerLeft.implicitHeight
            visible: root.dataSvc.loaded

            Column {
              id: footerLeft
              anchors.left: parent.left
              anchors.leftMargin: Style.space(4)
              spacing: Style.space(2)

              // The zone every time on this panel was rendered in, stated
              // outright rather than assumed.
              Text {
                text: "All times in " + root.timeSvc.zoneLabel
                color: root.dimmer
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                text: root.dataSvc.stale
                  ? "Offline — showing cached data from " + root.agoOf(root.dataSvc.lastUpdatedAt)
                  : "Updated " + root.agoOf(root.dataSvc.lastUpdatedAt)
                color: root.dataSvc.stale ? Color.urgent : root.dimmer
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(4)
              anchors.bottom: parent.bottom
              text: "enter live · r refresh · j k scroll · esc close"
              color: root.dimmer
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  // ==================================================== race overview

  Component {
    id: raceView

    Column {
      spacing: Style.space(12)

      readonly property var race: root.dataSvc.race

      // ------------------------------------------------------- hero

      Item {
        width: parent.width
        height: Math.max(heroText.implicitHeight, trackMap.height) + Style.space(4)

        Column {
          id: heroText
          anchors.left: parent.left
          anchors.leftMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - trackMap.width - Style.space(20)
          spacing: Style.space(5)

          Text {
            width: parent.width
            text: race ? race.name : ""
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            text: race ? race.circuitName : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            text: race ? race.locality + " · " + race.country : ""
            color: root.dimmer
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // Re-homed from the countdown banner, which is gone: which weekend
          // format this is changes what sessions to expect, so it belongs
          // beside the race identity rather than beside a clock.
          StatusChip {
            visible: race && race.isSprintWeekend
            text: "SPRINT WEEKEND"
            tone: "accent"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Item { width: 1; height: Style.space(4) }

          // Race day and start time, in local time, with the countdown.
          Row {
            spacing: Style.space(12)

            Column {
              spacing: Style.space(2)
              Text {
                text: "LIGHTS OUT"
                color: root.dimmer
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
              Text {
                text: race ? root.fmtDateLong(race.raceStartAt) : ""
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                text: race ? root.fmtTime(race.raceStartAt) + " your time" : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        // Circuit map, when the shipped set covers this circuit. Absent simply
        // means this box is not there — nothing else reflows.
        Item {
          id: trackMap
          anchors.right: parent.right
          anchors.rightMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          // The shipped drawings all share one square 500x500 canvas, so the
          // box is square too — a wide box would just letterbox every round
          // and leave the map floating away from the panel edge.
          width: root.circuit.ready ? Style.space(112) : 0
          height: root.circuit.ready ? Style.space(112) : 0
          visible: root.circuit.ready

          Image {
            id: trackImage
            anchors.fill: parent
            source: root.circuit.source
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: true
            smooth: true
            // SVG: sourceSize is the render resolution, not a hint, so ask for
            // twice the box and let it downscale crisply on a HiDPI panel.
            sourceSize.width: Style.space(224)
            sourceSize.height: Style.space(224)

            // The drawings hardcode a white track band with a black centreline,
            // which only happens to suit a dark theme. Colorization preserves
            // luminance, so the band takes the panel's own foreground colour
            // while the centreline stays dark — the drawing's design intact, in
            // whatever theme is loaded, rather than a fixed white.
            layer.enabled: true
            layer.effect: MultiEffect {
              colorization: 1.0
              colorizationColor: root.fg
            }

            Behavior on opacity { NumberAnimation { duration: 180 } }
            opacity: status === Image.Ready ? 1 : 0
          }

          Accessible.role: Accessible.Graphic
          Accessible.name: race ? "Circuit map of " + race.circuitName : "Circuit map"
        }
      }

      // ---------------------------------------------- weekend schedule

      PanelSeparator { width: parent.width }

      PanelSectionHeader {
        text: "WEEKEND · " + (race ? root.fmtRange(race.weekendStartAt, race.weekendEndAt) : "")
        foreground: root.fg
        fontFamily: root.fontFamily
        leftPadding: Style.space(4)
      }

      Column {
        width: parent.width
        spacing: Style.space(1)

        Repeater {
          model: race ? race.sessions : []

          SessionRow {
            required property var modelData
            width: parent.width
            session: modelData
            state: root.stateOf(modelData)
            dayText: root.fmtDay(modelData.startAt)
            timeText: modelData.dateOnly ? "—" : root.fmtTime(modelData.startAt)
            countdownText: root.shortCountdownTo(modelData.startAt)
            foreground: root.fg
            fontFamily: root.fontFamily
          }
        }
      }

      // ------------------------------------------------ starting grid

      PanelSeparator {
        width: parent.width
        visible: root.dataSvc.qualifyingAvailable
      }

      PanelSectionHeader {
        visible: root.dataSvc.qualifyingAvailable
        // Named unambiguously: these are grid slots, not championship places.
        text: "STARTING GRID · QUALIFYING RESULT"
        foreground: root.fg
        fontFamily: root.fontFamily
        leftPadding: Style.space(4)
      }

      Grid {
        width: parent.width
        visible: root.dataSvc.qualifyingAvailable
        columns: 2
        columnSpacing: Style.space(10)
        rowSpacing: Style.space(1)

        Repeater {
          model: root.dataSvc.qualifyingAvailable ? root.dataSvc.qualifying.positions.slice(0, 10) : []

          StandingRow {
            required property var modelData
            width: (parent.width - Style.space(10)) / 2
            position: modelData.position
            positionPrefix: "P"
            name: modelData.familyName
            code: modelData.code
            teamName: modelData.constructorName
            teamColor: root.teamColor(modelData.constructorId, modelData.constructorName, "")
            valueText: modelData.bestTime
            showTeam: false
            foreground: root.fg
            fontFamily: root.fontFamily
          }
        }
      }

      // ----------------------------------------------- upcoming races

      PanelSeparator {
        width: parent.width
        visible: root.dataSvc.upcoming.length > 0
      }

      PanelSectionHeader {
        visible: root.dataSvc.upcoming.length > 0
        text: "UPCOMING RACES"
        foreground: root.fg
        fontFamily: root.fontFamily
        leftPadding: Style.space(4)
      }

      Column {
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: root.dataSvc.upcoming

          RaceCard {
            required property var modelData
            width: parent.width
            race: modelData
            dateText: root.fmtDate(modelData.raceStartAt)
            timeText: root.fmtTime(modelData.raceStartAt)
            countdownText: root.shortCountdownTo(modelData.raceStartAt)
            foreground: root.fg
            fontFamily: root.fontFamily
          }
        }
      }

      // --------------------------------------------- driver standings

      PanelSeparator {
        width: parent.width
        visible: root.dataSvc.driverStandings.length > 0
      }

      PanelSectionHeader {
        visible: root.dataSvc.driverStandings.length > 0
        text: "DRIVER STANDINGS"
        foreground: root.fg
        fontFamily: root.fontFamily
        leftPadding: Style.space(4)
      }

      Column {
        width: parent.width
        spacing: Style.space(1)

        Repeater {
          model: root.dataSvc.standingsView.top

          StandingRow {
            required property var modelData
            width: parent.width
            position: modelData.position
            name: modelData.fullName
            code: modelData.code
            teamName: modelData.constructorName
            teamColor: root.teamColor(modelData.constructorId, modelData.constructorName, "")
            valueText: modelData.points + " pts"
            noteText: modelData.wins > 0 ? modelData.wins + (modelData.wins === 1 ? " win" : " wins") : ""
            foreground: root.fg
            fontFamily: root.fontFamily
          }
        }

        // The always-visible driver, when the top five does not include them.
        StandingRow {
          readonly property var pin: root.dataSvc.standingsView.pinned
          visible: pin !== null
          width: parent.width
          pinned: true
          position: pin ? pin.position : 0
          name: pin ? pin.fullName : ""
          code: pin ? pin.code : ""
          teamName: pin ? pin.constructorName : ""
          teamColor: pin ? root.teamColor(pin.constructorId, pin.constructorName, "") : Color.accent
          valueText: pin ? pin.points + " pts" : ""
          noteText: pin ? pin.gapToLeader + " pts behind leader" : ""
          foreground: root.fg
          fontFamily: root.fontFamily
        }
      }
    }
  }

  // ====================================================== live view

  Component {
    id: liveView

    Column {
      spacing: Style.space(10)

      // ------------------------------------------- nothing running

      Column {
        width: parent.width
        visible: !root.live.hasLiveSession
        spacing: Style.space(8)

        Text {
          width: parent.width
          text: "No F1 race is currently live."
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          leftPadding: Style.space(4)
        }

        Text {
          width: parent.width
          visible: root.dataSvc.race !== null
          text: {
            if (!root.dataSvc.race) return ""
            var next = F1Model.nextSession(root.dataSvc.race, root.now)
            if (!next) return root.dataSvc.race.name + " has finished."
            return root.dataSvc.race.name + " · " + next.name + " starts "
              + root.fmtDayTime(next.startAt) + " — in " + root.countdownTo(next.startAt) + "."
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          leftPadding: Style.space(4)
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          text: "Turn live mode off to return to the race overview."
          color: root.dimmer
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          leftPadding: Style.space(4)
        }
      }

      // --------------------------------------------- live dashboard

      Column {
        width: parent.width
        visible: root.live.hasLiveSession
        spacing: Style.space(10)

        // Session identity, flag state, lap counter, freshness.
        Item {
          width: parent.width
          height: Math.max(lapBlock.implicitHeight, liveMeta.implicitHeight)

          Row {
            id: lapBlock
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(12)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: {
                if (root.live.currentLap <= 0) return "LAP —"
                if (root.live.totalLaps > 0) return "LAP " + root.live.currentLap + " / " + root.live.totalLaps
                return "LAP " + root.live.currentLap
              }
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            StatusChip {
              anchors.verticalCenter: parent.verticalCenter
              text: root.live.status.label
              tone: root.live.status.kind === "green" ? "accent"
                : root.live.status.kind === "finished" ? "done"
                : "warn"
              foreground: root.fg
              fontFamily: root.fontFamily
              filled: true
            }
          }

          Column {
            id: liveMeta
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              anchors.right: parent.right
              text: root.live.sessionName + (root.dataSvc.race ? " · " + root.dataSvc.race.name : "")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // Freshness, measured from the newest timestamp in the feed itself.
            Text {
              anchors.right: parent.right
              text: {
                if (root.live.lastUpdateAt <= 0) return "Connecting…"
                var prefix = root.live.delayed ? "Delayed • " : "Live • "
                return prefix + "Updated " + root.agoOf(root.live.lastUpdateAt)
              }
              color: root.live.delayed ? Color.urgent : root.dimmer
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Text {
          width: parent.width
          visible: root.live.lastError !== ""
          text: root.live.lastError
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          leftPadding: Style.space(4)
        }

        PanelSeparator { width: parent.width }

        // Column headings, so the two gap columns are never ambiguous.
        Item {
          width: parent.width
          height: headings.implicitHeight
          visible: root.live.hasData

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            text: "POS  DRIVER"
            color: root.dimmer
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 0.8
          }

          Row {
            id: headings
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(14)

            Text {
              width: Style.space(26)
              horizontalAlignment: Text.AlignRight
              text: "PIT"
              color: root.dimmer
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              width: Style.space(72)
              horizontalAlignment: Text.AlignRight
              text: "INTERVAL"
              color: root.dimmer
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              width: Style.space(72)
              horizontalAlignment: Text.AlignRight
              text: "LEADER"
              color: root.dimmer
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Text {
          width: parent.width
          visible: !root.live.hasData
          text: root.live.polling ? "Waiting for the first timing update…" : "No timing data available yet."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          leftPadding: Style.space(4)
        }

        Column {
          width: parent.width
          spacing: 0

          Repeater {
            model: root.live.grid

            LiveRow {
              required property var modelData
              width: parent.width
              entry: modelData
              teamColor: root.teamColor("", modelData.teamName, modelData.teamColour)
              foreground: root.fg
              fontFamily: root.fontFamily
            }
          }
        }
      }
    }
  }
}
