import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.06chaynes.rust-workspaces"
  ipcTarget: "io.github.06chaynes.rust-workspaces"
  manageIpc: false

  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("bin/rustctl").toString().replace(/^file:\/\//, ""))
  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property var rawData: ({})
  property var workspaces: []
  property var scanRoots: []
  property string totalReclaimable: "0 B"
  property string totalSource: "0 B"
  property int count: 0
  property string searchQuery: ""
  property string sortMode: "size" // "size", "age", "name"
  property var selectedPaths: ({})
  property bool showSettings: false
  property string newRootInput: ""
  property bool isBusy: false
  property string statusMessage: ""

  function open() {
    root.controller.show();
    root.rescan();
  }

  function openFromHotkey() {
    root.open();
  }

  function close() {
    root.controller.hide();
  }

  function toggle() {
    if (root.opened) root.close();
    else root.open();
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction);
    return false;
  }

  function updateData(data) {
    if (!data) return;
    root.rawData = data;
    root.totalReclaimable = data.totalReclaimableDisplay || "0 B";
    root.totalSource = data.totalSourceDisplay || "0 B";
    root.count = data.count || 0;
    root.scanRoots = data.scanRoots || [];
    filterAndSort();
  }

  function filterAndSort() {
    var list = (root.rawData.workspaces || []).slice();
    var q = root.searchQuery.trim().toLowerCase();
    
    if (q !== "") {
      list = list.filter(function(item) {
        return (item.name && item.name.toLowerCase().indexOf(q) !== -1) ||
               (item.path && item.path.toLowerCase().indexOf(q) !== -1) ||
               (item.displayPath && item.displayPath.toLowerCase().indexOf(q) !== -1);
      });
    }

    if (root.sortMode === "size") {
      list.sort(function(a, b) { return b.targetBytes - a.targetBytes; });
    } else if (root.sortMode === "age") {
      list.sort(function(a, b) { return b.daysSinceBuild - a.daysSinceBuild; });
    } else if (root.sortMode === "name") {
      list.sort(function(a, b) { return a.name.localeCompare(b.name); });
    }

    root.workspaces = list;
  }

  function rescan() {
    if (root.hostWidget && root.hostWidget.rescan) root.hostWidget.rescan();
  }

  function cleanSingle(path) {
    root.isBusy = true;
    root.statusMessage = "Cleaning " + path + "...";
    cleanProc.running = false;
    cleanProc.command = [root.helperPath, "clean", path];
    cleanProc.running = true;
  }

  function cleanSelected() {
    var paths = Object.keys(root.selectedPaths).filter(function(k) { return root.selectedPaths[k] === true; });
    if (paths.length === 0) return;
    root.isBusy = true;
    root.statusMessage = "Cleaning " + paths.length + " workspaces...";
    var args = [root.helperPath, "clean-batch"];
    for (var i = 0; i < paths.length; i++) {
      args.push(paths[i]);
    }
    cleanProc.running = false;
    cleanProc.command = args;
    cleanProc.running = true;
  }

  function cleanStale() {
    root.isBusy = true;
    root.statusMessage = "Cleaning stale targets (>14 days)...";
    cleanProc.running = false;
    cleanProc.command = [root.helperPath, "clean-stale", "14"];
    cleanProc.running = true;
  }

  function toggleSelect(path) {
    var sel = Object.assign({}, root.selectedPaths);
    sel[path] = !sel[path];
    root.selectedPaths = sel;
  }

  function selectAll() {
    var sel = {};
    for (var i = 0; i < root.workspaces.length; i++) {
      if (root.workspaces[i].hasTarget) {
        sel[root.workspaces[i].path] = true;
      }
    }
    root.selectedPaths = sel;
  }

  function deselectAll() {
    root.selectedPaths = ({});
  }

  function selectedCount() {
    return Object.keys(root.selectedPaths).filter(function(k) { return root.selectedPaths[k] === true; }).length;
  }

  function openTerm(path) {
    if (root.bar && typeof root.bar.run === "function") {
      root.bar.run("uwsm-app -- xdg-terminal-exec --dir=" + path);
    } else {
      actionProc.running = false;
      actionProc.command = [root.helperPath, "open-term", path];
      actionProc.running = true;
    }
  }

  function openEditor(path) {
    if (root.bar && typeof root.bar.run === "function") {
      root.bar.run("omarchy-launch-editor " + path);
    } else {
      actionProc.running = false;
      actionProc.command = [root.helperPath, "open-editor", path];
      actionProc.running = true;
    }
  }

  function openFiles(path) {
    if (root.bar && typeof root.bar.run === "function") {
      root.bar.run("xdg-open " + path);
    } else {
      actionProc.running = false;
      actionProc.command = [root.helperPath, "open-files", path];
      actionProc.running = true;
    }
  }

  function addRoot(path) {
    if (!path || path.trim() === "") return;
    root.isBusy = true;
    rootsProc.command = [root.helperPath, "roots-add", path.trim()];
    rootsProc.running = true;
    root.newRootInput = "";
  }

  function removeRoot(path) {
    root.isBusy = true;
    rootsProc.command = [root.helperPath, "roots-remove", path];
    rootsProc.running = true;
  }

  Process {
    id: cleanProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.isBusy = false;
        root.statusMessage = "";
        root.selectedPaths = ({});
        root.rescan();
      }
    }
    onExited: {
      root.isBusy = false;
      root.statusMessage = "";
      root.rescan();
    }
  }

  Process {
    id: rootsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.isBusy = false;
        var raw = String(text || "").trim();
        if (raw) {
          try {
            var data = JSON.parse(raw);
            root.updateData(data);
          } catch(e) {}
        }
      }
    }
  }

  Process {
    id: actionProc
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(Style.space(580))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchInput.activeFocus || addRootInput.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(12)
        spacing: Style.space(10)

        // Header
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)

          Text {
            text: "\uE7A8"
            font.family: "Symbols Nerd Font Mono"
            font.pixelSize: Style.space(24)
            color: Color.accent || "#ff79c6"
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Text {
              text: "Rust Workspaces"
              font.pixelSize: Style.space(15)
              font.weight: Font.Bold
              color: Color.foreground || "#f8f8f2"
            }

            Text {
              text: root.count + " workspaces • " + root.totalReclaimable + " reclaimable"
              font.pixelSize: Style.space(11)
              color: Color.muted || "#6272a4"
            }
          }

          // Rescan button
          Rectangle {
            width: Style.space(30)
            height: Style.space(30)
            radius: 4
            color: rescanMa.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : Qt.rgba(1, 1, 1, 0.08)
            border.color: Qt.rgba(1, 1, 1, 0.2)
            border.width: 1

            Text {
              anchors.centerIn: parent
              text: "\uF01E"
              font.family: "Symbols Nerd Font Mono"
              font.pixelSize: Style.space(13)
              color: Color.foreground || "#f8f8f2"
            }

            MouseArea {
              id: rescanMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.rescan()
            }

            PanelToolTip {
              visible: rescanMa.containsMouse
              text: "Rescan all Rust workspaces"
            }
          }

          // Settings toggle button
          Rectangle {
            width: Style.space(30)
            height: Style.space(30)
            radius: 4
            color: root.showSettings ? (Color.accent || "#ff79c6") : (settingsMa.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : Qt.rgba(1, 1, 1, 0.08))
            border.color: Qt.rgba(1, 1, 1, 0.2)
            border.width: 1

            Text {
              anchors.centerIn: parent
              text: "\uF013"
              font.family: "Symbols Nerd Font Mono"
              font.pixelSize: Style.space(13)
              color: root.showSettings ? "#000000" : (Color.foreground || "#f8f8f2")
            }

            MouseArea {
              id: settingsMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.showSettings = !root.showSettings
            }

            PanelToolTip {
              visible: settingsMa.containsMouse
              text: root.showSettings ? "Back to workspaces list" : "Configure scan root directories"
            }
          }
        }

        // Search & Sort Bar
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          visible: !root.showSettings

          Rectangle {
            Layout.fillWidth: true
            height: Style.space(30)
            radius: 4
            color: Qt.rgba(1, 1, 1, 0.06)
            border.color: searchInput.activeFocus ? (Color.accent || "#ff79c6") : Qt.rgba(1, 1, 1, 0.15)
            border.width: 1

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(6)

              Text {
                text: "\uF002"
                font.family: "Symbols Nerd Font Mono"
                font.pixelSize: Style.space(12)
                color: Color.muted || "#6272a4"
              }

              TextInput {
                id: searchInput
                Layout.fillWidth: true
                font.pixelSize: Style.space(12)
                color: Color.foreground || "#f8f8f2"
                clip: true
                onTextChanged: {
                  root.searchQuery = text;
                  root.filterAndSort();
                }

                Text {
                  anchors.fill: parent
                  text: "Filter workspaces or paths..."
                  font.pixelSize: Style.space(12)
                  color: Color.muted || "#6272a4"
                  visible: !searchInput.text && !searchInput.activeFocus
                }
              }
            }
          }

          // Sort Size
          Rectangle {
            width: Style.space(48)
            height: Style.space(30)
            radius: 4
            color: root.sortMode === "size" ? Qt.rgba(1, 1, 1, 0.2) : (sortSizeMa.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : "transparent")
            border.color: Qt.rgba(1, 1, 1, 0.15)
            border.width: 1

            Text {
              anchors.centerIn: parent
              text: "Size"
              font.pixelSize: Style.space(11)
              font.weight: root.sortMode === "size" ? Font.Bold : Font.Normal
              color: root.sortMode === "size" ? (Color.accent || "#ff79c6") : (Color.foreground || "#f8f8f2")
            }

            MouseArea {
              id: sortSizeMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { root.sortMode = "size"; root.filterAndSort(); }
            }

            PanelToolTip {
              visible: sortSizeMa.containsMouse
              text: "Sort by largest reclaimable target size"
            }
          }

          // Sort Age
          Rectangle {
            width: Style.space(44)
            height: Style.space(30)
            radius: 4
            color: root.sortMode === "age" ? Qt.rgba(1, 1, 1, 0.2) : (sortAgeMa.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : "transparent")
            border.color: Qt.rgba(1, 1, 1, 0.15)
            border.width: 1

            Text {
              anchors.centerIn: parent
              text: "Age"
              font.pixelSize: Style.space(11)
              font.weight: root.sortMode === "age" ? Font.Bold : Font.Normal
              color: root.sortMode === "age" ? (Color.accent || "#ff79c6") : (Color.foreground || "#f8f8f2")
            }

            MouseArea {
              id: sortAgeMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { root.sortMode = "age"; root.filterAndSort(); }
            }

            PanelToolTip {
              visible: sortAgeMa.containsMouse
              text: "Sort by days since last build (oldest first)"
            }
          }

          // Sort Name
          Rectangle {
            width: Style.space(50)
            height: Style.space(30)
            radius: 4
            color: root.sortMode === "name" ? Qt.rgba(1, 1, 1, 0.2) : (sortNameMa.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : "transparent")
            border.color: Qt.rgba(1, 1, 1, 0.15)
            border.width: 1

            Text {
              anchors.centerIn: parent
              text: "Name"
              font.pixelSize: Style.space(11)
              font.weight: root.sortMode === "name" ? Font.Bold : Font.Normal
              color: root.sortMode === "name" ? (Color.accent || "#ff79c6") : (Color.foreground || "#f8f8f2")
            }

            MouseArea {
              id: sortNameMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { root.sortMode = "name"; root.filterAndSort(); }
            }

            PanelToolTip {
              visible: sortNameMa.containsMouse
              text: "Sort alphabetically by workspace name"
            }
          }
        }

        // Global Batch Actions Bar
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          visible: !root.showSettings

          Rectangle {
            width: Style.space(86)
            height: Style.space(26)
            radius: 4
            color: selectAllMa.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : Qt.rgba(1, 1, 1, 0.08)
            border.color: Qt.rgba(1, 1, 1, 0.15)
            border.width: 1

            Text {
              anchors.centerIn: parent
              text: "\uF00C Select All"
              font.family: "Symbols Nerd Font Mono"
              font.pixelSize: Style.space(11)
              color: Color.foreground || "#f8f8f2"
            }

            MouseArea {
              id: selectAllMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.selectAll()
            }

            PanelToolTip {
              visible: selectAllMa.containsMouse
              text: "Select all workspaces with uncleaned target builds"
            }
          }

          Rectangle {
            width: Style.space(56)
            height: Style.space(26)
            radius: 4
            visible: root.selectedCount() > 0
            color: clearSelMa.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : Qt.rgba(1, 1, 1, 0.08)
            border.color: Qt.rgba(1, 1, 1, 0.15)
            border.width: 1

            Text {
              anchors.centerIn: parent
              text: "Clear"
              font.pixelSize: Style.space(11)
              color: Color.muted || "#6272a4"
            }

            MouseArea {
              id: clearSelMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.deselectAll()
            }

            PanelToolTip {
              visible: clearSelMa.containsMouse
              text: "Clear all selected checkboxes"
            }
          }

          Rectangle {
            Layout.fillWidth: true
            height: Style.space(26)
            radius: 4
            visible: root.selectedCount() > 0
            color: cleanSelMa.containsMouse ? (Color.accent || "#ff79c6") : Qt.rgba(Color.accent.r || 1, Color.accent.g || 0.4, Color.accent.b || 0.7, 0.8)

            Text {
              anchors.centerIn: parent
              text: "\uF0E2 Clean Selected (" + root.selectedCount() + ")"
              font.family: "Symbols Nerd Font Mono"
              font.pixelSize: Style.space(11)
              font.weight: Font.Bold
              color: "#000000"
            }

            MouseArea {
              id: cleanSelMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.cleanSelected()
            }

            PanelToolTip {
              visible: cleanSelMa.containsMouse
              text: "Run cargo clean on all " + root.selectedCount() + " selected workspaces"
            }
          }

          Rectangle {
            Layout.fillWidth: root.selectedCount() === 0
            height: Style.space(26)
            radius: 4
            color: cleanStaleMa.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : Qt.rgba(1, 1, 1, 0.08)
            border.color: Qt.rgba(1, 1, 1, 0.15)
            border.width: 1

            Text {
              anchors.centerIn: parent
              text: "\uF017 Clean Stale (>14d)"
              font.family: "Symbols Nerd Font Mono"
              font.pixelSize: Style.space(11)
              color: Color.foreground || "#f8f8f2"
            }

            MouseArea {
              id: cleanStaleMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.cleanStale()
            }

            PanelToolTip {
              visible: cleanStaleMa.containsMouse
              text: "Clean targets that have not been built in over 14 days"
            }
          }
        }

        // Settings Drawer View
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.space(8)
          visible: root.showSettings

          Text {
            text: "Scan Roots Configuration"
            font.pixelSize: Style.space(13)
            font.weight: Font.Bold
            color: Color.foreground || "#f8f8f2"
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            Rectangle {
              Layout.fillWidth: true
              height: Style.space(32)
              radius: 4
              color: Qt.rgba(1, 1, 1, 0.06)
              border.color: addRootInput.activeFocus ? (Color.accent || "#ff79c6") : Qt.rgba(1, 1, 1, 0.15)
              border.width: 1

              TextInput {
                id: addRootInput
                anchors.fill: parent
                anchors.margins: Style.space(6)
                font.pixelSize: Style.space(12)
                color: Color.foreground || "#f8f8f2"
                clip: true

                Text {
                  anchors.fill: parent
                  text: "~/Projects or /path/to/code"
                  font.pixelSize: Style.space(12)
                  color: Color.muted || "#6272a4"
                  visible: !addRootInput.text && !addRootInput.activeFocus
                }
              }
            }

            Rectangle {
              width: Style.space(90)
              height: Style.space(32)
              radius: 4
              color: addRootMa.containsMouse ? (Color.accent || "#ff79c6") : Qt.rgba(Color.accent.r || 1, Color.accent.g || 0.4, Color.accent.b || 0.7, 0.8)

              Text {
                anchors.centerIn: parent
                text: "+ Add Root"
                font.pixelSize: Style.space(11)
                font.weight: Font.Bold
                color: "#000000"
              }

              MouseArea {
                id: addRootMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.addRoot(addRootInput.text);
                  addRootInput.text = "";
                }
              }

              PanelToolTip {
                visible: addRootMa.containsMouse
                text: "Add directory to permanent scan roots"
              }
            }
          }

          ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Style.space(6)
            model: root.scanRoots
            delegate: Rectangle {
              width: ListView.view.width
              height: Style.space(36)
              color: Qt.rgba(1, 1, 1, 0.04)
              border.color: Qt.rgba(1, 1, 1, 0.1)
              border.width: 1
              radius: 4

              RowLayout {
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: Style.space(8)

                Text {
                  Layout.fillWidth: true
                  text: modelData
                  font.pixelSize: Style.space(12)
                  color: Color.foreground || "#f8f8f2"
                  elide: Text.ElideMiddle
                }

                Rectangle {
                  width: Style.space(24)
                  height: Style.space(24)
                  radius: 3
                  color: remRootMa.containsMouse ? Qt.rgba(1, 0, 0, 0.3) : "transparent"

                  Text {
                    anchors.centerIn: parent
                    text: "\uF00D"
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: Style.space(12)
                    color: Color.urgent || "#ff5555"
                  }

                  MouseArea {
                    id: remRootMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.removeRoot(modelData)
                  }

                  PanelToolTip {
                    visible: remRootMa.containsMouse
                    text: "Remove this directory from scan roots"
                  }
                }
              }
            }
          }
        }

        // Workspaces List View
        ListView {
          id: wsList
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          spacing: Style.space(8)
          visible: !root.showSettings
          model: root.workspaces

          delegate: Rectangle {
            id: card
            width: wsList.width
            height: Style.space(86)
            radius: 6
            color: Qt.rgba(1, 1, 1, 0.05)
            border.color: root.selectedPaths[modelData.path] ? (Color.accent || "#ff79c6") : Qt.rgba(1, 1, 1, 0.1)
            border.width: root.selectedPaths[modelData.path] ? 2 : 1

            ColumnLayout {
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(4)

              // Top row: Checkbox, Name, Badges, Reclaimable Size
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                // Custom Checkbox
                Rectangle {
                  width: Style.space(16)
                  height: Style.space(16)
                  radius: 3
                  color: root.selectedPaths[modelData.path] ? (Color.accent || "#ff79c6") : "transparent"
                  border.color: modelData.hasTarget ? (Color.accent || "#ff79c6") : Qt.rgba(1, 1, 1, 0.2)
                  border.width: 1
                  opacity: modelData.hasTarget ? 1.0 : 0.3

                  Text {
                    anchors.centerIn: parent
                    text: "\uF00C"
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: Style.space(10)
                    color: "#000000"
                    visible: root.selectedPaths[modelData.path] === true
                  }

                  MouseArea {
                    id: checkMa
                    anchors.fill: parent
                    enabled: modelData.hasTarget
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleSelect(modelData.path)
                  }

                  PanelToolTip {
                    visible: checkMa.containsMouse && modelData.hasTarget
                    text: root.selectedPaths[modelData.path] ? "Deselect workspace" : "Select workspace for batch clean"
                  }
                }

                Text {
                  text: modelData.name
                  font.pixelSize: Style.space(13)
                  font.weight: Font.Bold
                  color: Color.foreground || "#f8f8f2"
                  elide: Text.ElideRight
                }

                Text {
                  text: modelData.version ? "v" + modelData.version : ""
                  font.pixelSize: Style.space(11)
                  color: Color.muted || "#6272a4"
                  visible: modelData.version !== ""
                }

                Rectangle {
                  visible: modelData.isWorkspace === true
                  radius: 3
                  color: Qt.rgba(0.9, 0.4, 0.2, 0.2)
                  implicitWidth: wsBadgeText.implicitWidth + Style.space(8)
                  implicitHeight: wsBadgeText.implicitHeight + Style.space(4)
                  Text {
                    id: wsBadgeText
                    anchors.centerIn: parent
                    text: "workspace"
                    font.pixelSize: Style.space(10)
                    color: Color.accent || "#ff79c6"
                  }
                }

                Rectangle {
                  visible: modelData.gitBranch !== null && modelData.gitBranch !== ""
                  radius: 3
                  color: Qt.rgba(1, 1, 1, 0.1)
                  implicitWidth: gitBadgeText.implicitWidth + Style.space(8)
                  implicitHeight: gitBadgeText.implicitHeight + Style.space(4)
                  Text {
                    id: gitBadgeText
                    anchors.centerIn: parent
                    text: "\uF126 " + (modelData.gitBranch || "")
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: Style.space(10)
                    color: Color.foreground || "#f8f8f2"
                  }
                }

                Item { Layout.fillWidth: true }

                Text {
                  text: modelData.targetDisplay
                  font.pixelSize: Style.space(13)
                  font.weight: Font.Bold
                  color: modelData.hasTarget ? (Color.accent || "#ff79c6") : (Color.muted || "#6272a4")
                }
              }

              // Middle row: Path + Age
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                Text {
                  Layout.fillWidth: true
                  text: modelData.displayPath
                  font.pixelSize: Style.space(11)
                  color: Color.muted || "#6272a4"
                  elide: Text.ElideMiddle
                }

                Text {
                  text: modelData.daysSinceBuild >= 0 ? ("Built " + modelData.daysSinceBuild + "d ago") : "Clean"
                  font.pixelSize: Style.space(11)
                  color: modelData.daysSinceBuild > 14 ? (Color.urgent || "#ff5555") : (Color.muted || "#6272a4")
                }
              }

              // Bottom row: Action Buttons
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                Text {
                  text: "Source: " + modelData.sourceDisplay
                  font.pixelSize: Style.space(10)
                  color: Color.muted || "#6272a4"
                }

                Item { Layout.fillWidth: true }

                // Clean button
                Rectangle {
                  width: Style.space(62)
                  height: Style.space(22)
                  radius: 3
                  visible: modelData.hasTarget
                  color: singleCleanMa.containsMouse ? (Color.accent || "#ff79c6") : Qt.rgba(Color.accent.r || 1, Color.accent.g || 0.4, Color.accent.b || 0.7, 0.2)
                  border.color: Color.accent || "#ff79c6"
                  border.width: 1

                  Text {
                    anchors.centerIn: parent
                    text: "\uF0E2 Clean"
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: Style.space(10)
                    font.weight: Font.Bold
                    color: singleCleanMa.containsMouse ? "#000000" : (Color.accent || "#ff79c6")
                  }

                  MouseArea {
                    id: singleCleanMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.cleanSingle(modelData.path)
                  }

                  PanelToolTip {
                    visible: singleCleanMa.containsMouse
                    text: "Run cargo clean on " + modelData.name + " (" + modelData.targetDisplay + ")"
                  }
                }

                // Terminal
                Rectangle {
                  width: Style.space(26)
                  height: Style.space(22)
                  radius: 3
                  color: termMa.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : Qt.rgba(1, 1, 1, 0.06)

                  Text {
                    anchors.centerIn: parent
                    text: "\uEA85"
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: Style.space(12)
                    color: Color.foreground || "#f8f8f2"
                  }

                  MouseArea {
                    id: termMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openTerm(modelData.path)
                  }

                  PanelToolTip {
                    visible: termMa.containsMouse
                    text: "Open terminal in " + modelData.displayPath
                  }
                }

                // Editor
                Rectangle {
                  width: Style.space(26)
                  height: Style.space(22)
                  radius: 3
                  color: editMa.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : Qt.rgba(1, 1, 1, 0.06)

                  Text {
                    anchors.centerIn: parent
                    text: "\uF044"
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: Style.space(12)
                    color: Color.foreground || "#f8f8f2"
                  }

                  MouseArea {
                    id: editMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openEditor(modelData.path)
                  }

                  PanelToolTip {
                    visible: editMa.containsMouse
                    text: "Open project in default code editor"
                  }
                }

                // Files
                Rectangle {
                  width: Style.space(26)
                  height: Style.space(22)
                  radius: 3
                  color: filesMa.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : Qt.rgba(1, 1, 1, 0.06)

                  Text {
                    anchors.centerIn: parent
                    text: "\uF07B"
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: Style.space(12)
                    color: Color.foreground || "#f8f8f2"
                  }

                  MouseArea {
                    id: filesMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openFiles(modelData.path)
                  }

                  PanelToolTip {
                    visible: filesMa.containsMouse
                    text: "Reveal folder in file manager"
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
