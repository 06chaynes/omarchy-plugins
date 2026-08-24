import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "io.github.salemsayed.omaherd"
  // Moving a bar widget briefly overlaps its old and replacement instances.
  // Wait for the retired slot to release this process-wide IPC target.
  property bool ipcRegistrationReady: false

  readonly property var service: panelLoader.item ? panelLoader.item.service : null
  readonly property int attentionCount: service ? Number(service.counts.attention || 0) : 0
  readonly property int workingCount: service ? Number(service.counts.working || 0) : 0
  readonly property int totalCount: service ? Number(service.counts.total || 0) : 0
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  // The sheep keeps its own color, always. Whether anyone wants a person is
  // said by the dots beside it — a larger red or blue one — never by the
  // glyph turning into a warning light or a number hanging off it.
  readonly property color iconColor: foreground

  // The herd itself, as marks beside the sheep: one per agent, loudest
  // first. It answers "how many, and how many of them want me" without a
  // click, and the setting turns it off for a bar that wants only the icon.
  readonly property bool herdVisible: Style.boolToken(settings ? settings.barHerd : undefined, true)
    && totalCount > 0
  // Only agents that are doing something — working, or waiting on a person —
  // get a dot; quiet ones are counted in the tooltip and the panel instead.
  // At most six, the loudest first, grouped by machine with the local one
  // leading. Past six the bar says nothing more: the urgent count already
  // carries what matters.
  readonly property var herd: herdVisible && service ? Model.herdDotGroups(service.agents, 6) : { groups: [], overflow: 0 }

  // What is actually drawn. When dots leave, the previous frame's extras
  // stay on as ghosts that shrink away; once that has played the drawn
  // groups settle to the real ones. Arrivals need no ghost: they pop in.
  property var shownGroups: []
  property var _lastHerd: ({ groups: [] })
  property string _lastHerdKey: ""

  // Every poll hands over a new object; only a herd that actually differs
  // may rebuild the dots, or they would pop in again every few seconds.
  onHerdChanged: {
    var key = JSON.stringify(herd.groups)
    if (key === _lastHerdKey) return
    _lastHerdKey = key
    var merged = Model.ghostDotGroups(_lastHerd, herd)
    _lastHerd = herd
    shownGroups = merged
    ghostSettle.restart()
  }

  // Once the arrivals have popped and the ghosts have gone, draw the plain
  // groups so nothing is left flagged for a second animation.
  Timer {
    id: ghostSettle
    interval: 280
    repeat: false
    onTriggered: root.shownGroups = Model.ghostDotGroups(root.herd, root.herd)
  }

  // A ring in the bar's own background lifts the corner marks off the sheep
  // behind them. A transparent bar has no background to borrow, and painting
  // the theme color anyway would draw a halo over whatever wallpaper is
  // showing through, so there the marks stand on their own.
  readonly property bool barIsOpaque: !bar || bar.transparent !== true
  readonly property int markRing: barIsOpaque ? Math.max(1, Style.space(1)) : 0
  readonly property color markRingColor: bar ? bar.background : Color.background

  // One clock for every working mark, in the bar and in the panel alike.
  property real breath: 1.0

  SequentialAnimation on breath {
    running: root.workingCount > 0
    loops: Animation.Infinite
    NumberAnimation { to: 0.35; duration: 950; easing.type: Easing.InOutQuad }
    NumberAnimation { to: 1.0; duration: 950; easing.type: Easing.InOutQuad }
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function refresh() { if (service) service.refresh(true) }
  function poke() { if (service) service.refresh(false) }
  function launch() { if (service) service.openHerdr(service.defaultTarget()) }
  function monitor(host) {
    return panelLoader.item && panelLoader.item.monitorHost(host)
  }
  function unmonitor(host) {
    return panelLoader.item && panelLoader.item.unmonitorHost(host)
  }

  function dotColor(state) {
    if (state === "blocked") return urgentColor
    if (state === "done") return Color.accent
    if (state === "working") return foreground
    return Util.alpha(foreground, 0.35)
  }

  implicitWidth: layout.implicitWidth
  implicitHeight: layout.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  Component.onCompleted: ipcRegistrationTimer.start()

  Timer {
    id: ipcRegistrationTimer
    interval: 100
    onTriggered: root.ipcRegistrationReady = true
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    enabled: root.ipcRegistrationReady
    target: root.moduleName
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    // A bar widget exists once per monitor. IPC reaches one registered
    // handler, so relay collection requests to every live instance through
    // the BarWidget contract instead of leaving secondary bars stale.
    function refresh(): string { root.broadcast("refresh"); return "ok" }
    // What the HerdR hook calls: a plain poll, no host discovery.
    function poke(): string { root.broadcast("poke"); return "ok" }
    function launch(): string { root.launch(); return "ok" }
    function monitor(host: string): string {
      return root.monitor(host) ? "monitoring " + host : "invalid host"
    }
    function unmonitor(host: string): string {
      return root.unmonitor(host) ? "stopped monitoring " + host : "not monitored"
    }
    function status(): string {
      return root.service ? JSON.stringify({
        statusText: root.service.statusText,
        counts: root.service.counts,
        monitoredHosts: root.service.remoteHosts(),
        targets: root.service.targets,
        agents: root.service.agents
      }) : "{}"
    }
  }

  Grid {
    id: layout
    columns: root.vertical ? 1 : 2
    rows: root.vertical ? 2 : 1
    spacing: 0
    verticalItemAlignment: Grid.AlignVCenter
    horizontalItemAlignment: Grid.AlignHCenter

    BarIconButton {
      id: button
      bar: root.bar
      tooltipText: root.service ? Model.tooltip(root.service) : "Checking HerdR…"
      dimmed: root.service ? !root.service.installed && root.service.agents.length === 0 : true
      iconComponent: Component {
        Item {
          SheepIcon {
            anchors.centerIn: parent
            iconSize: Style.bar.iconFont
            color: root.iconColor
            fontFamily: root.fontFamily
          }

          // With the herd drawn beside the sheep, its working dots already
          // breathe; the corner pulse only steps in when the herd is hidden.
          Rectangle {
            visible: !root.herdVisible && root.attentionCount === 0 && root.workingCount > 0
            width: Style.space(6)
            height: width
            radius: width / 2
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(3)
            color: Color.accent
            border.width: root.markRing
            border.color: root.markRingColor
            opacity: root.breath
          }
        }
      }
      onPressed: function(buttonCode) {
        if (buttonCode === Qt.RightButton) root.refresh()
        else if (buttonCode === Qt.MiddleButton) root.launch()
        else root.togglePanel()
      }
    }

    Item {
      id: herdStrip
      readonly property bool showing: root.herdVisible && root.shownGroups.length > 0
      visible: width > 0 || height > 0
      // The strip grows and shrinks instead of snapping, so the widgets to
      // its right glide rather than jump when a dot comes or goes.
      width: showing ? (root.vertical ? Style.bar.iconSlot : dots.implicitWidth + Style.space(6)) : 0
      height: showing ? (root.vertical ? dots.implicitHeight + Style.space(6) : Style.bar.sizeHorizontal) : 0
      clip: true
      Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
      Behavior on height { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

      // One run of dots per host. The gap between runs is the only thing
      // that says "another machine", and it is enough.
      // A dot arriving pops in; dots making room for it slide over. The
      // positioners animate their own children, so a status poll that
      // rebuilds the model still reads as one motion, not a redraw.
      Grid {
        id: dots
        anchors.centerIn: parent
        columns: root.vertical ? 1 : Math.max(1, root.shownGroups.length)
        spacing: Style.space(5)
        verticalItemAlignment: Grid.AlignVCenter
        horizontalItemAlignment: Grid.AlignHCenter
        move: Transition { NumberAnimation { properties: "x,y"; duration: 220; easing.type: Easing.OutCubic } }

        Repeater {
          model: root.shownGroups

          delegate: Grid {
            id: hostGroup
            required property var modelData
            columns: root.vertical ? 1 : Math.max(1, modelData.dots.length)
            spacing: Style.space(2)
            verticalItemAlignment: Grid.AlignVCenter
            horizontalItemAlignment: Grid.AlignHCenter
            move: Transition { NumberAnimation { properties: "x,y"; duration: 220; easing.type: Easing.OutCubic } }

            Repeater {
              model: hostGroup.modelData.dots

              // A dot is steady, fresh (pops in) or a ghost (shrinks out).
              // The animations are started explicitly on creation because a
              // rebuilt delegate has no "previous value" for a Behavior to
              // ease from; the breath is a multiplier on top of either.
              delegate: Rectangle {
                id: dot
                required property var modelData
                readonly property string dotState: String(modelData.state || modelData)
                readonly property bool ghost: modelData.ghost === true
                readonly property bool fresh: modelData.fresh === true
                // Asking for a person earns the bigger dot; working stays small.
                readonly property bool loud: dotState === "blocked" || dotState === "done"
                property real presence: ghost || fresh ? (fresh ? 0.0 : 1.0) : 1.0
                width: Style.space(loud ? 6 : 4)
                height: width
                radius: width / 2
                color: root.dotColor(dotState)
                scale: 0.2 + 0.8 * presence
                opacity: presence * (dotState === "working" ? root.breath : 1.0)
                Behavior on color { ColorAnimation { duration: 180 } }

                NumberAnimation {
                  id: popIn
                  target: dot; property: "presence"; to: 1.0; duration: 240; easing.type: Easing.OutBack
                }
                NumberAnimation {
                  id: ghostOut
                  target: dot; property: "presence"; to: 0.0; duration: 220; easing.type: Easing.InCubic
                }
                Component.onCompleted: {
                  if (dot.ghost) ghostOut.start()
                  else if (dot.fresh) popIn.start()
                }
              }
            }
          }
        }
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        onClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) root.refresh()
          else if (mouse.button === Qt.MiddleButton) root.launch()
          else root.togglePanel()
        }
      }
    }
  }
}
