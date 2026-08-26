import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.06chaynes.github-tracker"
  ipcTarget: "io.github.06chaynes.github-tracker"
  manageIpc: false

  // CI, review and check states carry meaning a theme must not repaint: green
  // reads "passed", amber "running", red "failed". Red has a theme token;
  // the other two do not, so they are pinned once here rather than scattered
  // as literals through the file.
  readonly property color statusOk: "#50fa7b"
  readonly property color statusBusy: "#f1fa8c"
  readonly property color statusBad: Color.urgent

  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("bin/githubctl").toString().replace(/^file:\/\//, ""))
  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property var rawData: ({})
  property var organizations: []
  property string selectedOrg: "personal" // "personal" (default), "all", or "<org_login>"
  property bool orgDropdownOpen: false

  property var pinnedRepos: []
  property var allRepos: []
  property var myPullRequests: []
  property var reviewRequests: []
  property var actionAlerts: []
  property var actionRuns: []
  property var stats: ({
    failingActionsCount: 0,
    reviewRequestsCount: 0,
    myPrsCount: 0,
    pinnedCount: 0,
    runningActionsCount: 0,
    actionRunsCount: 0,
    totalRepoCount: 0,
    orgCount: 0
  })
  property string login: ""
  property string userName: ""
  property string avatarUrl: ""
  property string activeTab: "alerts" // "alerts", "actions", "reviews", "my_prs", "pinned"
  property string searchQuery: ""
  property int selectedIndex: 0
  property bool isFetching: false
  property string errorMessage: ""

  function isItemInOrg(repoWithOwner) {
    if (!repoWithOwner) return false;
    if (root.selectedOrg === "all") return true;
    var parts = repoWithOwner.split("/");
    var owner = parts[0] || "";
    if (root.selectedOrg === "personal") {
      return root.login ? (owner.toLowerCase() === root.login.toLowerCase()) : true;
    }
    return owner.toLowerCase() === root.selectedOrg.toLowerCase();
  }

  readonly property var filteredAlerts: {
    var q = (root.searchQuery || "").toLowerCase();
    var list = root.actionAlerts || [];
    return list.filter(function(a) {
      if (!root.isItemInOrg(a.repository)) return false;
      if (!q) return true;
      return (a.repository || "").toLowerCase().includes(q) || (a.title || "").toLowerCase().includes(q);
    });
  }

  readonly property var filteredActions: {
    var q = (root.searchQuery || "").toLowerCase();
    var list = root.actionRuns || [];
    return list.filter(function(a) {
      if (!root.isItemInOrg(a.repository)) return false;
      if (!q) return true;
      return (a.repository || "").toLowerCase().includes(q) || (a.name || "").toLowerCase().includes(q) || (a.headBranch || "").toLowerCase().includes(q) || (a.commitMessage || "").toLowerCase().includes(q);
    });
  }

  readonly property var filteredReviews: {
    var q = (root.searchQuery || "").toLowerCase();
    var list = root.reviewRequests || [];
    return list.filter(function(r) {
      if (!root.isItemInOrg(r.repository)) return false;
      if (!q) return true;
      return (r.repository || "").toLowerCase().includes(q) || (r.title || "").toLowerCase().includes(q) || (r.author || "").toLowerCase().includes(q);
    });
  }

  readonly property var filteredPrs: {
    var q = (root.searchQuery || "").toLowerCase();
    var list = root.myPullRequests || [];
    return list.filter(function(p) {
      if (!root.isItemInOrg(p.repository)) return false;
      if (!q) return true;
      return (p.repository || "").toLowerCase().includes(q) || (p.title || "").toLowerCase().includes(q) || (p.headRef || "").toLowerCase().includes(q);
    });
  }

  readonly property var filteredPinned: {
    var q = (root.searchQuery || "").toLowerCase();
    var sourceList = (q || (root.selectedOrg !== "personal" && root.selectedOrg !== "all")) ? (root.allRepos || []) : (root.pinnedRepos || []);
    return sourceList.filter(function(r) {
      if (!root.isItemInOrg(r.nameWithOwner)) return false;
      if (!q) return true;
      return (r.nameWithOwner || "").toLowerCase().includes(q);
    });
  }

  function selectedOrgLabel() {
    if (root.selectedOrg === "personal") return root.login ? ("@" + root.login + " (Personal)") : "Personal";
    if (root.selectedOrg === "all") return "All Accounts (" + (root.organizations.length + 1) + ")";
    for (var i = 0; i < root.organizations.length; i++) {
      if (root.organizations[i].login.toLowerCase() === root.selectedOrg.toLowerCase()) {
        return root.organizations[i].name || root.organizations[i].login;
      }
    }
    return root.selectedOrg;
  }

  function selectOrg(orgLogin) {
    root.selectedOrg = orgLogin;
    root.orgDropdownOpen = false;
    setOrgProc.command = [root.helperPath, "set-org", orgLogin];
    setOrgProc.running = true;

    // Smart tab adjustment for the newly selected org
    Qt.callLater(function() {
      if (root.filteredAlerts.length > 0) root.activeTab = "alerts";
      else if (root.filteredActions.length > 0) root.activeTab = "actions";
      else if (root.filteredPrs.length > 0) root.activeTab = "my_prs";
      else root.activeTab = "pinned";
    });
  }

  function updateData(data) {
    if (!data || !data.ok) return;
    root.rawData = data;
    root.login = data.login || "";
    root.userName = data.name || "";
    root.avatarUrl = data.avatarUrl || "";
    root.selectedOrg = data.selectedOrg || root.selectedOrg || "personal";
    root.organizations = data.organizations || [];
    root.pinnedRepos = data.pinnedRepos || [];
    root.allRepos = data.allRepos || [];
    root.myPullRequests = data.myPullRequests || [];
    root.reviewRequests = data.reviewRequests || [];
    root.actionAlerts = data.actionAlerts || [];
    root.actionRuns = data.actionRuns || [];
    root.stats = data.stats || root.stats;
    root.errorMessage = "";

    if (root.activeTab === "alerts" && root.filteredAlerts.length === 0) {
      if (root.filteredActions.length > 0) root.activeTab = "actions";
      else if (root.filteredReviews.length > 0) root.activeTab = "reviews";
      else if (root.filteredPrs.length > 0) root.activeTab = "my_prs";
      else root.activeTab = "pinned";
    }
  }

  function open() {
    root.orgDropdownOpen = false;
    root.controller.show();
    root.refresh();
  }

  function openFromHotkey() {
    root.open();
  }

  function close() {
    root.orgDropdownOpen = false;
    root.controller.hide();
  }

  function toggle() {
    if (root.opened) root.close();
    else root.open();
  }

  function refresh() {
    if (root.isFetching) return;
    root.isFetching = true;
    fetchProc.running = true;
  }

  function togglePin(repoName) {
    if (!repoName) return;
    root.isFetching = true;
    pinProc.command = [root.helperPath, "toggle-pin", repoName];
    pinProc.running = true;
  }

  function openUrl(url) {
    if (!url) return;
    Quickshell.execDetached(["xdg-open", url]);
  }

  Process {
    id: cacheProc
    command: [root.helperPath, "cache"]
    stdout: StdioCollector {
      id: cacheOut
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(cacheOut.text || cacheOut.value || "");
          if (data.ok) root.updateData(data);
        } catch (e) {}
      }
    }
  }

  Process {
    id: setOrgProc
    stdout: StdioCollector {
      id: setOrgOut
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(setOrgOut.text || setOrgOut.value || "");
          if (data.ok) root.updateData(data);
        } catch (e) {}
      }
    }
  }

  Process {
    id: fetchProc
    command: [root.helperPath, "fetch"]
    stdout: StdioCollector {
      id: panelFetchOut
      waitForEnd: true
      onStreamFinished: {
        root.isFetching = false;
        try {
          var data = JSON.parse(panelFetchOut.text || panelFetchOut.value || "");
          if (data.ok) {
            root.updateData(data);
          } else {
            root.errorMessage = data.error || "Failed to fetch GitHub data";
          }
        } catch (e) {
          root.errorMessage = "Failed to parse GitHub response";
        }
      }
    }
    onExited: {
      root.isFetching = false;
    }
  }

  Process {
    id: pinProc
    stdout: StdioCollector {
      id: panelPinOut
      waitForEnd: true
      onStreamFinished: {
        root.isFetching = false;
        try {
          var data = JSON.parse(panelPinOut.text || panelPinOut.value || "");
          if (data.ok) {
            root.updateData(data);
          }
        } catch (e) {}
      }
    }
    onExited: {
      root.isFetching = false;
    }
  }

  Component.onCompleted: {
    cacheProc.running = true;
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(660))
    contentHeight: panel.fittedContentHeight(Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchInput.activeFocus
      onCloseRequested: {
        if (root.orgDropdownOpen) {
          root.orgDropdownOpen = false;
        } else {
          root.close();
        }
      }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh();
        else if (t === "1") { root.activeTab = "alerts"; root.orgDropdownOpen = false; }
        else if (t === "2") { root.activeTab = "actions"; root.orgDropdownOpen = false; }
        else if (t === "3") { root.activeTab = "reviews"; root.orgDropdownOpen = false; }
        else if (t === "4") { root.activeTab = "my_prs"; root.orgDropdownOpen = false; }
        else if (t === "5") { root.activeTab = "pinned"; root.orgDropdownOpen = false; }
        else if (t === "o" || t === "O") { root.orgDropdownOpen = !root.orgDropdownOpen; }
        else if (t === "/") { searchInput.forceActiveFocus(); root.orgDropdownOpen = false; }
      }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(14)
        spacing: Style.space(10)

        // --- HEADER & ORG SELECTOR ---
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)

          Text {
            text: "󰊤"
            font.family: "Symbols Nerd Font Mono"
            font.pixelSize: Style.space(24)
            color: Color.accent
          }

          ColumnLayout {
            spacing: 1
            Text {
              text: root.userName ? (root.userName + " (" + root.login + ")") : (root.login ? ("@" + root.login) : "GitHub Tracker")
              font.pixelSize: 15
              font.weight: Font.DemiBold
              color: Color.foreground
            }
            Text {
              text: root.isFetching ? "Refreshing GitHub status…" : "Live CI/CD & Project Activity"
              font.pixelSize: 11
              color: Color.muted
            }
          }

          Item { Layout.fillWidth: true }

          // Org Selector Button
          Button {
            iconText: root.selectedOrg === "personal" ? "󰀄" : (root.selectedOrg === "all" ? "󰖟" : "󰌦")
            text: root.selectedOrgLabel() + (root.orgDropdownOpen ? "  ▴" : "  ▾")
            tooltipText: "Switch organisation"
            bordered: true
            selected: root.orgDropdownOpen
            onClicked: root.orgDropdownOpen = !root.orgDropdownOpen
          }

          // Refresh Button
          Button {
            iconText: "󰑐"
            tooltipText: "Refresh GitHub status"
            bordered: true
            foreground: root.isFetching ? Color.accent : Color.foreground
            onClicked: root.refresh()
          }
        }

        // --- 5-TAB BAR ---
        Rectangle {
          Layout.fillWidth: true
          height: Style.space(36)
          color: Util.alpha(Color.foreground, 0.04)
          radius: 8
          border.color: Util.alpha(Color.foreground, 0.1)
          border.width: 1

          RowLayout {
            anchors.fill: parent
            anchors.margins: Style.space(3)
            spacing: Style.space(3)

            // Tab 1: Action Alerts
            Button {
              Layout.fillWidth: true
              iconText: "󰅚"
              text: "Alerts" + (root.filteredAlerts.length > 0 ? " (" + root.filteredAlerts.length + ")" : "")
              bordered: true
              selected: root.activeTab === "alerts"
              foreground: root.filteredAlerts.length > 0 ? Color.urgent : Color.foreground
              onClicked: { root.activeTab = "alerts"; root.orgDropdownOpen = false; }
            }

            // Tab 2: Actions Log
            Button {
              Layout.fillWidth: true
              iconText: "⚡"
              text: "Actions" + (root.filteredActions.length > 0 ? " (" + root.filteredActions.length + ")" : "")
              bordered: true
              selected: root.activeTab === "actions"
              foreground: root.stats.runningActionsCount > 0 ? root.statusBusy : Color.foreground
              onClicked: { root.activeTab = "actions"; root.orgDropdownOpen = false; }
            }

            // Tab 3: Review Requests
            Button {
              Layout.fillWidth: true
              iconText: ""
              text: "Reviews" + (root.filteredReviews.length > 0 ? " (" + root.filteredReviews.length + ")" : "")
              bordered: true
              selected: root.activeTab === "reviews"
              onClicked: { root.activeTab = "reviews"; root.orgDropdownOpen = false; }
            }

            // Tab 4: My Pull Requests
            Button {
              Layout.fillWidth: true
              iconText: ""
              text: "My PRs" + (root.filteredPrs.length > 0 ? " (" + root.filteredPrs.length + ")" : "")
              bordered: true
              selected: root.activeTab === "my_prs"
              onClicked: { root.activeTab = "my_prs"; root.orgDropdownOpen = false; }
            }

            // Tab 5: Repositories (Pinned / All)
            Button {
              Layout.fillWidth: true
              iconText: "󰤱"
              text: (root.selectedOrg === "personal" || root.selectedOrg === "all" ? "Pinned" : "Repos") + " (" + root.filteredPinned.length + ")"
              bordered: true
              selected: root.activeTab === "pinned"
              onClicked: { root.activeTab = "pinned"; root.orgDropdownOpen = false; }
            }
          }
        }

        // --- SEARCH & FILTER BAR ---
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          TextField {
            id: searchInput
            Layout.fillWidth: true
            verticalPadding: Style.space(5)
            placeholderText: root.activeTab === "pinned"
              ? "Search repositories or type to find any repo to pin…"
              : "Filter items in this view…"
            onTextChanged: root.searchQuery = text
          }

          Button {
            visible: searchInput.text.length > 0
            text: "×"
            tooltipText: "Clear filter"
            bordered: true
            verticalPadding: Style.space(3)
            horizontalPadding: Style.space(9)
            onClicked: {
              searchInput.text = "";
              root.searchQuery = "";
            }
          }
        }

        // --- ERROR BANNER ---
        Rectangle {
          Layout.fillWidth: true
          height: Style.space(32)
          color: Util.alpha(root.statusBad, 0.2)
          radius: 6
          border.color: Color.urgent
          border.width: 1
          visible: root.errorMessage.length > 0

          RowLayout {
            anchors.fill: parent
            anchors.margins: Style.space(6)
            spacing: Style.space(8)
            Text {
              text: "󰅚"
              font.family: "Symbols Nerd Font Mono"
              color: Color.urgent
            }
            Text {
              Layout.fillWidth: true
              text: root.errorMessage
              color: Color.urgent
              font.pixelSize: 11
              elide: Text.ElideRight
            }
          }
        }

        // --- MAIN CONTENT AREA WITH DROPDOWN OVERLAY ---
        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          // 1. TAB: ACTION ALERTS
          ListView {
            id: alertsList
            anchors.fill: parent
            visible: root.activeTab === "alerts"
            spacing: Style.space(8)
            clip: true
            model: root.filteredAlerts

            delegate: Rectangle {
              width: alertsList.width
              height: Style.space(60)
              color: alertCardMouse.containsMouse ? Util.alpha(Color.foreground, 0.1) : Util.alpha(Color.foreground, 0.05)
              radius: 8
              border.color: modelData.state === "FAILURE" ? Color.urgent : (modelData.state === "PENDING" ? root.statusBusy : Util.alpha(Color.foreground, 0.15))
              border.width: 1

              RowLayout {
                anchors.fill: parent
                anchors.margins: Style.space(10)
                spacing: Style.space(10)

                Rectangle {
                  width: Style.space(30)
                  height: Style.space(30)
                  radius: 6
                  color: modelData.state === "FAILURE" ? Util.alpha(root.statusBad, 0.2) : Util.alpha(root.statusBusy, 0.2)

                  Text {
                    anchors.centerIn: parent
                    text: modelData.state === "FAILURE" ? "󰅚" : "󰔟"
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: 15
                    color: modelData.state === "FAILURE" ? Color.urgent : root.statusBusy
                  }
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 1

                  RowLayout {
                    spacing: Style.space(6)
                    Text {
                      text: modelData.repository
                      font.pixelSize: 13
                      font.weight: Font.DemiBold
                      color: Color.foreground
                    }
                    Rectangle {
                      height: Style.space(16)
                      width: alertKindText.implicitWidth + Style.space(8)
                      radius: 4
                      color: modelData.kind === "default_branch" ? Util.alpha(Color.accent, 0.2) : Util.alpha(Color.foreground, 0.1)
                      border.color: modelData.kind === "default_branch" ? Color.accent : Util.alpha(Color.foreground, 0.2)
                      border.width: 1

                      Text {
                        id: alertKindText
                        anchors.centerIn: parent
                        text: modelData.kind === "default_branch" ? "Default Branch" : "Pull Request"
                        font.pixelSize: 10
                        color: modelData.kind === "default_branch" ? Color.accent : Color.muted
                      }
                    }
                  }

                  Text {
                    Layout.fillWidth: true
                    text: modelData.title + (modelData.commit ? " — " + modelData.commit : "")
                    font.pixelSize: 11
                    color: Color.muted
                    elide: Text.ElideRight
                  }
                }

                Text {
                  text: "󰌹 View"
                  font.family: "Symbols Nerd Font Mono"
                  font.pixelSize: 12
                  color: Color.accent
                }
              }

              MouseArea {
                id: alertCardMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openUrl(modelData.url)
              }
            }

            Item {
              anchors.fill: parent
              visible: alertsList.count === 0

              ColumnLayout {
                anchors.centerIn: parent
                spacing: Style.space(6)
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "󰄲"
                  font.family: "Symbols Nerd Font Mono"
                  font.pixelSize: 32
                  color: root.statusOk
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "All workflows & default branches are healthy!"
                  font.pixelSize: 14
                  font.weight: Font.DemiBold
                  color: Color.foreground
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "No failing CI runs detected in this account context."
                  font.pixelSize: 12
                  color: Color.muted
                }
              }
            }
          }

          // 2. TAB: ACTIONS LOG
          ListView {
            id: actionsList
            anchors.fill: parent
            visible: root.activeTab === "actions"
            spacing: Style.space(8)
            clip: true
            model: root.filteredActions

            delegate: Rectangle {
              width: actionsList.width
              height: Style.space(64)
              color: runCardMouse.containsMouse ? Util.alpha(Color.foreground, 0.1) : Util.alpha(Color.foreground, 0.05)
              radius: 8
              border.color: modelData.conclusion === "failure" ? Color.urgent : (modelData.status === "in_progress" ? root.statusBusy : Util.alpha(Color.foreground, 0.15))
              border.width: 1

              RowLayout {
                anchors.fill: parent
                anchors.margins: Style.space(10)
                spacing: Style.space(10)

                Rectangle {
                  width: Style.space(30)
                  height: Style.space(30)
                  radius: 6
                  color: modelData.conclusion === "success" ? Util.alpha(root.statusOk, 0.2) : (modelData.conclusion === "failure" ? Util.alpha(root.statusBad, 0.2) : (modelData.status === "in_progress" ? Util.alpha(root.statusBusy, 0.2) : Util.alpha(Color.foreground, 0.08)))

                  Text {
                    anchors.centerIn: parent
                    text: modelData.conclusion === "success" ? "󰄲" : (modelData.conclusion === "failure" ? "󰅚" : (modelData.status === "in_progress" ? "󰔟" : (modelData.conclusion === "cancelled" ? "󰜺" : "⚡")))
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: 15
                    color: modelData.conclusion === "success" ? root.statusOk : (modelData.conclusion === "failure" ? Color.urgent : (modelData.status === "in_progress" ? root.statusBusy : Color.muted))
                  }
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 1

                  RowLayout {
                    spacing: Style.space(6)
                    Text {
                      text: modelData.repository
                      font.pixelSize: 12
                      font.weight: Font.DemiBold
                      color: Color.accent
                    }
                    Text {
                      text: "• " + modelData.name
                      font.pixelSize: 12
                      font.weight: Font.Medium
                      color: Color.foreground
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                    }
                    Rectangle {
                      height: Style.space(16)
                      width: branchText.implicitWidth + Style.space(8)
                      radius: 4
                      color: Util.alpha(Color.foreground, 0.1)
                      border.color: Util.alpha(Color.foreground, 0.2)
                      border.width: 1

                      Text {
                        id: branchText
                        anchors.centerIn: parent
                        text: modelData.headBranch + (modelData.headSha ? " (" + modelData.headSha + ")" : "")
                        font.pixelSize: 10
                        color: Color.foreground
                      }
                    }
                  }

                  RowLayout {
                    spacing: Style.space(8)
                    Text {
                      text: (modelData.commitMessage || modelData.event) + (modelData.actor ? " by @" + modelData.actor : "")
                      font.pixelSize: 11
                      color: Color.muted
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                    }
                    Text {
                      text: modelData.status === "in_progress" ? "In Progress" : (modelData.conclusion === "success" ? "Passed" : (modelData.conclusion === "failure" ? "Failed" : modelData.conclusion))
                      font.pixelSize: 10
                      font.weight: Font.DemiBold
                      color: modelData.conclusion === "success" ? root.statusOk : (modelData.conclusion === "failure" ? Color.urgent : (modelData.status === "in_progress" ? root.statusBusy : Color.muted))
                    }
                  }
                }

                Text {
                  text: "󰌹"
                  font.family: "Symbols Nerd Font Mono"
                  font.pixelSize: 14
                  color: Color.accent
                }
              }

              MouseArea {
                id: runCardMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openUrl(modelData.url)
              }
            }

            Item {
              anchors.fill: parent
              visible: actionsList.count === 0

              ColumnLayout {
                anchors.centerIn: parent
                spacing: Style.space(6)
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "⚡"
                  font.pixelSize: 32
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "No recent Actions runs"
                  font.pixelSize: 14
                  font.weight: Font.DemiBold
                  color: Color.foreground
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "No workflow runs found in this organization context."
                  font.pixelSize: 12
                  color: Color.muted
                }
              }
            }
          }

          // 3. TAB: REVIEW REQUESTS
          ListView {
            id: reviewsList
            anchors.fill: parent
            visible: root.activeTab === "reviews"
            spacing: Style.space(8)
            clip: true
            model: root.filteredReviews

            delegate: Rectangle {
              width: reviewsList.width
              height: Style.space(64)
              color: reviewCardMouse.containsMouse ? Util.alpha(Color.foreground, 0.1) : Util.alpha(Color.foreground, 0.05)
              radius: 8
              border.color: Util.alpha(Color.foreground, 0.15)
              border.width: 1

              RowLayout {
                anchors.fill: parent
                anchors.margins: Style.space(10)
                spacing: Style.space(10)

                Rectangle {
                  width: Style.space(30)
                  height: Style.space(30)
                  radius: 6
                  color: Util.alpha(root.statusBusy, 0.2)

                  Text {
                    anchors.centerIn: parent
                    text: ""
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: 15
                    color: root.statusBusy
                  }
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 1

                  RowLayout {
                    spacing: Style.space(6)
                    Text {
                      text: modelData.repository + " #" + modelData.number
                      font.pixelSize: 12
                      font.weight: Font.DemiBold
                      color: Color.accent
                    }
                    Text {
                      text: "by @" + modelData.author
                      font.pixelSize: 11
                      color: Color.muted
                    }
                  }

                  Text {
                    Layout.fillWidth: true
                    text: modelData.title
                    font.pixelSize: 13
                    color: Color.foreground
                    elide: Text.ElideRight
                  }
                }

                Text {
                  text: "󰌹 Review"
                  font.family: "Symbols Nerd Font Mono"
                  font.pixelSize: 12
                  color: Color.accent
                }
              }

              MouseArea {
                id: reviewCardMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openUrl(modelData.url)
              }
            }

            Item {
              anchors.fill: parent
              visible: reviewsList.count === 0

              ColumnLayout {
                anchors.centerIn: parent
                spacing: Style.space(6)
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "󰄲"
                  font.family: "Symbols Nerd Font Mono"
                  font.pixelSize: 32
                  color: Color.muted
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "Inbox zero on review requests"
                  font.pixelSize: 14
                  font.weight: Font.DemiBold
                  color: Color.foreground
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "No pull requests currently request your review in this scope."
                  font.pixelSize: 12
                  color: Color.muted
                }
              }
            }
          }

          // 4. TAB: MY PULL REQUESTS
          ListView {
            id: prsList
            anchors.fill: parent
            visible: root.activeTab === "my_prs"
            spacing: Style.space(8)
            clip: true
            model: root.filteredPrs

            delegate: Rectangle {
              width: prsList.width
              height: Style.space(68)
              color: prCardMouse.containsMouse ? Util.alpha(Color.foreground, 0.1) : Util.alpha(Color.foreground, 0.05)
              radius: 8
              border.color: modelData.ciState === "FAILURE" ? Color.urgent : Util.alpha(Color.foreground, 0.15)
              border.width: 1

              RowLayout {
                anchors.fill: parent
                anchors.margins: Style.space(10)
                spacing: Style.space(10)

                Rectangle {
                  width: Style.space(30)
                  height: Style.space(30)
                  radius: 6
                  color: modelData.ciState === "SUCCESS" ? Util.alpha(root.statusOk, 0.2) : (modelData.ciState === "FAILURE" ? Util.alpha(root.statusBad, 0.2) : Util.alpha(Color.foreground, 0.08))

                  Text {
                    anchors.centerIn: parent
                    text: modelData.ciState === "SUCCESS" ? "󰄲" : (modelData.ciState === "FAILURE" ? "󰅚" : (modelData.ciState === "PENDING" ? "󰔟" : ""))
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: 15
                    color: modelData.ciState === "SUCCESS" ? root.statusOk : (modelData.ciState === "FAILURE" ? Color.urgent : (modelData.ciState === "PENDING" ? root.statusBusy : Color.accent))
                  }
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 1

                  RowLayout {
                    spacing: Style.space(6)
                    Text {
                      text: modelData.repository + " #" + modelData.number
                      font.pixelSize: 12
                      font.weight: Font.DemiBold
                      color: Color.accent
                    }
                    Text {
                      text: "on " + modelData.headRef
                      font.pixelSize: 11
                      color: Color.muted
                    }
                    Rectangle {
                      height: Style.space(16)
                      width: reviewBadgeText.implicitWidth + Style.space(8)
                      radius: 4
                      color: modelData.reviewDecision === "APPROVED" ? Util.alpha(root.statusOk, 0.2) : (modelData.reviewDecision === "CHANGES_REQUESTED" ? Util.alpha(root.statusBad, 0.2) : Util.alpha(Color.foreground, 0.1))
                      border.color: modelData.reviewDecision === "APPROVED" ? root.statusOk : (modelData.reviewDecision === "CHANGES_REQUESTED" ? Color.urgent : Util.alpha(Color.foreground, 0.2))
                      border.width: 1

                      Text {
                        id: reviewBadgeText
                        anchors.centerIn: parent
                        text: modelData.reviewDecision === "APPROVED" ? "Approved" : (modelData.reviewDecision === "CHANGES_REQUESTED" ? "Changes Requested" : "Review Pending")
                        font.pixelSize: 10
                        color: modelData.reviewDecision === "APPROVED" ? root.statusOk : (modelData.reviewDecision === "CHANGES_REQUESTED" ? Color.urgent : Color.muted)
                      }
                    }
                  }

                  Text {
                    Layout.fillWidth: true
                    text: modelData.title
                    font.pixelSize: 13
                    color: Color.foreground
                    elide: Text.ElideRight
                  }
                }

                Text {
                  text: "󰌹 Open"
                  font.family: "Symbols Nerd Font Mono"
                  font.pixelSize: 12
                  color: Color.accent
                }
              }

              MouseArea {
                id: prCardMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openUrl(modelData.url)
              }
            }

            Item {
              anchors.fill: parent
              visible: prsList.count === 0

              ColumnLayout {
                anchors.centerIn: parent
                spacing: Style.space(6)
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: ""
                  font.family: "Symbols Nerd Font Mono"
                  font.pixelSize: 32
                  color: Color.muted
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "No open pull requests"
                  font.pixelSize: 14
                  font.weight: Font.DemiBold
                  color: Color.foreground
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "You don't have any authored pull requests open in this context."
                  font.pixelSize: 12
                  color: Color.muted
                }
              }
            }
          }

          // 5. TAB: REPOSITORIES (PINNED / ALL)
          ListView {
            id: pinnedList
            anchors.fill: parent
            visible: root.activeTab === "pinned"
            spacing: Style.space(8)
            clip: true
            model: root.filteredPinned

            delegate: Rectangle {
              width: pinnedList.width
              height: Style.space(68)
              color: pinnedCardMouse.containsMouse ? Util.alpha(Color.foreground, 0.1) : Util.alpha(Color.foreground, 0.05)
              radius: 8
              border.color: modelData.ciState === "FAILURE" ? Color.urgent : Util.alpha(Color.foreground, 0.15)
              border.width: 1

              RowLayout {
                anchors.fill: parent
                anchors.margins: Style.space(10)
                spacing: Style.space(10)

                Rectangle {
                  width: Style.space(30)
                  height: Style.space(30)
                  radius: 6
                  color: modelData.ciState === "SUCCESS" ? Util.alpha(root.statusOk, 0.2) : (modelData.ciState === "FAILURE" ? Util.alpha(root.statusBad, 0.2) : Util.alpha(Color.foreground, 0.08))

                  Text {
                    anchors.centerIn: parent
                    text: modelData.ciState === "SUCCESS" ? "󰄲" : (modelData.ciState === "FAILURE" ? "󰅚" : (modelData.ciState === "PENDING" ? "󰔟" : "󰘬"))
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: 15
                    color: modelData.ciState === "SUCCESS" ? root.statusOk : (modelData.ciState === "FAILURE" ? Color.urgent : (modelData.ciState === "PENDING" ? root.statusBusy : Color.accent))
                  }
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 1

                  RowLayout {
                    spacing: Style.space(8)
                    Text {
                      text: modelData.nameWithOwner
                      font.pixelSize: 13
                      font.weight: Font.DemiBold
                      color: Color.foreground
                    }
                    Text {
                      text: "branch: " + modelData.defaultBranch
                      font.pixelSize: 11
                      color: Color.muted
                    }
                  }

                  RowLayout {
                    spacing: Style.space(10)
                    Text {
                      text: " " + modelData.openPrs + " PRs"
                      font.family: "Symbols Nerd Font Mono"
                      font.pixelSize: 11
                      color: modelData.openPrs > 0 ? Color.accent : Color.muted
                    }
                    Text {
                      text: " " + modelData.openIssues + " Issues"
                      font.family: "Symbols Nerd Font Mono"
                      font.pixelSize: 11
                      color: modelData.openIssues > 0 ? root.statusBusy : Color.muted
                    }
                    Text {
                      text: "★ " + modelData.stargazerCount
                      font.pixelSize: 11
                      color: Color.muted
                    }
                  }
                }

                // Toggle Pin Button
                Button {
                  iconText: modelData.isPinned ? "󰤱" : "󰤲"
                  tooltipText: modelData.isPinned ? "Unpin repository" : "Pin repository"
                  bordered: true
                  selected: modelData.isPinned
                  verticalPadding: Style.space(2)
                  horizontalPadding: Style.space(6)
                  onClicked: root.togglePin(modelData.nameWithOwner)
                }

                Text {
                  text: "󰌹"
                  font.family: "Symbols Nerd Font Mono"
                  font.pixelSize: 14
                  color: Color.accent
                }
              }

              MouseArea {
                id: pinnedCardMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openUrl(modelData.url)
              }
            }

            Item {
              anchors.fill: parent
              visible: pinnedList.count === 0

              ColumnLayout {
                anchors.centerIn: parent
                spacing: Style.space(6)
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "󰤲"
                  font.family: "Symbols Nerd Font Mono"
                  font.pixelSize: 32
                  color: Color.muted
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "No repositories found"
                  font.pixelSize: 14
                  font.weight: Font.DemiBold
                  color: Color.foreground
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "Type in the search bar above to search or pin repositories."
                  font.pixelSize: 12
                  color: Color.muted
                }
              }
            }
          }

          // --- ORG SELECTOR POPUP DROPDOWN MENU ---
          Rectangle {
            id: orgDropdownMenu
            anchors.top: parent.top
            anchors.right: parent.right
            width: Style.space(280)
            height: Math.min(Style.space(340), orgList.contentHeight + Style.space(16))
            radius: 8
            color: Color.popups.background
            border.color: Color.accent
            border.width: 1
            visible: root.orgDropdownOpen
            z: 999

            ColumnLayout {
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(4)

              Text {
                text: "SELECT ACCOUNT / ORG"
                font.pixelSize: 10
                font.weight: Font.Bold
                color: Color.muted
                Layout.leftMargin: Style.space(6)
                Layout.topMargin: Style.space(4)
              }

              ListView {
                id: orgList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: Style.space(2)

                model: {
                  var items = [
                    { login: "personal", name: root.login ? ("@" + root.login + " (Personal)") : "Personal Account", type: "personal", count: "" },
                    { login: "all", name: "All Accounts", type: "all", count: (root.organizations.length + 1) + " accounts" }
                  ];
                  for (var i = 0; i < root.organizations.length; i++) {
                    var o = root.organizations[i];
                    items.push({ login: o.login, name: o.name || o.login, type: "org", count: o.repoCount ? (o.repoCount + " repos") : "" });
                  }
                  return items;
                }

                delegate: Rectangle {
                  width: orgList.width
                  height: Style.space(34)
                  radius: 6
                  color: (root.selectedOrg.toLowerCase() === modelData.login.toLowerCase()) ? Util.alpha(Color.accent, 0.25) : (orgItemMouse.containsMouse ? Util.alpha(Color.foreground, 0.1) : "transparent")

                  RowLayout {
                    anchors.fill: parent
                    anchors.margins: Style.space(8)
                    spacing: Style.space(8)

                    Text {
                      text: modelData.type === "personal" ? "👤" : (modelData.type === "all" ? "🌐" : "🏢")
                      font.pixelSize: 12
                    }

                    Text {
                      Layout.fillWidth: true
                      text: modelData.name
                      font.pixelSize: 12
                      font.weight: (root.selectedOrg.toLowerCase() === modelData.login.toLowerCase()) ? Font.DemiBold : Font.Normal
                      color: (root.selectedOrg.toLowerCase() === modelData.login.toLowerCase()) ? Color.accent : Color.foreground
                      elide: Text.ElideRight
                    }

                    Text {
                      text: modelData.count ? String(modelData.count) : ""
                      font.pixelSize: 10
                      color: Color.muted
                      visible: modelData.count.length > 0
                    }
                  }

                  MouseArea {
                    id: orgItemMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selectOrg(modelData.login)
                  }
                }
              }
            }
          }
        }

        // --- FOOTER SHORTCUTS ---
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(12)

          Text {
            text: "1-5: Switch Tabs   O: Select Org   /: Search/Pin   R: Refresh   Esc: Close"
            font.pixelSize: 11
            color: Color.muted
          }

          Item { Layout.fillWidth: true }

          Text {
            text: "Rate limit: " + (root.rawData.rateLimit ? (root.rawData.rateLimit.remaining + "/" + root.rawData.rateLimit.limit) : "5000")
            font.pixelSize: 10
            color: Color.muted
          }
        }
      }
    }
  }
}
