import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.06chaynes.github-tracker"
  implicitWidth: button.implicitWidth
  implicitHeight: barSize

  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("bin/githubctl").toString().replace(/^file:\/\//, ""))
  readonly property string barMode: String(setting("barMode", "BadgeCounts"))
  readonly property int refreshIntervalSec: Math.max(60, parseInt(setting("refreshIntervalSec", 300), 10) || 300)

  property var cachedData: ({})
  property var stats: ({
    failingActionsCount: 0,
    reviewRequestsCount: 0,
    myPrsCount: 0,
    pinnedCount: 0
  })
  property bool isFetching: false
  property bool hasAlerts: stats.failingActionsCount > 0

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("barWidget" in target) target.barWidget = root
    if (typeof target.updateData === "function" && root.cachedData && root.cachedData.ok) {
      target.updateData(root.cachedData);
    }
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
    var modes = ["BadgeCounts", "AlertsOnly", "IconOnly"];
    var index = modes.indexOf(root.barMode);
    var next = modes[(index + 1) % modes.length];
    var newSettings = Object.assign({}, root.settings, { barMode: next });
    root.settings = newSettings;
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
      root.bar.shell.updateEntryInline(root.moduleName, newSettings);
    }
  }

  function refresh() {
    if (root.isFetching) return;
    root.isFetching = true;
    fetchProc.running = true;
  }

  Process {
    id: fetchProc
    command: [root.helperPath, "fetch"]
    stdout: StdioCollector {
      id: fetchOut
      waitForEnd: true
      onStreamFinished: {
        root.isFetching = false;
        try {
          var data = JSON.parse(fetchOut.text || fetchOut.value || "");
          if (data.ok) {
            root.cachedData = data;
            if (data.stats) root.stats = data.stats;
            if (panelLoader.item && typeof panelLoader.item.updateData === "function") {
              panelLoader.item.updateData(data);
            }
          }
        } catch (e) {}
      }
    }
    onExited: {
      root.isFetching = false;
    }
  }

  Timer {
    id: autoRefreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: {
    root.refresh();
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
    tooltipText: "GitHub Tracker: " + root.stats.failingActionsCount + " CI alerts, " + root.stats.reviewRequestsCount + " reviews, " + root.stats.myPrsCount + " open PRs\nDisplay: " + root.barMode + " (Right-click to cycle)\nClick to open dashboard\nMiddle-click to refresh"

    onPressed: function(b) {
      if (b === Qt.RightButton) {
        root.cycleBarMode();
      } else if (b === Qt.MiddleButton) {
        root.refresh();
      } else if (b === Qt.LeftButton) {
        root.toggle();
      }
    }

    Row {
      id: pillContent
      anchors.centerIn: parent
      spacing: Style.space(5)

      // Octocat Icon
      Text {
        text: "󰊤"
        font.family: "Symbols Nerd Font Mono"
        font.pixelSize: Style.space(22)
        color: root.hasAlerts ? (Color.urgent || "#ff5555") : (root.opened ? (Color.accent || "#bd93f9") : button.foreground)
        anchors.verticalCenter: parent.verticalCenter
      }

      // Badges when in BadgeCounts mode
      Row {
        spacing: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        visible: root.barMode === "BadgeCounts"

        // Failing Actions Badge
        Rectangle {
          height: Style.space(18)
          width: failText.implicitWidth + Style.space(8)
          radius: 4
          color: Qt.rgba(1, 0.2, 0.2, 0.2)
          border.color: Color.urgent || "#ff5555"
          border.width: 1
          visible: root.stats.failingActionsCount > 0
          anchors.verticalCenter: parent.verticalCenter

          Text {
            id: failText
            anchors.centerIn: parent
            text: "󰅚 " + root.stats.failingActionsCount
            font.family: "Symbols Nerd Font Mono"
            font.pixelSize: 10
            font.weight: Font.DemiBold
            color: Color.urgent || "#ff5555"
          }
        }

        // Review Requests Badge
        Rectangle {
          height: Style.space(18)
          width: reviewText.implicitWidth + Style.space(8)
          radius: 4
          color: Qt.rgba(1, 0.7, 0, 0.2)
          border.color: "#f1fa8c"
          border.width: 1
          visible: root.stats.reviewRequestsCount > 0
          anchors.verticalCenter: parent.verticalCenter

          Text {
            id: reviewText
            anchors.centerIn: parent
            text: " " + root.stats.reviewRequestsCount
            font.family: "Symbols Nerd Font Mono"
            font.pixelSize: 10
            font.weight: Font.DemiBold
            color: "#f1fa8c"
          }
        }

        // Open PRs Badge
        Rectangle {
          height: Style.space(18)
          width: prText.implicitWidth + Style.space(8)
          radius: 4
          color: Qt.rgba(1, 1, 1, 0.1)
          border.color: Qt.rgba(1, 1, 1, 0.2)
          border.width: 1
          visible: root.stats.myPrsCount > 0
          anchors.verticalCenter: parent.verticalCenter

          Text {
            id: prText
            anchors.centerIn: parent
            text: " " + root.stats.myPrsCount
            font.family: "Symbols Nerd Font Mono"
            font.pixelSize: 10
            font.weight: Font.DemiBold
            color: Color.accent || "#8be9fd"
          }
        }
      }

      // Badges when in AlertsOnly mode
      Rectangle {
        height: Style.space(18)
        width: alertOnlyText.implicitWidth + Style.space(8)
        radius: 4
        color: Qt.rgba(1, 0.2, 0.2, 0.2)
        border.color: Color.urgent || "#ff5555"
        border.width: 1
        visible: root.barMode === "AlertsOnly" && root.stats.failingActionsCount > 0
        anchors.verticalCenter: parent.verticalCenter

        Text {
          id: alertOnlyText
          anchors.centerIn: parent
          text: "󰅚 " + root.stats.failingActionsCount
          font.family: "Symbols Nerd Font Mono"
          font.pixelSize: 10
          font.weight: Font.DemiBold
          color: Color.urgent || "#ff5555"
        }
      }
    }
  }
}
