import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.dlpwaters.retro-library"
  ipcTarget: "io.github.dlpwaters.retro-library"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.58)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.08)
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string helperPath: String(Qt.resolvedUrl("retro-library")).replace(/^file:\/\//, "")
  readonly property int desiredWidth: Style.space(1040)
  readonly property int maximumHeight: Style.space(820)

  property var library: ({})
  property var systems: []
  property var games: []
  property var filteredGames: []
  property string selectedSystem: "__all"
  property string keyboardSection: "games"
  property int selectedIndex: -1
  property var selectedGame: null
  property string selectedCorePath: "auto"
  property bool loading: false
  property bool actionBusy: false
  property string actionKind: ""
  property string listOutput: ""
  property string actionOutput: ""
  property string statusText: ""
  property bool statusError: false
  property string restorePath: ""

  readonly property int totalGames: Number(library.total_games || 0)

  function open() {
    keyboardSection = "games"
    root.controller.show()
    if (games.length === 0) refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.controller.hide() }
  function toggle() { root.opened ? close() : open() }

  function refresh() {
    if (listProc.running) return
    restorePath = selectedGame ? String(selectedGame.path || "") : restorePath
    loading = true
    listOutput = ""
    listProc.running = true
  }

  function parseList(exitCode) {
    loading = false
    var payload = null
    try { payload = JSON.parse(listOutput) } catch (error) {}
    if (exitCode !== 0 || !payload || !payload.ok) {
      showStatus(payload && payload.error ? payload.error : "Could not read the RetroArch playlists.", true)
      return
    }
    library = payload
    systems = payload.systems || []
    games = payload.games || []
    rebuildGames()
  }

  function showStatus(message, error) {
    statusText = String(message || "")
    statusError = error === true
    statusTimer.restart()
  }

  function systemOptions() {
    var result = [
      { id: "__all", short_name: "All games", manufacturer: "LIBRARY", icon: "", glyph: "󰊖", count: totalGames },
      { id: "__favorites", short_name: "Favorites", manufacturer: "YOUR PICKS", icon: "", glyph: "󰓎", count: Number(library.favorite_games || 0) },
      { id: "__recent", short_name: "Recently played", manufacturer: "HISTORY", icon: "", glyph: "󰋚", count: Number(library.recent_games || 0) }
    ]
    for (var i = 0; i < systems.length; i++) result.push(systems[i])
    return result
  }

  function systemForId(id) {
    for (var i = 0; i < systems.length; i++) if (String(systems[i].id) === String(id)) return systems[i]
    return null
  }

  function rebuildGames() {
    var query = searchField.text.trim().toLowerCase()
    var result = []
    for (var i = 0; i < games.length; i++) {
      var game = games[i]
      if (selectedSystem === "__favorites" && !game.favorite) continue
      if (selectedSystem === "__recent" && String(game.last_played || "") === "") continue
      if (selectedSystem.indexOf("__") !== 0 && String(game.system_id) !== selectedSystem) continue
      if (query !== "") {
        var haystack = (String(game.label) + " " + String(game.system_name) + " "
          + String(game.system_short_name) + " " + String(game.core_name)).toLowerCase()
        if (haystack.indexOf(query) === -1) continue
      }
      result.push(game)
    }
    if (selectedSystem === "__recent") {
      result.sort(function(a, b) { return String(b.last_played).localeCompare(String(a.last_played)) })
    } else {
      result.sort(function(a, b) {
        var systemOrder = String(a.system_short_name).localeCompare(String(b.system_short_name))
        return systemOrder !== 0 ? systemOrder : String(a.label).localeCompare(String(b.label))
      })
    }
    filteredGames = result

    var wanted = restorePath
    restorePath = ""
    var index = result.length > 0 ? 0 : -1
    if (wanted !== "") {
      for (var j = 0; j < result.length; j++) {
        if (String(result[j].path) === wanted) { index = j; break }
      }
    }
    selectedIndex = index
    gameList.currentIndex = index
    if (index >= 0) gameList.positionViewAtIndex(index, ListView.Contain)
    syncSelectedGame()
  }

  function syncSelectedGame() {
    selectedGame = selectedIndex >= 0 && selectedIndex < filteredGames.length
      ? filteredGames[selectedIndex] : null
    selectedCorePath = selectedGame && String(selectedGame.override_core_path || "") !== ""
      ? String(selectedGame.override_core_path) : "auto"
  }

  function selectGame(index) {
    if (index < 0 || index >= filteredGames.length) return
    selectedIndex = index
    gameList.currentIndex = index
    gameList.positionViewAtIndex(index, ListView.Contain)
    syncSelectedGame()
  }

  function moveSelection(delta) {
    if (filteredGames.length === 0) return
    var index = selectedIndex + delta
    if (index < 0) index = filteredGames.length - 1
    if (index >= filteredGames.length) index = 0
    selectGame(index)
  }

  function selectedSystemIndex() {
    var options = systemOptions()
    for (var i = 0; i < options.length; i++) {
      if (String(options[i].id) === selectedSystem) return i
    }
    return options.length > 0 ? 0 : -1
  }

  function selectSystem(index) {
    var options = systemOptions()
    if (index < 0 || index >= options.length) return
    selectedSystem = String(options[index].id)
    restorePath = ""
    rebuildGames()
    systemList.positionViewAtIndex(index, ListView.Contain)
  }

  function moveSystemSelection(delta) {
    var options = systemOptions()
    if (options.length === 0) return
    var index = selectedSystemIndex() + delta
    if (index < 0) index = options.length - 1
    if (index >= options.length) index = 0
    selectSystem(index)
  }

  function setKeyboardSection(section) {
    keyboardSection = section === "systems" ? "systems" : "games"
    keyCatcher.forceActiveFocus()
    if (keyboardSection === "systems") {
      var systemIndex = selectedSystemIndex()
      if (systemIndex >= 0) systemList.positionViewAtIndex(systemIndex, ListView.Contain)
    } else if (selectedIndex >= 0) {
      gameList.positionViewAtIndex(selectedIndex, ListView.Contain)
    }
  }

  function moveKeyboardSelection(dx, dy) {
    if (dx < 0) {
      setKeyboardSection("systems")
      return
    }
    if (dx > 0) {
      setKeyboardSection("games")
      return
    }
    if (dy === 0) return
    if (keyboardSection === "systems") moveSystemSelection(dy)
    else moveSelection(dy)
  }

  function activateKeyboardSelection() {
    if (keyboardSection === "systems") setKeyboardSection("games")
    else launchSelected()
  }

  function coreOptions() {
    if (!selectedGame) return []
    var system = systemForId(selectedGame.system_id)
    var automatic = "Automatic · " + String(selectedGame.core_name || system.default_core_name || "playlist core")
    var result = [{ value: "auto", label: automatic }]
    var cores = system && system.cores ? system.cores : []
    for (var i = 0; i < cores.length; i++) result.push({ value: String(cores[i].path), label: String(cores[i].name) })
    return result
  }

  function contentName(path) {
    var archive = String(path || "").split("#")[0]
    var parts = archive.split("/")
    return parts.length > 0 ? parts[parts.length - 1] : archive
  }

  function runAction(kind, args) {
    if (actionProc.running) return
    actionBusy = true
    actionKind = kind
    actionOutput = ""
    var command = [helperPath]
    for (var i = 0; i < args.length; i++) command.push(args[i])
    actionProc.command = command
    actionProc.running = true
  }

  function launchSelected() {
    if (!selectedGame || actionBusy) return
    runAction("launch", ["launch", "--path", String(selectedGame.path), "--core", selectedCorePath])
  }

  function toggleFavorite() {
    if (!selectedGame || actionBusy) return
    restorePath = String(selectedGame.path)
    runAction("favorite", ["favorite", "--path", String(selectedGame.path), "--value", selectedGame.favorite ? "false" : "true"])
  }

  function setCore(path) {
    if (!selectedGame || actionBusy) return
    selectedCorePath = path
    runAction("core", ["set-core", "--path", String(selectedGame.path), "--core", path])
  }

  function finishAction(exitCode) {
    actionBusy = false
    var payload = null
    try { payload = JSON.parse(actionOutput) } catch (error) {}
    if (exitCode !== 0 || !payload || !payload.ok) {
      showStatus(payload && payload.error ? payload.error : "The action could not be completed.", true)
      return
    }
    if (actionKind === "launch") {
      root.close()
    } else if (actionKind === "favorite") {
      showStatus(payload.favorite ? "Added to favorites." : "Removed from favorites.", false)
      refresh()
    } else if (actionKind === "core") {
      showStatus(payload.automatic ? "Using the playlist core automatically." : "Core choice saved for this game.", false)
    } else if (actionKind === "open" || actionKind === "folder" || actionKind === "organize") {
      root.close()
    }
  }

  Process {
    id: listProc
    command: [root.helperPath, "list"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.listOutput = text }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) { root.parseList(exitCode) }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.actionOutput = text }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) { root.finishAction(exitCode) }
  }

  Timer {
    id: statusTimer
    interval: 4500
    repeat: false
    onTriggered: root.statusText = ""
  }

  KeyboardPanel {
    id: libraryPanel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: libraryPanel.fittedContentWidth(root.desiredWidth)
    contentHeight: libraryPanel.fittedContentHeight(contentColumn.implicitHeight, root.maximumHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus || corePicker.popupOpen
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) { root.moveKeyboardSelection(dx, dy) }
      onActivateRequested: root.activateKeyboardSelection()
      onTextKey: function(text) {
        var key = String(text || "").toLowerCase()
        if (key === "/") searchField.forceActiveFocus()
        else if (key === "f") root.toggleFavorite()
        else if (key === "r") root.refresh()
      }

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.space(12)

        Row {
          width: parent.width
          height: Style.space(50)
          spacing: Style.space(12)

          BorderSurface {
            width: Style.space(46)
            height: width
            anchors.verticalCenter: parent.verticalCenter
            radius: Style.cornerRadius
            color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.15)
            borderSpec: Border.flat(Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.42), 1)

            Text {
              anchors.centerIn: parent
              text: "󰊖"
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
            }
          }

          Column {
            width: parent.width - Style.space(46) - headerActions.width - parent.spacing * 2
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "Retro Library"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              width: parent.width
              text: root.loading ? "READING RETROARCH PLAYLISTS…"
                : String(root.library.source_kind || "RETROARCH").toUpperCase() + " · "
                  + root.totalGames + " GAMES · " + root.systems.length + " SYSTEMS · "
                  + Number(root.library.playable_games || 0) + " READY"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 0.9
            }
          }

          Row {
            id: headerActions
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Button {
              text: "Refresh"
              iconText: "󰑓"
              foreground: root.foreground
              accent: root.accent
              bordered: true
              focusable: true
              enabled: !root.loading
              onClicked: root.refresh()
            }

            Button {
              text: "RetroArch"
              iconText: "󰐊"
              foreground: root.foreground
              accent: root.accent
              bordered: true
              focusable: true
              enabled: !root.actionBusy
              onClicked: root.runAction("open", ["open"])
            }
          }
        }

        Rectangle { width: parent.width; height: 1; color: root.faint }

        Row {
          width: parent.width
          height: Style.space(38)
          spacing: Style.space(10)

          TextField {
            id: searchField
            width: parent.width - resultCount.width - parent.spacing
            height: parent.height
            placeholderText: "Search titles, consoles, or cores…"
            foreground: root.foreground
            accent: root.accent
            onTextChanged: root.rebuildGames()
            Keys.onEscapePressed: function(event) {
              if (text !== "") { clear(); event.accepted = true }
              else root.close()
            }
          }

          Text {
            id: resultCount
            anchors.verticalCenter: parent.verticalCenter
            text: root.filteredGames.length + (root.filteredGames.length === 1 ? " title" : " titles")
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        Row {
          width: parent.width
          height: Style.space(560)
          spacing: Style.space(10)

          BorderSurface {
            width: Style.space(224)
            height: parent.height
            radius: Style.cornerRadius
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.025)
            borderSpec: root.keyboardSection === "systems" && !searchField.activeFocus
              ? Border.flat(Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.62), 2)
              : Border.flat(root.faint, 1)
            clip: true

            ListView {
              id: systemList
              anchors.fill: parent
              anchors.margins: Style.space(5)
              model: root.systemOptions()
              clip: true
              spacing: Style.space(2)
              boundsBehavior: Flickable.StopAtBounds
              QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

              delegate: BorderSurface {
                id: systemRow
                required property int index
                required property var modelData
                width: systemList.width
                height: Style.space(48)
                radius: Style.cornerRadius
                color: root.selectedSystem === String(modelData.id)
                  ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12)
                  : systemHover.hovered ? root.faint : "transparent"
                borderSpec: root.selectedSystem === String(modelData.id)
                  ? Border.flat(Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.34), 1)
                  : Border.none()

                Item {
                  id: consoleIcon
                  width: Style.space(30)
                  height: width
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(9)
                  anchors.verticalCenter: parent.verticalCenter

                  Image {
                    id: systemImage
                    anchors.fill: parent
                    anchors.margins: Style.space(3)
                    visible: String(systemRow.modelData.icon || "") !== ""
                    source: visible ? "file://" + String(systemRow.modelData.icon) : ""
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    layer.enabled: visible
                    layer.effect: MultiEffect {
                      colorization: 1.0
                      colorizationColor: root.selectedSystem === String(systemRow.modelData.id) ? root.accent : root.foreground
                    }
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: !systemImage.visible
                    text: String(systemRow.modelData.glyph || "󰊖")
                    color: root.selectedSystem === String(systemRow.modelData.id) ? root.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.icon
                  }
                }

                Column {
                  anchors.left: consoleIcon.right
                  anchors.right: systemCount.left
                  anchors.leftMargin: Style.space(9)
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)

                  Text {
                    width: parent.width
                    text: String(systemRow.modelData.short_name || "")
                    color: root.selectedSystem === String(systemRow.modelData.id) ? root.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: root.selectedSystem === String(systemRow.modelData.id)
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: String(systemRow.modelData.manufacturer || "").toUpperCase()
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 0.7
                    elide: Text.ElideRight
                  }
                }

                Text {
                  id: systemCount
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: String(systemRow.modelData.count || 0)
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                HoverHandler { id: systemHover }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.keyboardSection = "systems"
                    root.selectSystem(systemRow.index)
                    root.setKeyboardSection("systems")
                  }
                }
              }
            }
          }

          BorderSurface {
            width: Style.space(398)
            height: parent.height
            radius: Style.cornerRadius
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.025)
            borderSpec: root.keyboardSection === "games" && !searchField.activeFocus
              ? Border.flat(Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.62), 2)
              : Border.flat(root.faint, 1)
            clip: true

            ListView {
              id: gameList
              anchors.fill: parent
              anchors.margins: Style.space(5)
              model: root.filteredGames
              clip: true
              spacing: Style.space(2)
              boundsBehavior: Flickable.StopAtBounds
              currentIndex: root.selectedIndex
              QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

              delegate: BorderSurface {
                id: gameRow
                required property int index
                required property var modelData
                width: gameList.width
                height: Style.space(52)
                radius: Style.cornerRadius
                color: root.selectedIndex === index
                  ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.11)
                  : gameHover.hovered ? root.faint : "transparent"
                borderSpec: root.selectedIndex === index
                  ? Border.flat(Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.32), 1)
                  : Border.none()

                Text {
                  id: favoriteStar
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: gameRow.modelData.favorite ? "󰓎" : "󰋕"
                  color: gameRow.modelData.favorite ? root.accent : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Column {
                  anchors.left: favoriteStar.right
                  anchors.right: readyIcon.left
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: String(gameRow.modelData.label || "")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: root.selectedIndex === gameRow.index
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: String(gameRow.modelData.system_short_name || "")
                      + (String(gameRow.modelData.last_played || "") !== "" ? " · PLAYED " + Number(gameRow.modelData.play_count || 1) + "×" : "")
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    elide: Text.ElideRight
                  }
                }

                Text {
                  id: readyIcon
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(11)
                  anchors.verticalCenter: parent.verticalCenter
                  text: gameRow.modelData.content_available && gameRow.modelData.core_available ? "󰄬" : "󰅚"
                  color: gameRow.modelData.content_available && gameRow.modelData.core_available ? root.muted : "#e06c75"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                HoverHandler { id: gameHover }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.selectGame(gameRow.index)
                    root.setKeyboardSection("games")
                  }
                  onDoubleClicked: {
                    root.selectGame(gameRow.index)
                    root.launchSelected()
                  }
                }
              }

              Text {
                anchors.centerIn: parent
                visible: !root.loading && root.filteredGames.length === 0
                text: searchField.text.trim() === "" ? "No games in this view" : "No matching titles"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          BorderSurface {
            width: parent.width - Style.space(224) - Style.space(398) - parent.spacing * 2
            height: parent.height
            radius: Style.cornerRadius
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.025)
            borderSpec: Border.flat(root.faint, 1)
            clip: true

            Column {
              visible: root.selectedGame !== null
              anchors.fill: parent
              anchors.margins: Style.space(16)
              spacing: Style.space(10)

              BorderSurface {
                width: parent.width
                height: Style.space(218)
                radius: Style.cornerRadius
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.045)
                borderSpec: Border.flat(root.faint, 1)
                clip: true

                Image {
                  id: artworkImage
                  anchors.fill: parent
                  anchors.margins: Style.space(10)
                  visible: root.selectedGame && String(root.selectedGame.thumbnail || "") !== ""
                  source: visible ? "file://" + String(root.selectedGame.thumbnail) : ""
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  smooth: true
                  cache: true
                }

                Item {
                  anchors.fill: parent
                  visible: !artworkImage.visible

                  Image {
                    anchors.centerIn: parent
                    width: Style.space(94)
                    height: width
                    source: root.selectedGame && String(root.selectedGame.system_icon || "") !== ""
                      ? "file://" + String(root.selectedGame.system_icon) : ""
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    opacity: 0.78
                    layer.enabled: true
                    layer.effect: MultiEffect { colorization: 1.0; colorizationColor: root.foreground }
                  }
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(3)

                Text {
                  width: parent.width
                  text: root.selectedGame ? String(root.selectedGame.label || "") : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  wrapMode: Text.Wrap
                  maximumLineCount: 2
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: root.selectedGame ? String(root.selectedGame.system_name || "").toUpperCase() : ""
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 0.8
                  elide: Text.ElideRight
                }
              }

              Dropdown {
                id: corePicker
                width: parent.width
                label: "EMULATOR CORE"
                value: root.selectedCorePath
                options: root.coreOptions()
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                enabled: !root.actionBusy
                onChanged: function(value) { root.setCore(value) }
              }

              Column {
                width: parent.width
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  text: root.selectedCorePath !== "auto" ? "PER-GAME OVERRIDE" : "PLAYLIST DEFAULT"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 0.7
                }

                Text {
                  width: parent.width
                  text: root.selectedGame ? root.contentName(root.selectedGame.path) : ""
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.46)
                  font.family: "monospace"
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle
                }
              }

              Item { width: 1; height: Style.space(2) }

              Button {
                width: parent.width
                text: root.actionBusy && root.actionKind === "launch" ? "Launching…" : "Play"
                iconText: "󰐊"
                foreground: root.foreground
                accent: root.accent
                selected: true
                bordered: true
                focusable: true
                enabled: !root.actionBusy && root.selectedGame
                  && root.selectedGame.content_available && root.selectedGame.core_available
                onClicked: root.launchSelected()
              }

              Button {
                width: parent.width
                text: root.selectedGame && root.selectedGame.favorite ? "Remove favorite" : "Add favorite"
                iconText: root.selectedGame && root.selectedGame.favorite ? "󰓎" : "󰋕"
                foreground: root.foreground
                accent: root.accent
                bordered: true
                focusable: true
                enabled: !root.actionBusy
                onClicked: root.toggleFavorite()
              }

              Row {
                width: parent.width
                spacing: Style.space(6)

                Button {
                  width: (parent.width - parent.spacing * 2) / 3
                  text: "Game"
                  iconText: "󰉋"
                  foreground: root.foreground
                  accent: root.accent
                  bordered: true
                  focusable: true
                  enabled: !root.actionBusy
                  onClicked: root.runAction("folder", ["open-folder", "--kind", "roms", "--path", String(root.selectedGame.path)])
                }

                Button {
                  width: (parent.width - parent.spacing * 2) / 3
                  text: "Saves"
                  iconText: "󰆓"
                  foreground: root.foreground
                  accent: root.accent
                  bordered: true
                  focusable: true
                  enabled: !root.actionBusy
                  onClicked: root.runAction("folder", ["open-folder", "--kind", "saves"])
                }

                Button {
                  width: (parent.width - parent.spacing * 2) / 3
                  text: "States"
                  iconText: "󰁯"
                  foreground: root.foreground
                  accent: root.accent
                  bordered: true
                  focusable: true
                  enabled: !root.actionBusy
                  onClicked: root.runAction("folder", ["open-folder", "--kind", "states"])
                }
              }

              Button {
                width: parent.width
                visible: Boolean(root.library.organizer_available)
                height: visible ? implicitHeight : 0
                text: "Organize ROM library"
                iconText: "󰒓"
                foreground: root.foreground
                accent: root.accent
                bordered: true
                focusable: true
                enabled: !root.actionBusy
                onClicked: root.runAction("organize", ["organize"])
              }
            }

            Text {
              anchors.centerIn: parent
              visible: root.selectedGame === null
              text: root.loading ? "Loading your library…" : "Select a game"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }
        }

        Text {
          width: parent.width
          height: Style.space(18)
          text: root.statusText !== "" ? root.statusText : "↑/↓ browse · Enter play · F favorite · / search · R refresh"
          color: root.statusText !== "" ? (root.statusError ? "#e06c75" : root.accent) : root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }
      }
    }
  }
}
