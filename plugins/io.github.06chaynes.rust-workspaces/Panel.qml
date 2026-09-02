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
  property int staleDays: 14
  property string totalReclaimable: "0 B"
  property string totalSource: "0 B"
  property int count: 0
  property string searchQuery: ""
  property string sortMode: "size" // "size", "age", "name"
  property var selectedPaths: ({})
  property bool showSettings: false
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
    if (data.staleDaysThreshold > 0) root.staleDays = data.staleDaysThreshold;
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
    root.statusMessage = "Cleaning stale targets (>" + root.staleDays + " days)...";
    cleanProc.running = false;
    cleanProc.command = [root.helperPath, "clean-stale", String(root.staleDays)];
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

  // Util.execArgv, not bar.run: the latter takes a shell string, and pasting a
  // path into one breaks on spaces and executes anything a directory name
  // happens to contain. execArgv passes argv through positional parameters,
  // which bash does not re-tokenize.
  function openTerm(path) {
    Util.execArgv(["uwsm-app", "--", "xdg-terminal-exec", "--dir=" + path]);
  }

  function openEditor(path) {
    Util.execArgv(["omarchy-launch-editor", path]);
  }

  function openFiles(path) {
    Util.execArgv(["xdg-open", path]);
  }

  function addRoot(path) {
    if (!path || path.trim() === "") return;
    root.isBusy = true;
    rootsProc.command = [root.helperPath, "roots-add", path.trim()];
    rootsProc.running = true;
  }

  function removeRoot(path) {
    root.isBusy = true;
    rootsProc.command = [root.helperPath, "roots-remove", path];
    rootsProc.running = true;
  }

  Timer {
    id: statusClear
    interval: 6000
    onTriggered: root.statusMessage = ""
  }

  Process {
    id: cleanProc
    // Read the result here but rescan only in onExited. Both handlers fire, so
    // rescanning in each one ran a full filesystem scan twice per clean.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.selectedPaths = ({});
        var raw = String(text || "").trim();
        if (!raw) return;
        try {
          var data = JSON.parse(raw);
          if (data.ok === false && data.error) {
            root.statusMessage = data.error;
          } else if (data.skipped && data.skipped.length > 0) {
            root.statusMessage = "Left alone, not a cargo target dir: " + data.skipped.join(", ");
          } else if (data.reclaimedDisplay) {
            root.statusMessage = "Reclaimed " + data.reclaimedDisplay;
          }
        } catch(e) {
          root.statusMessage = "Could not read the cleaner's response";
        }
      }
    }
    onExited: {
      root.isBusy = false;
      root.rescan();
      statusClear.restart();
    }
  }

  Process {
    id: rootsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim();
        if (!raw) return;
        try {
          root.updateData(JSON.parse(raw));
        } catch(e) {}
      }
    }
    // Without this the busy flag sticks whenever the helper fails to start or
    // exits without writing anything.
    onExited: root.isBusy = false
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
            color: Color.accent
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Text {
              text: "Rust Workspaces"
              font.pixelSize: Style.space(15)
              font.weight: Font.Bold
              color: Color.foreground
            }

            Text {
              text: root.count + " workspaces • " + root.totalReclaimable + " reclaimable"
              font.pixelSize: Style.space(11)
              color: Color.muted
            }
          }

          Button {
            iconText: "\uF01E"
            tooltipText: "Rescan all Rust workspaces"
            bordered: true
            onClicked: root.rescan()
          }

          Button {
            iconText: "\uF013"
            tooltipText: root.showSettings ? "Back to workspaces list" : "Configure scan root directories"
            bordered: true
            selected: root.showSettings
            onClicked: root.showSettings = !root.showSettings
          }
        }

        // isBusy and statusMessage were set by every action but rendered
        // nowhere, so cleaning a large target looked like nothing happened.
        Rectangle {
          Layout.fillWidth: true
          visible: root.statusMessage !== ""
          radius: 4
          color: Util.alpha(Color.foreground, 0.06)
          implicitHeight: statusText.implicitHeight + Style.space(10)

          Text {
            id: statusText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            text: root.statusMessage
            font.pixelSize: Style.space(11)
            color: root.isBusy ? Color.muted : Color.foreground
            wrapMode: Text.WordWrap
          }
        }

        // Search & Sort Bar
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          visible: !root.showSettings

          // The kit's field carries the theme's focus border and selection
          // tint; the Rectangle + TextInput it replaces carried neither.
          TextField {
            id: searchInput
            Layout.fillWidth: true
            placeholderText: "Filter workspaces or paths…"
            verticalPadding: Style.space(4)
            onTextChanged: {
              root.searchQuery = text;
              root.filterAndSort();
            }
          }

          // Sort modes. Ui/Button carries the theme's [controls] fills,
          // borders and selected state; the hand-rolled rectangles this
          // replaces ignored all of it.
          Repeater {
            model: [
              { mode: "size", label: "Size", tip: "Sort by largest reclaimable target size" },
              { mode: "age",  label: "Age",  tip: "Sort by days since last build (oldest first)" },
              { mode: "name", label: "Name", tip: "Sort alphabetically by workspace name" }
            ]

            delegate: Button {
              required property var modelData
              text: modelData.label
              tooltipText: modelData.tip
              bordered: true
              selected: root.sortMode === modelData.mode
              onClicked: { root.sortMode = modelData.mode; root.filterAndSort(); }
            }
          }
        }

        // Global Batch Actions Bar
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          visible: !root.showSettings

          Button {
            text: "\uF00C Select All"
            tooltipText: "Select all workspaces with uncleaned target builds"
            bordered: true
            onClicked: root.selectAll()
          }

          Button {
            visible: root.selectedCount() > 0
            text: "Clear"
            tooltipText: "Clear all selected checkboxes"
            bordered: true
            onClicked: root.deselectAll()
          }

          Button {
            Layout.fillWidth: true
            visible: root.selectedCount() > 0
            text: "\uF0E2 Clean Selected (" + root.selectedCount() + ")"
            tooltipText: "Run cargo clean on all " + root.selectedCount() + " selected workspaces"
            active: true
            onClicked: root.cleanSelected()
          }

          Button {
            Layout.fillWidth: root.selectedCount() === 0
            text: "\uF017 Clean Stale (>" + root.staleDays + "d)"
            tooltipText: "Clean workspaces not built in over " + root.staleDays + " days"
            bordered: true
            onClicked: root.cleanStale()
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
            color: Color.foreground
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            Rectangle {
              Layout.fillWidth: true
              height: Style.space(32)
              radius: 4
              color: Util.alpha(Color.foreground, 0.06)
              border.color: addRootInput.activeFocus ? Color.accent : Util.alpha(Color.foreground, 0.15)
              border.width: 1

              TextInput {
                id: addRootInput
                anchors.fill: parent
                anchors.margins: Style.space(6)
                font.pixelSize: Style.space(12)
                color: Color.foreground
                clip: true

                Text {
                  anchors.fill: parent
                  text: "~/Projects or /path/to/code"
                  font.pixelSize: Style.space(12)
                  color: Color.muted
                  visible: !addRootInput.text && !addRootInput.activeFocus
                }
              }
            }

            Button {
              text: "+ Add Root"
              tooltipText: "Add directory to permanent scan roots"
              active: true
              onClicked: {
                root.addRoot(addRootInput.text);
                addRootInput.text = "";
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
              color: Util.alpha(Color.foreground, 0.04)
              border.color: Util.alpha(Color.foreground, 0.1)
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
                  color: Color.foreground
                  elide: Text.ElideMiddle
                }

                Button {
                  iconText: "\uF00D"
                  tooltipText: "Remove this scan root"
                  foreground: Color.urgent
                  verticalPadding: Style.space(2)
                  horizontalPadding: Style.space(6)
                  onClicked: root.removeRoot(modelData)
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
            color: Util.alpha(Color.foreground, 0.05)
            border.color: root.selectedPaths[modelData.path] ? Color.accent : Util.alpha(Color.foreground, 0.1)
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
                  color: root.selectedPaths[modelData.path] ? Color.accent : "transparent"
                  border.color: modelData.hasTarget ? Color.accent : Util.alpha(Color.foreground, 0.2)
                  border.width: 1
                  opacity: modelData.hasTarget ? 1.0 : 0.3

                  Text {
                    anchors.centerIn: parent
                    text: "\uF00C"
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: Style.space(10)
                    color: Color.background
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
                  color: Color.foreground
                  elide: Text.ElideRight
                }

                Text {
                  text: modelData.version ? "v" + modelData.version : ""
                  font.pixelSize: Style.space(11)
                  color: Color.muted
                  visible: modelData.version !== ""
                }

                Rectangle {
                  visible: modelData.isWorkspace === true
                  radius: 3
                  color: Util.alpha(Color.urgent, 0.2)
                  implicitWidth: wsBadgeText.implicitWidth + Style.space(8)
                  implicitHeight: wsBadgeText.implicitHeight + Style.space(4)
                  Text {
                    id: wsBadgeText
                    anchors.centerIn: parent
                    text: "workspace"
                    font.pixelSize: Style.space(10)
                    color: Color.accent
                  }
                }

                Rectangle {
                  visible: modelData.gitBranch !== null && modelData.gitBranch !== ""
                  radius: 3
                  color: Util.alpha(Color.foreground, 0.1)
                  implicitWidth: gitBadgeText.implicitWidth + Style.space(8)
                  implicitHeight: gitBadgeText.implicitHeight + Style.space(4)
                  Text {
                    id: gitBadgeText
                    anchors.centerIn: parent
                    text: "\uF126 " + (modelData.gitBranch || "")
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: Style.space(10)
                    color: Color.foreground
                  }
                }

                Item { Layout.fillWidth: true }

                Text {
                  text: modelData.targetDisplay
                  font.pixelSize: Style.space(13)
                  font.weight: Font.Bold
                  color: modelData.hasTarget ? Color.accent : Color.muted
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
                  color: Color.muted
                  elide: Text.ElideMiddle
                }

                Text {
                  text: modelData.daysSinceBuild >= 0 ? ("Built " + modelData.daysSinceBuild + "d ago") : "Clean"
                  font.pixelSize: Style.space(11)
                  color: modelData.daysSinceBuild > root.staleDays ? Color.urgent : Color.muted
                }
              }

              // Bottom row: Action Buttons
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                Text {
                  text: "Source: " + modelData.sourceDisplay
                  font.pixelSize: Style.space(10)
                  color: Color.muted
                }

                Item { Layout.fillWidth: true }

                // Clean button
                Button {
                  visible: modelData.hasTarget
                  text: "\uF0E2 Clean"
                  tooltipText: "Run cargo clean on " + modelData.name + " (" + modelData.targetDisplay + ")"
                  bordered: true
                  verticalPadding: Style.space(2)
                  horizontalPadding: Style.space(8)
                  onClicked: root.cleanSingle(modelData.path)
                }

                // Terminal
                Button {
                  iconText: "\uEA85"
                  tooltipText: "Open terminal in " + modelData.displayPath
                  bordered: true
                  verticalPadding: Style.space(2)
                  horizontalPadding: Style.space(6)
                  onClicked: root.openTerm(modelData.path)
                }

                // Editor
                Button {
                  iconText: "\uF044"
                  tooltipText: "Open project in default code editor"
                  bordered: true
                  verticalPadding: Style.space(2)
                  horizontalPadding: Style.space(6)
                  onClicked: root.openEditor(modelData.path)
                }

                // Files
                Button {
                  iconText: "\uF07B"
                  tooltipText: "Reveal folder in file manager"
                  bordered: true
                  verticalPadding: Style.space(2)
                  horizontalPadding: Style.space(6)
                  onClicked: root.openFiles(modelData.path)
                }
              }
            }
          }
        }
      }
    }
  }
}
