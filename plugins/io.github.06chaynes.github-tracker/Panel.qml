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
            color: Color.accent || "#bd93f9"
          }

          ColumnLayout {
            spacing: 1
            Text {
              text: root.userName ? (root.userName + " (" + root.login + ")") : (root.login ? ("@" + root.login) : "GitHub Tracker")
              font.pixelSize: 15
              font.weight: Font.DemiBold
              color: Color.foreground || "#f8f8f2"
            }
            Text {
              text: root.isFetching ? "Refreshing GitHub status…" : "Live CI/CD & Project Activity"
              font.pixelSize: 11
              color: Color.muted || "#6272a4"
            }
          }

          Item { Layout.fillWidth: true }

          // Org Selector Button
          Rectangle {
            height: Style.space(32)
            width: orgBtnLayout.implicitWidth + Style.space(16)
            radius: 6
            color: root.orgDropdownOpen ? Qt.rgba(0.7, 0.4, 1, 0.25) : (orgMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : Qt.rgba(1, 1, 1, 0.08))
            border.color: root.orgDropdownOpen ? (Color.accent || "#bd93f9") : Qt.rgba(1, 1, 1, 0.2)
            border.width: 1

            RowLayout {
              id: orgBtnLayout
              anchors.centerIn: parent
              spacing: Style.space(6)

              Text {
                text: root.selectedOrg === "personal" ? "👤" : (root.selectedOrg === "all" ? "🌐" : "🏢")
                font.pixelSize: 12
              }
              Text {
                text: root.selectedOrgLabel()
                font.pixelSize: 12
                font.weight: Font.DemiBold
                color: Color.foreground || "#f8f8f2"
              }
              Text {
                text: root.orgDropdownOpen ? "▴" : "▾"
                font.pixelSize: 10
                color: Color.muted || "#6272a4"
              }
            }

            MouseArea {
              id: orgMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.orgDropdownOpen = !root.orgDropdownOpen
            }
          }

          // Refresh Button
          Rectangle {
            width: Style.space(32)
            height: Style.space(32)
            radius: 6
            color: refreshMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : Qt.rgba(1, 1, 1, 0.08)
            border.color: Qt.rgba(1, 1, 1, 0.2)
            border.width: 1

            Text {
              anchors.centerIn: parent
              text: "󰑐"
              font.family: "Symbols Nerd Font Mono"
              font.pixelSize: 14
              color: root.isFetching ? (Color.accent || "#bd93f9") : (Color.foreground || "#f8f8f2")
              rotation: root.isFetching ? 180 : 0
              Behavior on rotation { NumberAnimation { duration: 400 } }
            }

            MouseArea {
              id: refreshMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.refresh()
            }
          }
        }

        // --- 5-TAB BAR ---
        Rectangle {
          Layout.fillWidth: true
          height: Style.space(36)
          color: Qt.rgba(1, 1, 1, 0.04)
          radius: 8
          border.color: Qt.rgba(1, 1, 1, 0.1)
          border.width: 1

          RowLayout {
            anchors.fill: parent
            anchors.margins: Style.space(3)
            spacing: Style.space(3)

            // Tab 1: Action Alerts
            Rectangle {
              Layout.fillWidth: true
              Layout.fillHeight: true
              radius: 6
              color: root.activeTab === "alerts" ? Qt.rgba(1, 1, 1, 0.15) : (tabAlertsMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : "transparent")
              border.color: root.activeTab === "alerts" ? (Color.accent || "#bd93f9") : "transparent"
              border.width: 1

              RowLayout {
                anchors.centerIn: parent
                spacing: Style.space(4)
                Text {
                  text: "󰅚"
                  font.family: "Symbols Nerd Font Mono"
                  font.pixelSize: 12
                  color: root.filteredAlerts.length > 0 ? (Color.urgent || "#ff5555") : (Color.muted || "#6272a4")
                }
                Text {
                  text: "Alerts" + (root.filteredAlerts.length > 0 ? " (" + root.filteredAlerts.length + ")" : "")
                  font.pixelSize: 11
                  font.weight: root.activeTab === "alerts" ? Font.DemiBold : Font.Normal
                  color: Color.foreground || "#f8f8f2"
                }
              }

              MouseArea {
                id: tabAlertsMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.activeTab = "alerts"; root.orgDropdownOpen = false; }
              }
            }

            // Tab 2: Actions Log
            Rectangle {
              Layout.fillWidth: true
              Layout.fillHeight: true
              radius: 6
              color: root.activeTab === "actions" ? Qt.rgba(1, 1, 1, 0.15) : (tabActionsMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : "transparent")
              border.color: root.activeTab === "actions" ? (Color.accent || "#bd93f9") : "transparent"
              border.width: 1

              RowLayout {
                anchors.centerIn: parent
                spacing: Style.space(4)
                Text {
                  text: "⚡"
                  font.pixelSize: 11
                  color: root.stats.runningActionsCount > 0 ? "#f1fa8c" : (Color.accent || "#bd93f9")
                }
                Text {
                  text: "Actions" + (root.filteredActions.length > 0 ? " (" + root.filteredActions.length + ")" : "")
                  font.pixelSize: 11
                  font.weight: root.activeTab === "actions" ? Font.DemiBold : Font.Normal
                  color: Color.foreground || "#f8f8f2"
                }
              }

              MouseArea {
                id: tabActionsMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.activeTab = "actions"; root.orgDropdownOpen = false; }
              }
            }

            // Tab 3: Review Requests
            Rectangle {
              Layout.fillWidth: true
              Layout.fillHeight: true
              radius: 6
              color: root.activeTab === "reviews" ? Qt.rgba(1, 1, 1, 0.15) : (tabReviewsMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : "transparent")
              border.color: root.activeTab === "reviews" ? (Color.accent || "#bd93f9") : "transparent"
              border.width: 1

              RowLayout {
                anchors.centerIn: parent
                spacing: Style.space(4)
                Text {
                  text: ""
                  font.family: "Symbols Nerd Font Mono"
                  font.pixelSize: 12
                  color: root.filteredReviews.length > 0 ? "#f1fa8c" : (Color.muted || "#6272a4")
                }
                Text {
                  text: "Reviews" + (root.filteredReviews.length > 0 ? " (" + root.filteredReviews.length + ")" : "")
                  font.pixelSize: 11
                  font.weight: root.activeTab === "reviews" ? Font.DemiBold : Font.Normal
                  color: Color.foreground || "#f8f8f2"
                }
              }

              MouseArea {
                id: tabReviewsMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.activeTab = "reviews"; root.orgDropdownOpen = false; }
              }
            }

            // Tab 4: My Pull Requests
            Rectangle {
              Layout.fillWidth: true
              Layout.fillHeight: true
              radius: 6
              color: root.activeTab === "my_prs" ? Qt.rgba(1, 1, 1, 0.15) : (tabPrsMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : "transparent")
              border.color: root.activeTab === "my_prs" ? (Color.accent || "#bd93f9") : "transparent"
              border.width: 1

              RowLayout {
                anchors.centerIn: parent
                spacing: Style.space(4)
                Text {
                  text: ""
                  font.family: "Symbols Nerd Font Mono"
                  font.pixelSize: 12
                  color: Color.accent || "#8be9fd"
                }
                Text {
                  text: "My PRs" + (root.filteredPrs.length > 0 ? " (" + root.filteredPrs.length + ")" : "")
                  font.pixelSize: 11
                  font.weight: root.activeTab === "my_prs" ? Font.DemiBold : Font.Normal
                  color: Color.foreground || "#f8f8f2"
                }
              }

              MouseArea {
                id: tabPrsMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.activeTab = "my_prs"; root.orgDropdownOpen = false; }
              }
            }

            // Tab 5: Repositories (Pinned / All)
            Rectangle {
              Layout.fillWidth: true
              Layout.fillHeight: true
              radius: 6
              color: root.activeTab === "pinned" ? Qt.rgba(1, 1, 1, 0.15) : (tabPinnedMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : "transparent")
              border.color: root.activeTab === "pinned" ? (Color.accent || "#bd93f9") : "transparent"
              border.width: 1

              RowLayout {
                anchors.centerIn: parent
                spacing: Style.space(4)
                Text {
                  text: "󰤱"
                  font.family: "Symbols Nerd Font Mono"
                  font.pixelSize: 12
                  color: Color.accent || "#bd93f9"
                }
                Text {
                  text: (root.selectedOrg === "personal" || root.selectedOrg === "all" ? "Pinned" : "Repos") + " (" + root.filteredPinned.length + ")"
                  font.pixelSize: 11
                  font.weight: root.activeTab === "pinned" ? Font.DemiBold : Font.Normal
                  color: Color.foreground || "#f8f8f2"
                }
              }

              MouseArea {
                id: tabPinnedMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.activeTab = "pinned"; root.orgDropdownOpen = false; }
              }
            }
          }
        }

        // --- SEARCH & FILTER BAR ---
        Rectangle {
          Layout.fillWidth: true
          height: Style.space(32)
          color: Qt.rgba(1, 1, 1, 0.06)
          radius: 6
          border.color: searchInput.activeFocus ? (Color.accent || "#bd93f9") : Qt.rgba(1, 1, 1, 0.15)
          border.width: 1

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(8)

            Text {
              text: "󰍉"
              font.family: "Symbols Nerd Font Mono"
              font.pixelSize: 13
              color: Color.muted || "#6272a4"
            }

            TextInput {
              id: searchInput
              Layout.fillWidth: true
              text: root.searchQuery
              color: Color.foreground || "#f8f8f2"
              font.pixelSize: 12
              clip: true
              onTextChanged: root.searchQuery = text

              Text {
                anchors.fill: parent
                text: root.activeTab === "pinned" ? "Search repositories or type to find any repo to pin…" : "Filter items in this view…"
                color: Color.muted || "#6272a4"
                font.pixelSize: 12
                visible: !searchInput.text && !searchInput.activeFocus
              }
            }

            Text {
              text: "/"
              font.pixelSize: 11
              color: Color.muted || "#6272a4"
              visible: !searchInput.text
            }

            Rectangle {
              width: Style.space(16)
              height: Style.space(16)
              radius: 8
              color: Qt.rgba(1, 1, 1, 0.1)
              visible: searchInput.text.length > 0

              Text {
                anchors.centerIn: parent
                text: "×"
                color: Color.foreground || "#f8f8f2"
                font.pixelSize: 12
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  searchInput.text = "";
                  root.searchQuery = "";
                }
              }
            }
          }
        }

        // --- ERROR BANNER ---
        Rectangle {
          Layout.fillWidth: true
          height: Style.space(32)
          color: Qt.rgba(1, 0, 0, 0.2)
          radius: 6
          border.color: Color.urgent || "#ff5555"
          border.width: 1
          visible: root.errorMessage.length > 0

          RowLayout {
            anchors.fill: parent
            anchors.margins: Style.space(6)
            spacing: Style.space(8)
            Text {
              text: "󰅚"
              font.family: "Symbols Nerd Font Mono"
              color: Color.urgent || "#ff5555"
            }
            Text {
              Layout.fillWidth: true
              text: root.errorMessage
              color: Color.urgent || "#ff5555"
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
              color: alertCardMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.05)
              radius: 8
              border.color: modelData.state === "FAILURE" ? (Color.urgent || "#ff5555") : (modelData.state === "PENDING" ? "#f1fa8c" : Qt.rgba(1, 1, 1, 0.15))
              border.width: 1

              RowLayout {
                anchors.fill: parent
                anchors.margins: Style.space(10)
                spacing: Style.space(10)

                Rectangle {
                  width: Style.space(30)
                  height: Style.space(30)
                  radius: 6
                  color: modelData.state === "FAILURE" ? Qt.rgba(1, 0.2, 0.2, 0.2) : Qt.rgba(1, 0.8, 0, 0.2)

                  Text {
                    anchors.centerIn: parent
                    text: modelData.state === "FAILURE" ? "󰅚" : "󰔟"
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: 15
                    color: modelData.state === "FAILURE" ? (Color.urgent || "#ff5555") : "#f1fa8c"
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
                      color: Color.foreground || "#f8f8f2"
                    }
                    Rectangle {
                      height: Style.space(16)
                      width: alertKindText.implicitWidth + Style.space(8)
                      radius: 4
                      color: modelData.kind === "default_branch" ? Qt.rgba(0.7, 0.4, 1, 0.2) : Qt.rgba(1, 1, 1, 0.1)
                      border.color: modelData.kind === "default_branch" ? (Color.accent || "#bd93f9") : Qt.rgba(1, 1, 1, 0.2)
                      border.width: 1

                      Text {
                        id: alertKindText
                        anchors.centerIn: parent
                        text: modelData.kind === "default_branch" ? "Default Branch" : "Pull Request"
                        font.pixelSize: 10
                        color: modelData.kind === "default_branch" ? (Color.accent || "#bd93f9") : (Color.muted || "#6272a4")
                      }
                    }
                  }

                  Text {
                    Layout.fillWidth: true
                    text: modelData.title + (modelData.commit ? " — " + modelData.commit : "")
                    font.pixelSize: 11
                    color: Color.muted || "#6272a4"
                    elide: Text.ElideRight
                  }
                }

                Text {
                  text: "󰌹 View"
                  font.family: "Symbols Nerd Font Mono"
                  font.pixelSize: 12
                  color: Color.accent || "#bd93f9"
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
                  color: "#50fa7b"
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "All workflows & default branches are healthy!"
                  font.pixelSize: 14
                  font.weight: Font.DemiBold
                  color: Color.foreground || "#f8f8f2"
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "No failing CI runs detected in this account context."
                  font.pixelSize: 12
                  color: Color.muted || "#6272a4"
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
              color: runCardMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.05)
              radius: 8
              border.color: modelData.conclusion === "failure" ? (Color.urgent || "#ff5555") : (modelData.status === "in_progress" ? "#f1fa8c" : Qt.rgba(1, 1, 1, 0.15))
              border.width: 1

              RowLayout {
                anchors.fill: parent
                anchors.margins: Style.space(10)
                spacing: Style.space(10)

                Rectangle {
                  width: Style.space(30)
                  height: Style.space(30)
                  radius: 6
                  color: modelData.conclusion === "success" ? Qt.rgba(0.3, 0.9, 0.4, 0.2) : (modelData.conclusion === "failure" ? Qt.rgba(1, 0.2, 0.2, 0.2) : (modelData.status === "in_progress" ? Qt.rgba(1, 0.8, 0, 0.2) : Qt.rgba(1, 1, 1, 0.08)))

                  Text {
                    anchors.centerIn: parent
                    text: modelData.conclusion === "success" ? "󰄲" : (modelData.conclusion === "failure" ? "󰅚" : (modelData.status === "in_progress" ? "󰔟" : (modelData.conclusion === "cancelled" ? "󰜺" : "⚡")))
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: 15
                    color: modelData.conclusion === "success" ? "#50fa7b" : (modelData.conclusion === "failure" ? (Color.urgent || "#ff5555") : (modelData.status === "in_progress" ? "#f1fa8c" : (Color.muted || "#6272a4")))
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
                      color: Color.accent || "#bd93f9"
                    }
                    Text {
                      text: "• " + modelData.name
                      font.pixelSize: 12
                      font.weight: Font.Medium
                      color: Color.foreground || "#f8f8f2"
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                    }
                    Rectangle {
                      height: Style.space(16)
                      width: branchText.implicitWidth + Style.space(8)
                      radius: 4
                      color: Qt.rgba(1, 1, 1, 0.1)
                      border.color: Qt.rgba(1, 1, 1, 0.2)
                      border.width: 1

                      Text {
                        id: branchText
                        anchors.centerIn: parent
                        text: modelData.headBranch + (modelData.headSha ? " (" + modelData.headSha + ")" : "")
                        font.pixelSize: 10
                        color: Color.foreground || "#f8f8f2"
                      }
                    }
                  }

                  RowLayout {
                    spacing: Style.space(8)
                    Text {
                      text: (modelData.commitMessage || modelData.event) + (modelData.actor ? " by @" + modelData.actor : "")
                      font.pixelSize: 11
                      color: Color.muted || "#6272a4"
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                    }
                    Text {
                      text: modelData.status === "in_progress" ? "In Progress" : (modelData.conclusion === "success" ? "Passed" : (modelData.conclusion === "failure" ? "Failed" : modelData.conclusion))
                      font.pixelSize: 10
                      font.weight: Font.DemiBold
                      color: modelData.conclusion === "success" ? "#50fa7b" : (modelData.conclusion === "failure" ? (Color.urgent || "#ff5555") : (modelData.status === "in_progress" ? "#f1fa8c" : (Color.muted || "#6272a4")))
                    }
                  }
                }

                Text {
                  text: "󰌹"
                  font.family: "Symbols Nerd Font Mono"
                  font.pixelSize: 14
                  color: Color.accent || "#bd93f9"
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
                  color: Color.foreground || "#f8f8f2"
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "No workflow runs found in this organization context."
                  font.pixelSize: 12
                  color: Color.muted || "#6272a4"
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
              color: reviewCardMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.05)
              radius: 8
              border.color: Qt.rgba(1, 1, 1, 0.15)
              border.width: 1

              RowLayout {
                anchors.fill: parent
                anchors.margins: Style.space(10)
                spacing: Style.space(10)

                Rectangle {
                  width: Style.space(30)
                  height: Style.space(30)
                  radius: 6
                  color: Qt.rgba(1, 0.8, 0, 0.2)

                  Text {
                    anchors.centerIn: parent
                    text: ""
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: 15
                    color: "#f1fa8c"
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
                      color: Color.accent || "#bd93f9"
                    }
                    Text {
                      text: "by @" + modelData.author
                      font.pixelSize: 11
                      color: Color.muted || "#6272a4"
                    }
                  }

                  Text {
                    Layout.fillWidth: true
                    text: modelData.title
                    font.pixelSize: 13
                    color: Color.foreground || "#f8f8f2"
                    elide: Text.ElideRight
                  }
                }

                Text {
                  text: "󰌹 Review"
                  font.family: "Symbols Nerd Font Mono"
                  font.pixelSize: 12
                  color: Color.accent || "#bd93f9"
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
                  color: Color.muted || "#6272a4"
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "Inbox zero on review requests"
                  font.pixelSize: 14
                  font.weight: Font.DemiBold
                  color: Color.foreground || "#f8f8f2"
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "No pull requests currently request your review in this scope."
                  font.pixelSize: 12
                  color: Color.muted || "#6272a4"
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
              color: prCardMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.05)
              radius: 8
              border.color: modelData.ciState === "FAILURE" ? (Color.urgent || "#ff5555") : Qt.rgba(1, 1, 1, 0.15)
              border.width: 1

              RowLayout {
                anchors.fill: parent
                anchors.margins: Style.space(10)
                spacing: Style.space(10)

                Rectangle {
                  width: Style.space(30)
                  height: Style.space(30)
                  radius: 6
                  color: modelData.ciState === "SUCCESS" ? Qt.rgba(0.3, 0.9, 0.4, 0.2) : (modelData.ciState === "FAILURE" ? Qt.rgba(1, 0.2, 0.2, 0.2) : Qt.rgba(1, 1, 1, 0.08))

                  Text {
                    anchors.centerIn: parent
                    text: modelData.ciState === "SUCCESS" ? "󰄲" : (modelData.ciState === "FAILURE" ? "󰅚" : (modelData.ciState === "PENDING" ? "󰔟" : ""))
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: 15
                    color: modelData.ciState === "SUCCESS" ? "#50fa7b" : (modelData.ciState === "FAILURE" ? (Color.urgent || "#ff5555") : (modelData.ciState === "PENDING" ? "#f1fa8c" : (Color.accent || "#8be9fd")))
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
                      color: Color.accent || "#bd93f9"
                    }
                    Text {
                      text: "on " + modelData.headRef
                      font.pixelSize: 11
                      color: Color.muted || "#6272a4"
                    }
                    Rectangle {
                      height: Style.space(16)
                      width: reviewBadgeText.implicitWidth + Style.space(8)
                      radius: 4
                      color: modelData.reviewDecision === "APPROVED" ? Qt.rgba(0.3, 0.9, 0.4, 0.2) : (modelData.reviewDecision === "CHANGES_REQUESTED" ? Qt.rgba(1, 0.2, 0.2, 0.2) : Qt.rgba(1, 1, 1, 0.1))
                      border.color: modelData.reviewDecision === "APPROVED" ? "#50fa7b" : (modelData.reviewDecision === "CHANGES_REQUESTED" ? (Color.urgent || "#ff5555") : Qt.rgba(1, 1, 1, 0.2))
                      border.width: 1

                      Text {
                        id: reviewBadgeText
                        anchors.centerIn: parent
                        text: modelData.reviewDecision === "APPROVED" ? "Approved" : (modelData.reviewDecision === "CHANGES_REQUESTED" ? "Changes Requested" : "Review Pending")
                        font.pixelSize: 10
                        color: modelData.reviewDecision === "APPROVED" ? "#50fa7b" : (modelData.reviewDecision === "CHANGES_REQUESTED" ? (Color.urgent || "#ff5555") : (Color.muted || "#6272a4"))
                      }
                    }
                  }

                  Text {
                    Layout.fillWidth: true
                    text: modelData.title
                    font.pixelSize: 13
                    color: Color.foreground || "#f8f8f2"
                    elide: Text.ElideRight
                  }
                }

                Text {
                  text: "󰌹 Open"
                  font.family: "Symbols Nerd Font Mono"
                  font.pixelSize: 12
                  color: Color.accent || "#bd93f9"
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
                  color: Color.muted || "#6272a4"
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "No open pull requests"
                  font.pixelSize: 14
                  font.weight: Font.DemiBold
                  color: Color.foreground || "#f8f8f2"
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "You don't have any authored pull requests open in this context."
                  font.pixelSize: 12
                  color: Color.muted || "#6272a4"
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
              color: pinnedCardMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.05)
              radius: 8
              border.color: modelData.ciState === "FAILURE" ? (Color.urgent || "#ff5555") : Qt.rgba(1, 1, 1, 0.15)
              border.width: 1

              RowLayout {
                anchors.fill: parent
                anchors.margins: Style.space(10)
                spacing: Style.space(10)

                Rectangle {
                  width: Style.space(30)
                  height: Style.space(30)
                  radius: 6
                  color: modelData.ciState === "SUCCESS" ? Qt.rgba(0.3, 0.9, 0.4, 0.2) : (modelData.ciState === "FAILURE" ? Qt.rgba(1, 0.2, 0.2, 0.2) : Qt.rgba(1, 1, 1, 0.08))

                  Text {
                    anchors.centerIn: parent
                    text: modelData.ciState === "SUCCESS" ? "󰄲" : (modelData.ciState === "FAILURE" ? "󰅚" : (modelData.ciState === "PENDING" ? "󰔟" : "󰘬"))
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: 15
                    color: modelData.ciState === "SUCCESS" ? "#50fa7b" : (modelData.ciState === "FAILURE" ? (Color.urgent || "#ff5555") : (modelData.ciState === "PENDING" ? "#f1fa8c" : (Color.accent || "#bd93f9")))
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
                      color: Color.foreground || "#f8f8f2"
                    }
                    Text {
                      text: "branch: " + modelData.defaultBranch
                      font.pixelSize: 11
                      color: Color.muted || "#6272a4"
                    }
                  }

                  RowLayout {
                    spacing: Style.space(10)
                    Text {
                      text: " " + modelData.openPrs + " PRs"
                      font.family: "Symbols Nerd Font Mono"
                      font.pixelSize: 11
                      color: modelData.openPrs > 0 ? (Color.accent || "#8be9fd") : (Color.muted || "#6272a4")
                    }
                    Text {
                      text: " " + modelData.openIssues + " Issues"
                      font.family: "Symbols Nerd Font Mono"
                      font.pixelSize: 11
                      color: modelData.openIssues > 0 ? "#f1fa8c" : (Color.muted || "#6272a4")
                    }
                    Text {
                      text: "★ " + modelData.stargazerCount
                      font.pixelSize: 11
                      color: Color.muted || "#6272a4"
                    }
                  }
                }

                // Toggle Pin Button
                Rectangle {
                  width: Style.space(26)
                  height: Style.space(26)
                  radius: 6
                  color: pinBtnMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : Qt.rgba(1, 1, 1, 0.06)
                  border.color: Qt.rgba(1, 1, 1, 0.2)
                  border.width: 1

                  Text {
                    anchors.centerIn: parent
                    text: modelData.isPinned ? "󰤱" : "󰤲"
                    font.family: "Symbols Nerd Font Mono"
                    font.pixelSize: 13
                    color: modelData.isPinned ? (Color.accent || "#bd93f9") : (Color.muted || "#6272a4")
                  }

                  MouseArea {
                    id: pinBtnMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.togglePin(modelData.nameWithOwner)
                  }
                }

                Text {
                  text: "󰌹"
                  font.family: "Symbols Nerd Font Mono"
                  font.pixelSize: 14
                  color: Color.accent || "#bd93f9"
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
                  color: Color.muted || "#6272a4"
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "No repositories found"
                  font.pixelSize: 14
                  font.weight: Font.DemiBold
                  color: Color.foreground || "#f8f8f2"
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "Type in the search bar above to search or pin repositories."
                  font.pixelSize: 12
                  color: Color.muted || "#6272a4"
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
            color: Qt.rgba(0.14, 0.15, 0.2, 0.98)
            border.color: Color.accent || "#bd93f9"
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
                color: Color.muted || "#6272a4"
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
                  color: (root.selectedOrg.toLowerCase() === modelData.login.toLowerCase()) ? Qt.rgba(0.7, 0.4, 1, 0.25) : (orgItemMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : "transparent")

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
                      color: (root.selectedOrg.toLowerCase() === modelData.login.toLowerCase()) ? (Color.accent || "#bd93f9") : (Color.foreground || "#f8f8f2")
                      elide: Text.ElideRight
                    }

                    Text {
                      text: modelData.count ? String(modelData.count) : ""
                      font.pixelSize: 10
                      color: Color.muted || "#6272a4"
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
            color: Color.muted || "#6272a4"
          }

          Item { Layout.fillWidth: true }

          Text {
            text: "Rate limit: " + (root.rawData.rateLimit ? (root.rawData.rateLimit.remaining + "/" + root.rawData.rateLimit.limit) : "5000")
            font.pixelSize: 10
            color: Color.muted || "#6272a4"
          }
        }
      }
    }
  }
}
