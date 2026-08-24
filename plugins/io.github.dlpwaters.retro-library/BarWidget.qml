import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.dlpwaters.retro-library"

  readonly property int gameCount: panelLoader.item ? panelLoader.item.totalGames : 0

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.settings = root.settings
    target.anchorItem = button
    target.hostWidget = root
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function refresh() { if (panelLoader.item) panelLoader.item.refresh() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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
    target: "io.github.dlpwaters.retro-library"
    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function refresh() { root.refresh() }
    function state(): string {
      var panel = panelLoader.item
      return JSON.stringify({
        loaded: panel !== null,
        opened: panel ? panel.opened : false,
        loading: panel ? panel.loading : false,
        games: panel ? panel.totalGames : 0,
        visibleGames: panel ? panel.filteredGames.length : 0,
        system: panel ? panel.selectedSystem : "",
        keyboardSection: panel ? panel.keyboardSection : "",
        selectedIndex: panel ? panel.selectedIndex : -1
      })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰊖"
    tooltipText: root.gameCount > 0 ? "Retro Library · " + root.gameCount + " games" : "Retro Library"
    onPressed: function(mouseButton) {
      if (mouseButton !== Qt.RightButton) root.toggle()
    }
  }
}
