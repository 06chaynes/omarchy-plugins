import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Omaherd's inbox, built to be glanced at: a thin meter and one line say how
// the herd is doing, then the agents that want a person, each on one line
// with its task underneath. Everything that is merely true — quiet agents,
// the machines being watched, hosts that could be added — folds behind a
// single row until asked for. The keyboard cursor walks the same rows.
//
// The header and key hints are pinned; only the rows scroll.
Panel {
  id: root
  moduleName: "io.github.salemsayed.omaherd"
  ipcTarget: "io.github.salemsayed.omaherd.panel"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property alias service: herdr
  property bool cursorActive: false
  property int selectedIndex: 0
  property string selectedKey: ""
  property bool _cursorRestoreScheduled: false
  property bool manualEditing: false
  property string manualError: ""
  // The field lives inside a row the repeater creates on demand; it signs in
  // here so the key catcher and the submit path can reach it when it exists.
  property var manualField: null
  // The reply field, like the manual field, lives in a row and signs in.
  property var replyField: null
  property string replyKey: ""
  // Folds. Both start closed; the host chooser opens itself when there is
  // nothing else to show, because then adding a host is the whole point.
  property bool quietExpanded: false
  property bool hostsExpanded: false

  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  // `dim` is the shell's house tone for secondary text, and it earns that on
  // dark themes. It is the wrong tool for a quiet *mark*: darkening a light
  // theme's ink makes the mark louder, so an idle dot would outweigh a
  // working one. Fading toward the surface is quieter on either theme.
  readonly property color faint: Util.alpha(foreground, 0.35)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // "attention" sorts the whole herd by who wants a person; "host" keeps
  // HerdR's own grouping by machine. G flips it and the choice persists.
  readonly property string groupMode:
    String(root.setting("groupBy", "Attention")).toLowerCase() === "host" ? "host" : "attention"
  readonly property var ignoredHosts: Model.ignoredHostList(root.setting("ignoredHosts", ""))
  readonly property var sections: Model.agentSections(herdr.agents, groupMode)
  readonly property var connections: Model.visibleConnections(herdr.connections, ignoredHosts)
  readonly property var rows: Model.panelRows(sections, connections,
    { quietExpanded: quietExpanded, hostsExpanded: hostsExpanded })
  readonly property int rowCount: rows.length
  readonly property bool multiHost: Model.hostCount(herdr) > 1
  readonly property var segments: Model.herdSegments(herdr.counts)
  readonly property var legend: Model.herdLegend(herdr.counts)
  readonly property int total: Number(herdr.counts.total || 0)

  onRowsChanged: scheduleCursorRestore()

  // Working is the one state with no color of its own, so it gets the one
  // thing no static row can fake. Every working mark reads this single clock
  // rather than starting its own: they breathe together, and a status refresh
  // rebuilding the rows underneath cannot knock any of them out of step.
  property real breath: 1.0

  SequentialAnimation on breath {
    running: root.opened
    loops: Animation.Infinite
    NumberAnimation { to: 0.5; duration: 950; easing.type: Easing.InOutQuad }
    NumberAnimation { to: 1.0; duration: 950; easing.type: Easing.InOutQuad }
  }

  function open() {
    controller.show()
    herdr.refresh(true)
    Qt.callLater(function() { if (opened) keyCatcher.forceActiveFocus() })
  }

  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function rowAt(index) { return index >= 0 && index < rowCount ? rows[index] : null }
  function selectedRow() { return rowAt(selectedIndex) }

  function clampCursor() {
    selectedIndex = rowCount > 0 ? Math.max(0, Math.min(rowCount - 1, selectedIndex)) : 0
    rememberCursor()
  }

  function rememberCursor() {
    var row = selectedRow()
    selectedKey = row ? String(row.key || "") : ""
  }

  // Rows are rebuilt on every poll and every fold; the cursor follows the
  // row's key rather than its number, so it stays on the same agent.
  function scheduleCursorRestore() {
    if (_cursorRestoreScheduled) return
    _cursorRestoreScheduled = true
    Qt.callLater(function() {
      root._cursorRestoreScheduled = false
      var restored = Model.rowIndex(root.rows, root.selectedKey)
      if (restored >= 0) root.selectedIndex = restored
      else root.clampCursor()
      root.rememberCursor()
    })
  }

  function moveCursor(dx, dy) {
    var step = dy !== 0 ? dy : dx
    if (step === 0) return
    cursorActive = true
    if (rowCount === 0) selectedIndex = 0
    else selectedIndex = Math.max(0, Math.min(rowCount - 1,
      selectedIndex + (step < 0 ? -1 : 1)))
    rememberCursor()
  }

  function selectItem(index) {
    cursorActive = true
    selectedIndex = index
    rememberCursor()
  }

  function selectKey(key) {
    var index = Model.rowIndex(rows, key)
    if (index >= 0) selectItem(index)
  }

  function saveSettings(next) {
    root.settings = Object.assign({}, root.settings, next)
    if (root.bar && root.bar.shell)
      root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  function monitorHost(host) {
    var target = String(host || "").trim()
    if (!Model.validRemoteTarget(target)) return false
    if (!herdr.isMonitored(target)) {
      var hosts = herdr.remoteHosts()
      if (hosts.length >= 8) {
        manualError = "Omaherd can monitor up to 8 remote hosts"
        return false
      }
      hosts.push(target)
      saveSettings({ remoteHosts: hosts.join(","),
        ignoredHosts: ignoredHosts.filter(function(entry) { return entry !== target }).join(",") })
    }
    herdr.refresh(true)
    return true
  }

  function unmonitorHost(host) {
    var target = String(host || "").trim()
    var hosts = herdr.remoteHosts().filter(function(entry) { return entry !== target })
    if (hosts.length === herdr.remoteHosts().length) return false
    saveSettings({ remoteHosts: hosts.join(",") })
    herdr.refresh(true)
    return true
  }

  // A discovered host the person does not want offered again.
  function hideHost(host) {
    var target = String(host || "").trim()
    if (target === "" || ignoredHosts.indexOf(target) >= 0) return false
    saveSettings({ ignoredHosts: ignoredHosts.concat([target]).join(",") })
    return true
  }

  function toggleGrouping() {
    saveSettings({ groupBy: groupMode === "host" ? "Attention" : "Host" })
    selectedKey = ""
    selectedIndex = 0
    scheduleCursorRestore()
  }

  function isLocalAgent(agent) {
    return !!agent && String(agent.host || "local") === "local"
  }

  // A local host opens in a terminal; an unwatched remote host starts being
  // watched; a watched one opens its session over ssh in a terminal.
  function activateConnection(connection) {
    if (!connection) return
    if (connection.local === true || herdr.isMonitored(connection.host)) {
      herdr.openHerdr(connection)
      close()
    } else {
      monitorHost(connection.host)
    }
  }

  // Enter, by row: bring an agent to the front, unfold a fold, act on a host,
  // or start typing a host.
  function activateCursor() {
    var row = selectedRow()
    if (!row) return
    if (row.kind === "agent") {
      herdr.focusAgent(row.agent)
      close()
    } else if (row.kind === "quiet") {
      quietExpanded = !quietExpanded
    } else if (row.kind === "hosts") {
      hostsExpanded = !hostsExpanded
    } else if (row.kind === "host") {
      activateConnection(row.connection)
    } else if (row.kind === "manual") {
      beginManualConnection()
    }
  }

  // A: always a fresh terminal on the exact pane, even when HerdR is open.
  function attachCursor() {
    var row = selectedRow()
    if (!row || row.kind !== "agent") return
    herdr.attachAgent(row.agent)
    close()
  }

  // X: stop watching a monitored host, or stop being offered a discovered one.
  function deleteCursor() {
    var row = selectedRow()
    if (!row || row.kind !== "host" || !row.connection || row.connection.local === true) return
    if (herdr.isMonitored(row.connection.host)) unmonitorHost(row.connection.host)
    else if (row.connection.discovered === true) hideHost(row.connection.host)
  }

  function beginManualConnection() {
    cursorActive = true
    hostsExpanded = true
    manualEditing = true
    manualError = ""
    Qt.callLater(function() {
      root.selectKey("manual")
      var field = root.manualField
      if (!root.opened || !root.manualEditing || !field || !field.visible) return
      field.forceActiveFocus()
      field.selectAll()
    })
  }

  function cancelManualConnection() {
    manualEditing = false
    manualError = ""
    if (manualField) manualField.text = ""
    keyCatcher.forceActiveFocus()
  }

  function submitManualConnection() {
    var target = String(manualField ? manualField.text || "" : "").trim()
    if (!Model.validRemoteTarget(target)) {
      manualError = "Enter an SSH alias, user@host, or ssh://user@host:port"
      return
    }
    if (monitorHost(target)) {
      manualEditing = false
      if (manualField) manualField.text = ""
      keyCatcher.forceActiveFocus()
    }
  }

  // Rows call this as the cursor lands on them, so the panel never has to
  // find row N inside the repeater.
  function revealItem(item) {
    if (!item || !panelScroll) return
    Qt.callLater(function() {
      if (!root.opened || !item || !panelScroll) return
      try {
        var point = item.mapToItem(panelScroll.contentItem, 0, 0)
        var top = point.y
        var bottom = top + item.height
        var margin = Style.space(8)
        var maximum = Math.max(0, panelScroll.contentHeight - panelScroll.height)
        if (top < panelScroll.contentY + margin)
          panelScroll.contentY = Math.max(0, top - margin)
        else if (bottom > panelScroll.contentY + panelScroll.height - margin)
          panelScroll.contentY = Math.min(maximum, bottom + margin - panelScroll.height)
      } catch (error) {
        // A poll can destroy a repeater row before this deferred reveal.
      }
    })
  }

  // Only blocked and done get a color of their own: those are the two states
  // asking for a person. Working and idle stay in the text tone and let
  // motion — or its absence — do the talking.
  function stateColor(state) {
    var value = String(state || "unknown")
    if (value === "blocked") return urgent
    if (value === "done") return Color.accent
    if (value === "working") return foreground
    return dim
  }

  // The mark carries more weight than the label beside it, so the quiet
  // states fade rather than merely going grey.
  function stateMarkColor(state) {
    var value = String(state || "unknown")
    return value === "idle" || value === "unknown" ? faint : stateColor(value)
  }

  function toneColor(tone) {
    if (tone === "urgent") return urgent
    if (tone === "dim") return dim
    return foreground
  }

  function meterWidths(available) {
    return Model.meterWidths(segments, available, Style.space(6))
  }

  // What Enter would do to the row under the cursor, in the footer's voice.
  function primaryHint() {
    var row = selectedRow()
    if (!row) return ""
    if (row.kind === "agent") return "open"
    if (row.kind === "quiet") return quietExpanded ? "fold" : "unfold"
    if (row.kind === "hosts") return hostsExpanded ? "fold" : "hosts"
    if (row.kind === "manual") return "add host"
    var connection = row.connection
    if (!connection) return ""
    if (connection.local === true) return connection.running ? "attach" : "open"
    return herdr.isMonitored(connection.host) ? "attach" : "monitor"
  }

  function canAttach() {
    var row = selectedRow()
    return !!row && row.kind === "agent"
  }

  function canPeek() {
    return herdr.peekEnabled && canAttach()
  }

  // P: show or hide the agent's last lines under its row.
  function togglePeek() {
    var row = selectedRow()
    if (!canPeek() || !row) return
    if (row.agent && herdr.peekKey === String(row.agent.key || "")) herdr.clearPeek()
    else herdr.peekAgent(row.agent)
  }

  // I: a one-line field under the row; Enter sends, Escape backs out.
  function beginReply() {
    var row = selectedRow()
    if (!canPeek() || !row) return
    replyKey = String(row.key)
    Qt.callLater(function() {
      var field = root.replyField
      if (!root.opened || root.replyKey === "" || !field || !field.visible) return
      field.forceActiveFocus()
    })
  }

  function cancelReply() {
    replyKey = ""
    keyCatcher.forceActiveFocus()
  }

  function submitReply(text) {
    var row = selectedRow()
    if (!row || row.kind !== "agent" || row.key !== replyKey) { cancelReply(); return }
    if (herdr.replyAgent(row.agent, text)) cancelReply()
  }

  function deleteHint() {
    var row = selectedRow()
    if (!row || row.kind !== "host" || !row.connection || row.connection.local === true) return ""
    if (herdr.isMonitored(row.connection.host)) return "stop"
    return row.connection.discovered === true ? "hide" : ""
  }

  function emptyTitle() {
    if (!herdr.installed) return "HerdR isn't installed here"
    if (herdr.statusText === "HerdR is stopped") return "No HerdR server running"
    return "Nothing needs you"
  }

  function emptyDetail() {
    if (!herdr.installed) return "Monitor a machine that runs it below."
    if (herdr.statusText === "HerdR is stopped") return "Start HerdR and its agents show up here."
    return "Omaherd speaks up when an agent needs input or finishes."
  }

  // The one line under the meter: the legend when there is a herd, the
  // status sentence when there is not, and a short error when a poll failed.
  function statusLine() {
    if (herdr.lastError !== "" && total === 0) return herdr.lastError
    return String(herdr.statusText || "")
  }

  implicitWidth: hiddenButton.implicitWidth
  implicitHeight: hiddenButton.implicitHeight

  onOpenedChanged: {
    cursorActive = false
    selectedIndex = 0
    selectedKey = ""
    manualEditing = false
    manualError = ""
    quietExpanded = false
    if (!opened && manualField) manualField.text = ""
    replyKey = ""
    herdr.clearPeek()
    if (opened) {
      hostsExpanded = herdr.agents.length === 0
      if (panelScroll) panelScroll.contentY = 0
      scheduleCursorRestore()
    }
  }

  Service {
    id: herdr
    settings: root.settings
    onAgentsChanged: if (root.opened && herdr.agents.length === 0 && root.total === 0) root.hostsExpanded = true
  }

  BarIconButton {
    id: hiddenButton
    visible: false
    bar: root.bar
    text: ""
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(
      header.implicitHeight + list.implicitHeight + footer.implicitHeight + Style.space(20),
      Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: (root.manualField ? root.manualField.activeFocus === true : false)
        || (root.replyField ? root.replyField.activeFocus === true : false)
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.deleteCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(value) {
        var key = String(value).toLowerCase()
        if (key === "r") herdr.refresh(true)
        else if (key === "a") root.attachCursor()
        else if (key === "p") root.togglePeek()
        else if (key === "i") root.beginReply()
        else if (key === "g") root.toggleGrouping()
        else if (key === "o") {
          herdr.openHerdr(herdr.defaultTarget())
          root.close()
        }
      }

      // ------------------------------------------------------------- pinned
      //
      // The whole herd in one strip: every agent is a slice of the meter,
      // loudest first, and the line under it counts them. No title — the
      // sheep in the bar already said whose panel this is.
      Column {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(6)

        Item {
          id: meter
          width: parent.width
          height: Style.space(4)
          readonly property var widths: root.meterWidths(
            Math.max(0, width - Style.space(2) * Math.max(0, root.segments.length - 1)))

          Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: Util.alpha(root.foreground, 0.08)
            visible: root.segments.length === 0
          }

          Row {
            anchors.fill: parent
            spacing: Style.space(2)

            Repeater {
              model: root.segments

              delegate: Rectangle {
                required property var modelData
                required property int index
                width: meter.widths[index] || 0
                height: parent.height
                radius: height / 2
                color: root.stateMarkColor(modelData.state)
                opacity: modelData.state === "working" ? root.breath : 1.0
                Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
              }
            }
          }
        }

        RowLayout {
          width: parent.width
          spacing: Style.space(6)

          // A poll every few seconds does not deserve an announcement; the
          // line fades a touch while one is in flight.
          Flow {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: Style.space(5)
            opacity: herdr.refreshing ? 0.6 : 1.0
            Behavior on opacity { NumberAnimation { duration: 240 } }

            Text {
              visible: root.segments.length === 0
              text: root.statusLine()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Repeater {
              model: root.legend

              delegate: Row {
                id: legendEntry
                required property var modelData
                required property int index
                readonly property bool loud: Model.stateIsLoud(modelData.state)
                spacing: Style.space(5)

                Text {
                  visible: legendEntry.index > 0
                  anchors.verticalCenter: parent.verticalCenter
                  text: "·"
                  color: root.faint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: legendEntry.modelData.count + " " + legendEntry.modelData.label
                  color: legendEntry.loud ? root.stateColor(legendEntry.modelData.state) : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: legendEntry.loud
                }
              }
            }
          }

          PanelActionButton {
            Layout.alignment: Qt.AlignVCenter
            iconText: root.groupMode === "host" ? "󰒍" : "󰒺"
            tooltipText: root.groupMode === "host"
              ? "Grouped by host · G groups by attention"
              : "Grouped by attention · G groups by host"
            foreground: root.dim
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.toggleGrouping()
          }

          PanelActionButton {
            Layout.alignment: Qt.AlignVCenter
            iconText: "󰑐"
            tooltipText: "Refresh (R)"
            foreground: root.dim
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: herdr.refresh(true)
          }
        }

        // A failed poll with a herd still on screen: one quiet line, not a card.
        Text {
          visible: herdr.lastError !== "" && root.total > 0
          width: parent.width
          text: herdr.lastError
          color: Util.alpha(root.urgent, 0.85)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        PanelSeparator { width: parent.width; foreground: root.foreground }
      }

      Column {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(8)

        PanelSeparator { width: parent.width; foreground: root.foreground }

        Item {
          width: parent.width
          implicitHeight: hints.implicitHeight
          height: implicitHeight

          Row {
            id: hints
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(12)

            KeyHint { cap: "Enter"; label: root.primaryHint(); visible: label !== "" }
            KeyHint { cap: "A"; label: "attach"; visible: root.canAttach() }
            KeyHint { cap: "P"; label: "peek"; visible: root.canPeek() }
            KeyHint { cap: "I"; label: "reply"; visible: root.canPeek() }
            KeyHint { cap: "X"; label: root.deleteHint(); visible: label !== "" }
            KeyHint { cap: "Esc"; label: "close" }
          }
        }
      }

      // ------------------------------------------------------------- scroll
      //
      // The card clips the rows against a hard edge, which looks the same
      // whether the list ends there or merely continues. These two fades
      // answer that: they appear only on the side that has more to show.
      Rectangle {
        anchors.left: panelScroll.left
        anchors.right: panelScroll.right
        anchors.top: panelScroll.top
        height: Style.space(14)
        z: 1
        visible: panelScroll.contentHeight > panelScroll.height
        opacity: panelScroll.atYBeginning ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 140 } }
        gradient: Gradient {
          GradientStop { position: 0.0; color: Color.popups.background }
          GradientStop { position: 1.0; color: Util.alpha(Color.popups.background, 0) }
        }
      }

      Rectangle {
        anchors.left: panelScroll.left
        anchors.right: panelScroll.right
        anchors.bottom: panelScroll.bottom
        height: Style.space(14)
        z: 1
        visible: panelScroll.contentHeight > panelScroll.height
        opacity: panelScroll.atYEnd ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 140 } }
        gradient: Gradient {
          GradientStop { position: 0.0; color: Util.alpha(Color.popups.background, 0) }
          GradientStop { position: 1.0; color: Color.popups.background }
        }
      }

      Flickable {
        id: panelScroll
        anchors.top: header.bottom
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: Style.space(8)
        anchors.bottomMargin: Style.space(8)
        contentWidth: width
        contentHeight: list.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: list
          width: panelScroll.width
          spacing: Style.space(2)

          Column {
            visible: herdr.agents.length === 0
            width: parent.width
            spacing: Style.space(5)

            Item { width: parent.width; height: Style.space(10) }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "󰳆"
              color: Util.alpha(root.foreground, 0.22)
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: root.emptyTitle()
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: root.emptyDetail()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Item { width: parent.width; height: Style.space(10) }
          }

          Repeater {
            model: root.rows

            delegate: Loader {
              id: rowLoader
              required property var modelData
              required property int index
              width: parent.width
              sourceComponent: modelData.kind === "agent" ? agentRowComponent
                : modelData.kind === "quiet" ? quietRowComponent
                : modelData.kind === "hosts" ? hostsRowComponent
                : modelData.kind === "host" ? hostRowComponent
                : manualRowComponent
              onLoaded: {
                item.row = modelData
                item.rowIndex = index
              }
            }
          }
        }
      }
    }
  }

  Component { id: agentRowComponent; AgentRow {} }
  Component { id: quietRowComponent; FoldRow {} }
  Component { id: hostsRowComponent; FoldRow {} }
  Component { id: hostRowComponent; HostRow {} }
  Component { id: manualRowComponent; ManualRow {} }

  // --------------------------------------------------------------- pieces

  // Section label, small caps, above the first row of its section.
  component SectionHeading: Item {
    id: sectionHeading
    property string heading: ""
    property color tone: root.foreground
    property bool first: false
    implicitHeight: headingLabel.implicitHeight + Style.space(first ? 2 : 10)

    PanelSectionHeader {
      id: headingLabel
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      anchors.leftMargin: Style.space(9)
      width: Math.max(0, parent.width - Style.space(18))
      text: sectionHeading.heading
      foreground: sectionHeading.tone
      color: sectionHeading.tone === root.foreground ? Qt.darker(sectionHeading.tone, 1.4) : sectionHeading.tone
      fontFamily: root.fontFamily
      elide: Text.ElideRight
    }
  }

  // Something you can press, as opposed to something that is merely true.
  component ActionChip: BorderSurface {
    id: actionChip
    property string label: ""
    property color tone: Color.accent
    property bool hot: false

    implicitWidth: actionLabel.implicitWidth + Style.space(14)
    implicitHeight: actionLabel.implicitHeight + Style.space(6)
    radius: Style.cornerRadius
    color: Util.alpha(actionChip.tone, actionChip.hot ? 0.18 : 0.07)
    borderSpec: Border.flat(Util.alpha(actionChip.tone, actionChip.hot ? 0.65 : 0.3),
      Math.max(1, Style.space(1)))

    Behavior on color { ColorAnimation { duration: 90 } }

    Text {
      id: actionLabel
      anchors.centerIn: parent
      text: actionChip.label
      color: actionChip.tone
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  component KeyHint: Row {
    id: keyHint
    property string cap: ""
    property string label: ""
    spacing: Style.space(5)

    BorderSurface {
      anchors.verticalCenter: parent.verticalCenter
      implicitWidth: capLabel.implicitWidth + Style.space(10)
      implicitHeight: capLabel.implicitHeight + Style.space(4)
      radius: Style.cornerRadius
      color: Util.alpha(root.foreground, 0.06)
      borderSpec: Border.flat(Util.alpha(root.foreground, 0.22), Math.max(1, Style.space(1)))

      Text {
        id: capLabel
        anchors.centerIn: parent
        text: keyHint.cap
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: keyHint.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // One agent on one line: mark, where it is, how long it has been in its
  // state. The task sits underneath only when it is worth reading — an agent
  // that wants a person — or when the cursor asks.
  component AgentRow: Column {
    id: agentRow
    property var row: null
    property int rowIndex: 0
    readonly property var agent: row ? row.agent : null
    readonly property string agentState: agent ? String(agent.status || "unknown") : "unknown"
    readonly property bool loud: !!row && row.loud === true
    readonly property string task: Model.agentTask(agent)
    readonly property string host: Model.hostChip(agent, root.groupMode, root.multiHost)
    readonly property string since: agent ? Model.sinceLabel(agent.since, herdr.now) : ""
    readonly property bool hasCursor: root.cursorActive && root.selectedIndex === agentRow.rowIndex
    readonly property bool showTask: task !== "" && (loud || hasCursor)
    readonly property bool peeking: !!agent && herdr.peekKey !== "" && herdr.peekKey === String(agent.key || "")
    readonly property bool replying: !!row && root.replyKey === row.key
    onReplyingChanged: if (replying) Qt.callLater(function() { if (agentRow.replying) root.replyField = replyField })
    spacing: 0

    SectionHeading {
      visible: !!agentRow.row && agentRow.row.heading !== ""
      width: parent.width
      heading: agentRow.row ? agentRow.row.heading : ""
      first: agentRow.rowIndex === 0
      tone: agentRow.row && agentRow.row.sectionKey === "attention" ? root.urgent : root.foreground
    }

    CursorSurface {
      id: agentSurface
      width: parent.width
      implicitHeight: agentContent.implicitHeight + Style.space(10)
      hasCursor: agentRow.hasCursor
      foreground: root.foreground
      accent: Color.accent
      onHasCursorChanged: if (hasCursor) root.revealItem(agentSurface)

      Behavior on implicitHeight { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

      ColumnLayout {
        id: agentContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(9)
        anchors.rightMargin: Style.space(9)
        spacing: Style.space(2)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            Layout.preferredWidth: Style.space(12)
            Layout.alignment: Qt.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            text: Model.stateGlyph(agentRow.agentState)
            color: root.stateMarkColor(agentRow.agentState)
            opacity: agentRow.agentState === "working" ? root.breath : 1.0
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // The workspace is the long variable half and gives up width
          // first; the agent's name and host are short and always kept.
          Row {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter

            Text {
              width: Math.min(implicitWidth, Math.max(0, parent.width - agentLabel.implicitWidth))
              text: Model.agentWorkspace(agentRow.agent)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: agentRow.loud
              elide: Text.ElideRight
            }

            Text {
              id: agentLabel
              text: " · " + Model.agentName(agentRow.agent)
                + (agentRow.host !== "" ? " · " + agentRow.host : "")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          Text {
            visible: agentRow.since !== "" && agentRow.since !== "now"
            Layout.alignment: Qt.AlignVCenter
            text: agentRow.since
            color: agentRow.loud ? root.stateColor(agentRow.agentState) : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: agentRow.agentState === "blocked"
          }
        }

        Text {
          visible: agentRow.showTask
          Layout.fillWidth: true
          Layout.leftMargin: Style.space(20)
          text: agentRow.task
          color: agentRow.loud ? Util.alpha(root.foreground, 0.8) : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignLeft
          elide: Text.ElideRight
        }

        // The peek: the pane's last lines, in the pane's own voice. It is a
        // quote, so it sits in a quiet box and never wraps the row's own text.
        BorderSurface {
          visible: agentRow.peeking
          Layout.fillWidth: true
          Layout.leftMargin: Style.space(20)
          Layout.topMargin: Style.space(3)
          implicitHeight: peekLabel.implicitHeight + Style.space(10)
          radius: Style.cornerRadius
          color: Util.alpha(root.foreground, 0.04)
          borderSpec: Border.flat(Util.alpha(root.foreground, 0.14), Math.max(1, Style.space(1)))

          Text {
            id: peekLabel
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(7)
            text: herdr.peekBusy ? "Reading…" : (herdr.peekError !== "" ? herdr.peekError : herdr.peekText)
            color: herdr.peekError !== "" && !herdr.peekBusy ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignLeft
            wrapMode: Text.Wrap
            maximumLineCount: 14
            elide: Text.ElideRight
          }
        }

        // The reply: one line, Enter sends it followed by Enter in the pane.
        RowLayout {
          visible: agentRow.replying
          Layout.fillWidth: true
          Layout.leftMargin: Style.space(20)
          Layout.topMargin: Style.space(3)
          spacing: Style.space(6)

          TextField {
            id: replyField
            Layout.fillWidth: true
            foreground: root.foreground
            placeholderText: "Reply, then Enter"
            verticalPadding: Style.spacing.controlPaddingY
            onAccepted: root.submitReply(text)
            Keys.onEscapePressed: root.cancelReply()
            onVisibleChanged: if (!visible) text = ""
            Component.onCompleted: if (agentRow.replying) root.replyField = replyField
            Component.onDestruction: if (root && root.replyField === replyField) root.replyField = null
          }

          ActionChip {
            Layout.alignment: Qt.AlignVCenter
            label: "Send"
            hot: true

            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              cursorShape: Qt.PointingHandCursor
              onClicked: root.submitReply(replyField.text)
            }
          }
        }
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        cursorShape: Qt.PointingHandCursor
        onEntered: root.selectItem(agentRow.rowIndex)
        onClicked: function(mouse) {
          root.selectItem(agentRow.rowIndex)
          if (mouse.button === Qt.MiddleButton) root.attachCursor()
          else root.activateCursor()
        }
      }
    }
  }

  // A fold: one row standing in for many. QUIET hides the agents nobody is
  // waiting on; HOSTS hides the chooser behind a line that still says
  // which machines are being watched and whether one is down.
  component FoldRow: Column {
    id: foldRow
    property var row: null
    property int rowIndex: 0
    readonly property bool hosts: !!row && row.kind === "hosts"
    readonly property bool expanded: !!row && row.expanded === true
    readonly property bool hasCursor: root.cursorActive && root.selectedIndex === foldRow.rowIndex
    spacing: 0

    Item { width: parent.width; height: Style.space(foldRow.hosts ? 10 : 8) }

    CursorSurface {
      id: foldSurface
      width: parent.width
      implicitHeight: foldContent.implicitHeight + Style.space(10)
      hasCursor: foldRow.hasCursor
      foreground: root.foreground
      accent: Color.accent
      onHasCursorChanged: if (hasCursor) root.revealItem(foldSurface)

      RowLayout {
        id: foldContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(9)
        anchors.rightMargin: Style.space(9)
        spacing: Style.space(8)

        Text {
          Layout.preferredWidth: Style.space(12)
          horizontalAlignment: Text.AlignHCenter
          text: foldRow.expanded ? "󰅀" : "󰅂"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        PanelSectionHeader {
          text: foldRow.hosts ? "HOSTS" : (foldRow.row ? String(foldRow.row.heading || "QUIET") : "QUIET")
          foreground: root.foreground
          fontFamily: root.fontFamily
          topPadding: 0
        }

        // The summary: a count for quiet agents, the watched machines for
        // hosts. An offline host keeps its urgent tone even folded away.
        Row {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          spacing: Style.space(5)
          clip: true

          Repeater {
            model: foldRow.hosts && foldRow.row ? foldRow.row.summary.parts
              : (foldRow.row ? [{ label: Model.agentsLabel(foldRow.row.count), tone: "dim" }] : [])

            delegate: Row {
              id: summaryPart
              required property var modelData
              required property int index
              spacing: Style.space(5)

              Text {
                visible: summaryPart.index > 0
                text: "·"
                color: root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                text: summaryPart.modelData.label
                color: root.toneColor(summaryPart.modelData.tone)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: summaryPart.modelData.tone === "urgent"
              }
            }
          }
        }
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: root.selectItem(foldRow.rowIndex)
        onClicked: {
          root.selectItem(foldRow.rowIndex)
          root.activateCursor()
        }
      }
    }
  }

  component HostRow: CursorSurface {
    id: hostRow
    property var row: null
    property int rowIndex: 0
    readonly property var connection: row ? row.connection : null
    readonly property bool local: !!connection && connection.local === true
    readonly property bool discovered: !!connection && connection.discovered === true
    readonly property bool reachable: !connection || connection.reachable !== false
    readonly property bool monitored: !!connection && !local && herdr.isMonitored(connection.host)
    readonly property string action: local
      ? (connection && connection.running ? "Attach" : "Open")
      : (monitored ? (hasCursor && reachable ? "Attach" : "") : "Monitor")
    readonly property string title: connection
      ? (local ? String(connection.title || "Local") : Model.shortHost(connection.host)) : ""
    readonly property string meta: connection
      ? ((!local && Model.shortHost(connection.host) !== String(connection.host)
          ? String(connection.host) + " · " : "") + String(connection.meta || ""))
      : ""

    implicitHeight: hostContent.implicitHeight + Style.space(10)
    hasCursor: root.cursorActive && root.selectedIndex === hostRow.rowIndex
    foreground: root.foreground
    accent: Color.accent
    onHasCursorChanged: if (hasCursor) root.revealItem(hostRow)

    RowLayout {
      id: hostContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(9)
      anchors.rightMargin: Style.space(9)
      spacing: Style.space(8)

      Text {
        Layout.preferredWidth: Style.space(12)
        Layout.alignment: Qt.AlignVCenter
        horizontalAlignment: Text.AlignHCenter
        text: hostRow.local ? "󰆍" : "󰢹"
        color: hostRow.reachable ? root.dim : Util.alpha(root.urgent, 0.8)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: hostRow.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: hostRow.meta
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // A host already being watched is a fact, not a button, and is written
      // like one. The cursor reveals the ways to act on it.
      Text {
        visible: hostRow.monitored && !hostRow.hasCursor
        Layout.alignment: Qt.AlignVCenter
        text: hostRow.reachable ? "󰄬 Monitoring" : "󰀦 Offline"
        color: hostRow.reachable ? root.dim : root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      ActionChip {
        visible: hostRow.hasCursor && (hostRow.monitored || hostRow.discovered)
        Layout.alignment: Qt.AlignVCenter
        label: hostRow.monitored ? "Stop" : "Hide"
        tone: root.foreground
        hot: false

        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          cursorShape: Qt.PointingHandCursor
          onClicked: root.deleteCursor()
        }
      }

      ActionChip {
        visible: hostRow.action !== ""
        Layout.alignment: Qt.AlignVCenter
        label: hostRow.action
        hot: hostRow.hasCursor
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.selectItem(hostRow.rowIndex)
      onClicked: {
        root.selectItem(hostRow.rowIndex)
        root.activateCursor()
      }
      z: -1
    }
  }

  // The last host slot: same shape as the rows above it, but it grows a
  // field instead of an action when you pick it.
  component ManualRow: CursorSurface {
    id: manualRow
    property var row: null
    property int rowIndex: 0

    width: parent ? parent.width : implicitWidth
    implicitHeight: manualContent.implicitHeight + Style.space(10)
    hasCursor: root.cursorActive && root.selectedIndex === manualRow.rowIndex
    foreground: root.foreground
    accent: Color.accent
    onHasCursorChanged: if (hasCursor) root.revealItem(manualRow)

    ColumnLayout {
      id: manualContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(9)
      anchors.rightMargin: Style.space(9)
      spacing: Style.space(4)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          Layout.preferredWidth: Style.space(12)
          Layout.alignment: Qt.AlignVCenter
          horizontalAlignment: Text.AlignHCenter
          text: "󰐕"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Item {
          Layout.fillWidth: true
          implicitHeight: root.manualEditing ? manualField.implicitHeight : manualLabels.implicitHeight

          Column {
            id: manualLabels
            visible: !root.manualEditing
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              width: parent.width
              text: "Other host…"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: "SSH alias, user@host, or Tailscale name"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          TextField {
            id: manualField
            visible: root.manualEditing
            anchors.fill: parent
            foreground: root.foreground
            placeholderText: "user@host"
            verticalPadding: Style.spacing.controlPaddingY
            onTextChanged: root.manualError = ""
            onAccepted: root.submitManualConnection()
            Keys.onEscapePressed: root.cancelManualConnection()
            Component.onCompleted: root.manualField = manualField
            Component.onDestruction: if (root.manualField === manualField) root.manualField = null
          }
        }

        ActionChip {
          Layout.alignment: Qt.AlignVCenter
          label: "Monitor"
          hot: manualRow.hasCursor

          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            enabled: root.manualEditing
            cursorShape: Qt.PointingHandCursor
            onClicked: root.submitManualConnection()
          }
        }
      }

      Text {
        visible: root.manualError !== ""
        Layout.fillWidth: true
        text: root.manualError
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    MouseArea {
      anchors.fill: parent
      enabled: !root.manualEditing
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.selectItem(manualRow.rowIndex)
      onClicked: root.beginManualConnection()
    }
  }
}
