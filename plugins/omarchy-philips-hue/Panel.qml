import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "HueApi.js" as HueApi

Panel {
  id: root
  moduleName: "omarchy-philips-hue"
  ipcTarget: "omarchy-philips-hue"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property var config: null
  property string currentThemeName: ""
  property var lightsById: ({})
  property var rooms: []
  property var roomsWithLights: []
  property var orphanLights: []
  property var expandedRooms: ({})
  property int pendingFetches: 0
  property bool loading: false
  property bool lastFetchFailed: false
  property var actionQueue: []

  readonly property int roomCount: root.roomsWithLights.length
  readonly property int lightTotal: root.lightsTotal()
  readonly property int lightedRoomCount: root.lightedRooms().length
  readonly property bool allLightsOn: root.computeAllLightsOn()
  readonly property bool allRoomsExpanded: {
    if (root.roomCount === 0) return false
    for (var i = 0; i < root.roomsWithLights.length; i++) {
      if (root.expandedRooms[root.roomsWithLights[i].id] !== true) return false
    }
    return true
  }
  readonly property bool insecureMode: root.config !== null && !root.config.bridgeId

  function isRoomExpanded(roomId) {
    return root.expandedRooms[roomId] === true
  }

  function toggleRoomExpanded(roomId) {
    var er = Object.assign({}, root.expandedRooms)
    er[roomId] = !root.isRoomExpanded(roomId)
    root.expandedRooms = er
  }

  function toggleAllExpanded() {
    var shouldExpand = !root.allRoomsExpanded
    var er = {}
    for (var i = 0; i < root.roomsWithLights.length; i++) {
      er[root.roomsWithLights[i].id] = shouldExpand
    }
    root.expandedRooms = er
  }

  readonly property string statusText: {
    if (root.config === null) return "Not paired"
    if (root.lastFetchFailed) return "Bridge unreachable"
    if (root.loading) return "Loading…"
    var roomLabel = root.roomCount + " room" + (root.roomCount === 1 ? "" : "s")
    return roomLabel + " · " + root.lightTotal + " light" + (root.lightTotal === 1 ? "" : "s")
  }

  function computeAllLightsOn() {
    if (root.lightedRoomCount === 0) return false
    var rooms = root.lightedRooms()
    for (var i = 0; i < rooms.length; i++) {
      if (!rooms[i].on) return false
    }
    return true
  }

  function lightedRooms() {
    var result = []
    for (var i = 0; i < root.roomsWithLights.length; i++) {
      if (root.roomsWithLights[i].lightCount > 0) result.push(root.roomsWithLights[i])
    }
    return result
  }

  function lightsTotal() {
    var total = 0
    for (var i = 0; i < root.roomsWithLights.length; i++) {
      total += root.roomsWithLights[i].lightCount
    }
    return total + root.orphanLights.length
  }

  function open() {
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    root.controller.show()
    root.refresh()
  }

  function close() {
    root.controller.hide()
  }

  function refresh() {
    if (!root.config) {
      configFile.reload()
      return
    }
    root.lastFetchFailed = false
    if (root.roomsWithLights.length === 0 && root.orphanLights.length === 0) root.loading = true
    lightsProc.running = false
    groupsProc.running = false
    Qt.callLater(startFetches)
  }

  function startFetches() {
    if (!root.config) return
    root.pendingFetches = 2
    lightsProc.command = HueApi.apiCmd(["get-lights"])
    groupsProc.command = HueApi.apiCmd(["get-groups"])
    lightsProc.running = true
    groupsProc.running = true
  }

  function finishFetch(success) {
    root.pendingFetches--
    if (success === false) root.lastFetchFailed = true
    if (root.pendingFetches <= 0) {
      root.loading = false
      root.assembleRooms()
    }
  }

  function assembleRooms() {
    var used = {}
    var result = []
    for (var i = 0; i < root.rooms.length; i++) {
      var room = root.rooms[i]
      var lights = HueApi.roomLights(room, root.lightsById)
      for (var j = 0; j < room.lightIds.length; j++) used[room.lightIds[j]] = true
      result.push({ id: room.id, name: room.name, on: room.on, lightCount: lights.length, lights: lights })
    }
    var orphans = []
    for (var id in root.lightsById) {
      if (!used[id]) orphans.push(root.lightsById[id])
    }
    root.roomsWithLights = result
    root.orphanLights = orphans
  }

  function lightClone(light, changes) {
    return {
      id: light.id,
      name: light.name,
      on: changes.on !== undefined ? changes.on : light.on,
      bri: changes.bri !== undefined ? changes.bri : light.bri,
      hasBri: light.hasBri,
      ct: changes.ct !== undefined ? changes.ct : light.ct,
      hasCt: light.hasCt,
      hue: changes.hue !== undefined ? changes.hue : light.hue,
      sat: changes.sat !== undefined ? changes.sat : light.sat,
      hasColor: light.hasColor,
      pickerOpen: changes.pickerOpen !== undefined ? changes.pickerOpen : light.pickerOpen
    }
  }

  function lightCopy(light, on) {
    return root.lightClone(light, { on: on })
  }

  function setRoomOn(roomId, on) {
    var newRooms = []
    for (var i = 0; i < root.roomsWithLights.length; i++) {
      var room = root.roomsWithLights[i]
      newRooms.push({
        id: room.id,
        name: room.name,
        on: room.id === roomId ? on : room.on,
        lightCount: room.lightCount,
        lights: room.id === roomId
          ? room.lights.map(function(light) { return root.lightCopy(light, on) })
          : room.lights
      })
    }
    root.roomsWithLights = newRooms
  }

  function setLightOn(lightId, on) {
    var newRooms = []
    for (var i = 0; i < root.roomsWithLights.length; i++) {
      var room = root.roomsWithLights[i]
      newRooms.push({
        id: room.id,
        name: room.name,
        on: room.on,
        lightCount: room.lightCount,
        lights: room.lights.map(function(light) {
          return light.id === lightId ? root.lightCopy(light, on) : light
        })
      })
    }
    root.roomsWithLights = newRooms
    root.orphanLights = root.orphanLights.map(function(light) {
      return light.id === lightId ? root.lightCopy(light, on) : light
    })
  }

  function patchLights(lightId, changes) {
    var newRooms = []
    for (var i = 0; i < root.roomsWithLights.length; i++) {
      var room = root.roomsWithLights[i]
      newRooms.push({
        id: room.id,
        name: room.name,
        on: room.on,
        lightCount: room.lightCount,
        lights: room.lights.map(function(light) {
          return light.id === lightId ? root.lightClone(light, changes) : light
        })
      })
    }
    root.roomsWithLights = newRooms
    root.orphanLights = root.orphanLights.map(function(light) {
      return light.id === lightId ? root.lightClone(light, changes) : light
    })
  }

  function setLightBri(lightId, bri) {
    root.patchLights(lightId, { bri: bri })
  }

  function setLightCt(lightId, ct) {
    root.patchLights(lightId, { ct: ct })
  }

  function patchLightColor(lightId, hue, sat) {
    root.patchLights(lightId, { hue: hue, sat: sat })
  }

  function lightById(lightId) {
    for (var i = 0; i < root.roomsWithLights.length; i++) {
      var room = root.roomsWithLights[i]
      for (var j = 0; j < room.lights.length; j++) {
        if (room.lights[j].id === lightId) return room.lights[j]
      }
    }
    for (var k = 0; k < root.orphanLights.length; k++) {
      if (root.orphanLights[k].id === lightId) return root.orphanLights[k]
    }
    return null
  }

  function roomSyncOn(roomId) {
    return root.themeSync[roomId] === true
  }

  function toggleColorPicker(lightId) {
    var light = root.lightById(lightId)
    if (light) root.patchLights(lightId, { pickerOpen: !light.pickerOpen })
  }

  function toggleRoom(roomId, on) {
    if (!root.config) return
    root.setRoomOn(roomId, on)
    root.runAction(HueApi.apiCmd(["put-group", roomId, JSON.stringify({ on: on })]))
    root.scheduleRefresh()
  }

  function toggleLight(lightId, on) {
    if (!root.config) return
    root.setLightOn(lightId, on)
    root.runAction(HueApi.apiCmd(["put-light", lightId, JSON.stringify({ on: on })]))
    root.scheduleRefresh()
  }

  function setBrightness(lightId, bri) {
    if (!root.config) return
    var clamped = Math.max(1, Math.min(254, Math.round(bri)))
    root.setLightBri(lightId, clamped)
    root.runAction(HueApi.apiCmd(["put-light", lightId, JSON.stringify({ bri: clamped })]))
    root.scheduleRefresh()
  }

  function setColorTemperature(lightId, ct) {
    if (!root.config) return
    var clamped = Math.max(153, Math.min(500, Math.round(ct)))
    root.setLightCt(lightId, clamped)
    root.runAction(HueApi.apiCmd(["put-light", lightId, JSON.stringify({ ct: clamped })]))
    root.scheduleRefresh()
  }

  function setLightColor(lightId, hue, sat) {
    if (!root.config) return
    root.patchLightColor(lightId, hue, sat)
    root.runAction(HueApi.apiCmd(["put-light", lightId, JSON.stringify({ hue: hue, sat: sat })]))
    root.scheduleRefresh()
  }

  function toggleAll(on) {
    if (!root.config || root.lightedRoomCount === 0) return
    var rooms = root.lightedRooms()
    var body = JSON.stringify({ on: on })
    for (var i = 0; i < rooms.length; i++) {
      root.runAction(HueApi.apiCmd(["put-group", rooms[i].id, body]))
    }
    root.setAllOn(on)
    root.scheduleRefresh()
  }

  function setAllOn(on) {
    root.roomsWithLights = root.roomsWithLights.map(function(room) {
      if (room.lightCount === 0) return room
      return {
        id: room.id,
        name: room.name,
        on: on,
        lightCount: room.lightCount,
        lights: room.lights.map(function(light) { return root.lightCopy(light, on) })
      }
    })
  }

  function runAction(command) {
    root.actionQueue.push(command)
    drainActionQueue()
  }

  function drainActionQueue() {
    if (actionProc.running) return
    if (root.actionQueue.length === 0) return
    var next = root.actionQueue.shift()
    actionProc.command = next
    actionProc.running = true
  }

  function scheduleRefresh() {
    resyncTimer.restart()
  }

  property FileView configFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/hue.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.config = HueApi.parseConfig(text())
      if (root.config) {
        root.config.username = ""
        root.refresh()
      }
    }
    onLoadFailed: root.config = null
  }

  property FileView themeNameFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme.name"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.currentThemeName = String(text()).trim()
  }

  property var themeSync: ({})
  property FileView themeConfigFile: FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/settings/hue-theme.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        root.themeSync = parsed.themeSync || {}
      } catch (e) {
        root.themeSync = {}
      }
    }
    onLoadFailed: root.themeSync = {}
  }

  Timer {
    interval: 1500
    running: true
    onTriggered: configFile.reload()
  }

  Timer {
    interval: 5000
    repeat: true
    running: root.config === null
    onTriggered: configFile.reload()
  }

  Timer {
    id: resyncTimer
    interval: 700
    onTriggered: root.refresh()
  }

  Timer {
    id: pollTimer
    interval: 15000
    repeat: true
    running: root.config !== null
    onTriggered: root.refresh()
  }

  Process {
    id: lightsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lights = HueApi.parseLights(text)
        var byId = {}
        for (var i = 0; i < lights.length; i++) byId[lights[i].id] = lights[i]
        root.lightsById = byId
        root.finishFetch(true)
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.finishFetch(false)
    }
  }

  Process {
    id: groupsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.rooms = HueApi.parseGroups(text)
        root.finishFetch(true)
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.finishFetch(false)
    }
  }

  Process {
    id: actionProc
    onExited: function(exitCode) {
      root.drainActionQueue()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(540))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        WheelHandler {
          target: scroll
          acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
          onWheel: function(event) {
            var step = 80
            var delta = event.angleDelta.y > 0 ? -step : step
            scroll.contentY = Math.max(0, Math.min(scroll.contentHeight - scroll.height, scroll.contentY + delta))
          }
        }

        Column {
          id: column
          width: scroll.width
          spacing: Style.space(6)

          Row {
            width: parent.width
            spacing: Style.space(10)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "󰌵"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Hue Lights" + (root.currentThemeName ? " (" + root.currentThemeName + ")" : "")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                text: root.statusText
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

          }

          Rectangle {
            width: parent.width
            height: Style.spacing.hairline
            color: root.bar.foreground
            opacity: 0.12
          }

          Column {
            visible: root.config === null
            width: parent.width
            spacing: Style.space(4)

            Text {
              width: parent.width
              text: "No bridge configured yet."
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              text: "Press the link button on your Hue bridge, then click below."
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Rectangle {
              width: parent.width
              height: pairButton.implicitHeight + Style.space(16)
              radius: Style.space(8)
              color: pairButtonMouse.containsMouse ? Qt.lighter(Color.accent, 1.2) : Color.accent

              Text {
                id: pairButton
                anchors.centerIn: parent
                text: "Pair with bridge"
                color: "#ffffff"
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              MouseArea {
                id: pairButtonMouse
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                hoverEnabled: true
                onClicked: {
                  var pairPath = Qt.resolvedUrl("pair.sh").toString().replace("file://", "")
                  Quickshell.execDetached(["omarchy-launch-terminal", "bash", pairPath])
                }
              }
            }
          }

          Row {
            visible: root.config !== null && root.loading && root.roomCount === 0 && root.orphanLights.length === 0
            spacing: Style.space(4)

            Text {
              text: "󰦖"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body

              RotationAnimator on rotation {
                running: root.loading
                from: 0
                to: 360
                duration: 800
                loops: Animation.Infinite
              }
            }

            Text {
              text: "Loading…"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          Text {
            visible: root.config !== null && root.lastFetchFailed && !root.loading
            width: parent.width
            text: "Couldn't reach the bridge. Check the bridge is on and the IP is still valid, then re-run pair.sh."
            color: Color.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.insecureMode
            width: parent.width
            text: "TLS verification disabled. Re-run pair.sh to secure the connection."
            color: Color.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          BorderSurface {
            visible: root.config !== null && root.lightedRoomCount > 0
            width: parent.width
            implicitHeight: Style.space(48)
            radius: Style.cornerRadius
            color: Style.controlFill(false, allLightsMouse.containsMouse, root.bar.foreground, Color.accent)
            borderSpec: Border.controlSpec(allLightsMouse.containsMouse ? "hover-cursor" : "normal", root.bar.foreground, Color.accent)

            MouseArea {
              id: allLightsMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleAll(!root.allLightsOn)
            }

            Row {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "󰌵"
                color: root.allLightsOn ? Color.accent : Qt.darker(root.bar.foreground, 1.6)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                  text: "All Lights"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  text: root.lightTotal + " lights in " + root.roomCount + " rooms"
                  color: Qt.darker(root.bar.foreground, 1.6)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Row {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              // Expand / Collapse All Pill
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(24)
                width: expandAllText.implicitWidth + Style.space(14)
                radius: Style.space(12)
                color: expandAllMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.05)
                border.width: 1
                border.color: Qt.darker(root.bar.foreground, 1.8)

                Row {
                  id: expandAllText
                  anchors.centerIn: parent
                  spacing: Style.space(4)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.allRoomsExpanded ? "󰅂" : "󰅀"
                    color: Qt.darker(root.bar.foreground, 1.3)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.allRoomsExpanded ? "Collapse all" : "Expand all"
                    color: Qt.darker(root.bar.foreground, 1.3)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                MouseArea {
                  id: expandAllMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleAllExpanded()
                }
              }

              ToggleSwitch {
                anchors.verticalCenter: parent.verticalCenter
                checked: root.allLightsOn
                foreground: root.bar.foreground
                accent: Color.accent
                onToggled: root.toggleAll(!root.allLightsOn)
              }
            }
          }

          Column {
            visible: root.config !== null && root.roomCount > 0
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.roomsWithLights

              Column {
                id: roomColumn
                required property var modelData
                width: parent.width
                spacing: Style.space(4)

                readonly property bool isExpanded: root.isRoomExpanded(modelData.id)
                readonly property bool themeSynced: root.roomSyncOn(modelData.id)

                // --- Room Header Card ---
                BorderSurface {
                  width: parent.width
                  implicitHeight: Style.space(44)
                  radius: Style.cornerRadius
                  color: Style.controlFill(false, roomHeaderMouse.containsMouse, root.bar.foreground, Color.accent)
                  borderSpec: Border.controlSpec(roomHeaderMouse.containsMouse ? "hover-cursor" : "normal", root.bar.foreground, Color.accent)

                  MouseArea {
                    id: roomHeaderMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleRoomExpanded(roomColumn.modelData.id)
                  }

                  Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: roomColumn.isExpanded ? "󰅀" : "󰅂"
                      color: Qt.darker(root.bar.foreground, 1.3)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                    }

                    Column {
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: 1

                      Text {
                        text: modelData.name
                        color: modelData.on ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.5)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                      }

                      Text {
                        text: modelData.lightCount + (modelData.lightCount === 1 ? " light" : " lights")
                        color: Qt.darker(root.bar.foreground, 1.6)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }

                  Row {
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    // Theme Sync Pill Button
                    Rectangle {
                      visible: modelData.on
                      anchors.verticalCenter: parent.verticalCenter
                      height: Style.space(22)
                      width: syncText.implicitWidth + Style.space(14)
                      radius: Style.space(11)
                      color: roomColumn.themeSynced ? Util.alpha(Color.accent, 0.25) : Qt.rgba(1, 1, 1, 0.06)
                      border.width: 1
                      border.color: roomColumn.themeSynced ? Color.accent : Qt.darker(root.bar.foreground, 1.8)

                      Row {
                        id: syncText
                        anchors.centerIn: parent
                        spacing: Style.space(3)

                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          text: "󰚌"
                          color: roomColumn.themeSynced ? Color.accent : Qt.darker(root.bar.foreground, 1.4)
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.caption
                        }

                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          text: "Sync"
                          color: roomColumn.themeSynced ? Color.accent : Qt.darker(root.bar.foreground, 1.4)
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: roomColumn.themeSynced
                        }
                      }

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          var ts = JSON.parse(JSON.stringify(root.themeSync))
                          ts[roomColumn.modelData.id] = !roomColumn.themeSynced
                          root.themeSync = ts
                          actionProc.command = HueApi.apiCmd(["write-theme-config", JSON.stringify(ts)])
                          actionProc.running = true
                        }
                      }
                    }

                    // Room Master Switch
                    ToggleSwitch {
                      anchors.verticalCenter: parent.verticalCenter
                      checked: modelData.on
                      foreground: root.bar.foreground
                      accent: Color.accent
                      onToggled: root.toggleRoom(modelData.id, !modelData.on)
                    }
                  }
                }

                // --- Nested Lights List ---
                Column {
                  visible: roomColumn.isExpanded
                  width: parent.width
                  spacing: Style.space(4)

                  Repeater {
                    model: modelData.lights

                    BorderSurface {
                      id: lightCard
                      required property var modelData
                      width: parent.width
                      implicitHeight: lightCol.implicitHeight + Style.space(8)
                      radius: Style.cornerRadius
                      color: Qt.rgba(0, 0, 0, 0.22)
                      borderSpec: Border.controlSpec("normal", Qt.darker(root.bar.foreground, 1.9), Color.accent)

                      Column {
                        id: lightCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Style.space(6)
                        spacing: Style.space(4)

                        // Main Inline Row: Icon + Name + Brightness Slider + HSV Icon + Switch
                        Item {
                          width: parent.width
                          implicitHeight: Style.space(30)

                          // Left: Icon + Name
                          Row {
                            id: lightInfo
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Style.space(6)
                            width: Style.space(135)

                            Text {
                              anchors.verticalCenter: parent.verticalCenter
                              text: "󰌵"
                              color: modelData.on ? Color.accent : Qt.darker(root.bar.foreground, 2.0)
                              font.family: root.bar.fontFamily
                              font.pixelSize: Style.font.body
                            }

                            Text {
                              anchors.verticalCenter: parent.verticalCenter
                              width: parent.width - Style.space(22)
                              text: modelData.name
                              color: modelData.on ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.6)
                              font.family: root.bar.fontFamily
                              font.pixelSize: Style.font.body
                              elide: Text.ElideRight
                            }
                          }

                          // Middle: Brightness Slider + Percentage (when on)
                          Row {
                            visible: modelData.on && modelData.hasBri
                            anchors.left: lightInfo.right
                            anchors.right: lightControlsRow.left
                            anchors.leftMargin: Style.space(6)
                            anchors.rightMargin: Style.space(6)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Style.space(4)

                            Text {
                              anchors.verticalCenter: parent.verticalCenter
                              text: "󰃟"
                              color: Qt.darker(root.bar.foreground, 1.5)
                              font.family: root.bar.fontFamily
                              font.pixelSize: Style.font.caption
                            }

                            HueSlider {
                              anchors.verticalCenter: parent.verticalCenter
                              width: parent.width - Style.space(48)
                              bar: root.bar
                              minimum: 1
                              maximum: 254
                              integer: true
                              step: 10
                              value: modelData.bri
                              onReleased: function(v) { root.setBrightness(modelData.id, v) }
                            }

                            Text {
                              anchors.verticalCenter: parent.verticalCenter
                              width: Style.space(28)
                              text: Math.round((modelData.bri / 254) * 100) + "%"
                              color: Qt.darker(root.bar.foreground, 1.4)
                              font.family: root.bar.fontFamily
                              font.pixelSize: Style.font.caption
                              horizontalAlignment: Text.AlignRight
                              font.bold: true
                            }
                          }

                          // Right: HSV Color Wheel Icon + ToggleSwitch
                          Row {
                            id: lightControlsRow
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Style.space(8)

                            Item {
                              visible: modelData.on && modelData.hasColor && !roomColumn.themeSynced
                              anchors.verticalCenter: parent.verticalCenter
                              width: Style.space(20)
                              height: Style.space(20)

                              Image {
                                anchors.fill: parent
                                source: Qt.resolvedUrl("hsv_wheel.png")
                                fillMode: Image.Stretch
                                smooth: true
                              }

                              Rectangle {
                                anchors.fill: parent
                                radius: Style.space(10)
                                border.width: modelData.pickerOpen ? 2 : 1
                                border.color: modelData.pickerOpen ? Color.accent : Qt.darker(root.bar.foreground, 1.6)
                                color: "transparent"
                              }

                              MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.toggleColorPicker(modelData.id)
                              }
                            }

                            ToggleSwitch {
                              anchors.verticalCenter: parent.verticalCenter
                              checked: modelData.on
                              foreground: root.bar.foreground
                              accent: Color.accent
                              onToggled: root.toggleLight(modelData.id, !modelData.on)
                            }
                          }
                        }

                        // Color Temperature Row (compact, when supported)
                        Row {
                          visible: modelData.on && modelData.hasCt && !roomColumn.themeSynced
                          width: parent.width
                          anchors.leftMargin: Style.space(140)
                          spacing: Style.space(6)

                          Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "󰃠"
                            color: Qt.darker(root.bar.foreground, 1.5)
                            font.family: root.bar.fontFamily
                            font.pixelSize: Style.font.caption
                          }

                          HueSlider {
                            width: parent.width - Style.space(200)
                            anchors.verticalCenter: parent.verticalCenter
                            bar: root.bar
                            minimum: 153
                            maximum: 500
                            integer: true
                            step: 10
                            value: modelData.ct
                            onReleased: function(v) { root.setColorTemperature(modelData.id, v) }
                          }

                          Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Temp"
                            color: Qt.darker(root.bar.foreground, 1.6)
                            font.family: root.bar.fontFamily
                            font.pixelSize: Style.font.caption
                          }
                        }

                        // Color Wheel (expands below when pickerOpen)
                        ColorWheel {
                          lightOn: modelData.on
                          hasColor: modelData.hasColor
                          pickerOpen: modelData.pickerOpen
                          themeSynced: roomColumn.themeSynced
                          initialHue: modelData.hue
                          initialSat: modelData.sat
                          onColorSelected: function(hue, sat) { root.setLightColor(modelData.id, hue, sat) }
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          Column {
            visible: root.config !== null && root.orphanLights.length > 0
            width: parent.width
            spacing: Style.space(4)

            Text {
              text: "OTHER LIGHTS"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
              font.bold: true
            }

            Repeater {
              model: root.orphanLights

              BorderSurface {
                id: orphanCard
                required property var modelData
                width: parent.width
                implicitHeight: orphanCol.implicitHeight + Style.space(8)
                radius: Style.cornerRadius
                color: Qt.rgba(0, 0, 0, 0.22)
                borderSpec: Border.controlSpec("normal", Qt.darker(root.bar.foreground, 1.9), Color.accent)

                Column {
                  id: orphanCol
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.margins: Style.space(6)
                  spacing: Style.space(4)

                  Item {
                    width: parent.width
                    implicitHeight: Style.space(30)

                    Row {
                      id: orphanInfo
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(6)
                      width: Style.space(135)

                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "󰌵"
                        color: modelData.on ? Color.accent : Qt.darker(root.bar.foreground, 2.0)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.body
                      }

                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - Style.space(22)
                        text: modelData.name
                        color: modelData.on ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.6)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.body
                        elide: Text.ElideRight
                      }
                    }

                    Row {
                      visible: modelData.on && modelData.hasBri
                      anchors.left: orphanInfo.right
                      anchors.right: orphanControlsRow.left
                      anchors.leftMargin: Style.space(6)
                      anchors.rightMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(4)

                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "󰃟"
                        color: Qt.darker(root.bar.foreground, 1.5)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      HueSlider {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - Style.space(48)
                        bar: root.bar
                        minimum: 1
                        maximum: 254
                        integer: true
                        step: 10
                        value: modelData.bri
                        onReleased: function(v) { root.setBrightness(modelData.id, v) }
                      }

                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(28)
                        text: Math.round((modelData.bri / 254) * 100) + "%"
                        color: Qt.darker(root.bar.foreground, 1.4)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        horizontalAlignment: Text.AlignRight
                        font.bold: true
                      }
                    }

                    Row {
                      id: orphanControlsRow
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(8)

                      Item {
                        visible: modelData.on && modelData.hasColor
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(20)
                        height: Style.space(20)

                        Image {
                          anchors.fill: parent
                          source: Qt.resolvedUrl("hsv_wheel.png")
                          fillMode: Image.Stretch
                          smooth: true
                        }

                        Rectangle {
                          anchors.fill: parent
                          radius: Style.space(10)
                          border.width: modelData.pickerOpen ? 2 : 1
                          border.color: modelData.pickerOpen ? Color.accent : Qt.darker(root.bar.foreground, 1.6)
                          color: "transparent"
                        }

                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.toggleColorPicker(modelData.id)
                        }
                      }

                      ToggleSwitch {
                        anchors.verticalCenter: parent.verticalCenter
                        checked: modelData.on
                        foreground: root.bar.foreground
                        accent: Color.accent
                        onToggled: root.toggleLight(modelData.id, !modelData.on)
                      }
                    }
                  }

                  Row {
                    visible: modelData.on && modelData.hasCt
                    width: parent.width
                    anchors.leftMargin: Style.space(140)
                    spacing: Style.space(6)

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "󰃠"
                      color: Qt.darker(root.bar.foreground, 1.5)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    HueSlider {
                      width: parent.width - Style.space(200)
                      anchors.verticalCenter: parent.verticalCenter
                      bar: root.bar
                      minimum: 153
                      maximum: 500
                      integer: true
                      step: 10
                      value: modelData.ct
                      onReleased: function(v) { root.setColorTemperature(modelData.id, v) }
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Temp"
                      color: Qt.darker(root.bar.foreground, 1.6)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  ColorWheel {
                    lightOn: modelData.on
                    hasColor: modelData.hasColor
                    pickerOpen: modelData.pickerOpen
                    initialHue: modelData.hue
                    initialSat: modelData.sat
                    onColorSelected: function(hue, sat) { root.setLightColor(modelData.id, hue, sat) }
                  }
                }
              }
            }
          }

          Text {
            visible: root.config !== null && !root.loading && !root.lastFetchFailed && root.roomCount === 0 && root.orphanLights.length === 0
            text: "No lights found on this bridge."
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
