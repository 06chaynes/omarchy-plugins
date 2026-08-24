import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.06chaynes.rust-workspaces"

  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("bin/rustctl").toString().replace(/^file:\/\//, ""))
  readonly property string barMode: String(setting("barMode", "Size"))
  property string totalReclaimable: "0 B"
  property int projectCount: 0
  property int uncleanedCount: 0
  property bool isScanning: false
  property var workspaceList: []
  property var scanRoots: []

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("barWidget" in target) target.barWidget = root
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open();
  }
  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close();
  }
  function toggle() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle();
  }
  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch) panelLoader.item.closeForPopoutSwitch();
  }

  function cycleBarMode() {
    var modes = ["Size", "Count", "Detailed", "Status", "IconOnly"];
    var index = modes.indexOf(root.barMode);
    var next = modes[(index + 1) % modes.length];
    var newSettings = Object.assign({}, root.settings, { barMode: next });
    root.settings = newSettings;
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
      root.bar.shell.updateEntryInline(root.moduleName, newSettings);
    }
  }

  function pillText() {
    if (root.barMode === "Size") return root.totalReclaimable !== "0 B" ? root.totalReclaimable : "";
    if (root.barMode === "Count") return String(root.projectCount);
    if (root.barMode === "Detailed") return root.projectCount + " • " + root.totalReclaimable;
    if (root.barMode === "Status") return root.uncleanedCount + " uncleaned";
    if (root.barMode === "IconOnly") return "";
    return root.totalReclaimable !== "0 B" ? root.totalReclaimable : "";
  }

  function rescan() {
    if (root.isScanning) return;
    root.isScanning = true;
    scanProc.running = true;
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Process {
    id: scanProc
    command: [root.helperPath, "scan"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.isScanning = false;
        var raw = String(text || "").trim();
        if (!raw) return;
        try {
          var data = JSON.parse(raw);
          root.totalReclaimable = data.totalReclaimableDisplay || "0 B";
          root.projectCount = data.count || 0;
          root.workspaceList = data.workspaces || [];
          root.scanRoots = data.scanRoots || [];
          
          var uncleaned = 0;
          for (var i = 0; i < root.workspaceList.length; i++) {
            if (root.workspaceList[i].hasTarget) uncleaned++;
          }
          root.uncleanedCount = uncleaned;

          if (panelLoader.item && panelLoader.item.updateData) {
            panelLoader.item.updateData(data);
          }
        } catch(e) {
          console.warn("rust-workspaces scan parse error:", e);
        }
      }
    }
    onExited: {
      root.isScanning = false;
    }
  }

  Timer {
    interval: 300000 // 5 minutes
    running: true
    repeat: true
    onTriggered: root.rescan()
  }

  Component.onCompleted: {
    root.rescan();
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel();
      Qt.callLater(root.injectPanel);
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.opened
    labelVisible: false
    hasVisualContent: true
    implicitWidth: pillContent.implicitWidth + Style.space(16)
    tooltipText: "Rust Workspaces: " + root.projectCount + " found (" + root.totalReclaimable + " reclaimable)\nDisplay: " + root.barMode + " (Right-click to cycle)\nClick to inspect & clean\nMiddle-click to rescan"

    onPressed: function(b) {
      if (b === Qt.RightButton) {
        root.cycleBarMode();
      } else if (b === Qt.MiddleButton) {
        root.rescan();
      } else if (b === Qt.LeftButton) {
        root.toggle();
      }
    }

    Row {
      id: pillContent
      anchors.centerIn: parent
      spacing: Style.space(6)

      Text {
        text: "\uE7A8" // Official Rust Logo
        font.family: "Symbols Nerd Font Mono"
        font.pixelSize: Style.space(22)
        color: root.isScanning ? (Color.accent || "#ff79c6") : button.foreground
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: root.pillText()
        font.family: button.fontFamily
        font.pixelSize: Style.font.body
        font.weight: Font.Medium
        color: button.foreground
        anchors.verticalCenter: parent.verticalCenter
        visible: root.pillText() !== ""
      }
    }
  }
}
