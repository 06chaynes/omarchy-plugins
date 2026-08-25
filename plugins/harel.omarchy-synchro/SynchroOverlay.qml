import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property int page: 0
  property string cli: localPath(Qt.resolvedUrl("cli.sh"))
  property string action: ""
  property string message: "Ready"
  property bool actionFailed: false
  property string detail: ""
  property string repository: "Not selected"
  property string repoDraft: ""
  property string branch: "—"
  property string origin: ""
  property string originDraft: ""
  property string remoteState: "unconfigured"
  property string repoState: "uninitialized"
  property int dirty: 0
  property int pendingChangesCount: 0
  property var categories: ({})
  property int ahead: 0
  property int behind: 0
  property bool includeDevice: false
  property bool easterEggOpen: false
  property string commitMessage: "Update Omarchy configuration"
  property string confirmAction: ""

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color border: Color.menu.border
  readonly property color accent: Color.menu.selectedText
  readonly property color muted: Qt.darker(foreground, 1.55)
  readonly property color urgent: Color.urgent
  readonly property color success: "#4ade80"
  readonly property color warning: "#facc15"
  readonly property string fontFamily: Style.font.menuFamily

  readonly property var pages: [
    { title: "Dashboard", icon: "󰓦", subtitle: "1-Click sync & status" },
    { title: "Restore & History", icon: "󰁯", subtitle: "Rollback & new laptop setup" },
    { title: "Settings", icon: "󰒓", subtitle: "Repository & allowlist policy" }
  ]

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    return decodeURIComponent(value)
  }

  function open(payloadJson) {
    opened = true
    page = 0
    message = "Checking system changes…"
    checkSnapshot()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { opened = false }

  function toggle(payloadJson) {
    if (opened) dismiss()
    else open(payloadJson)
  }

  function dismiss() {
    opened = false
    if (shell && typeof shell.hide === "function")
      shell.hide((manifest && manifest.id) || "harel.omarchy-synchro")
  }

  function run(nextAction, args) {
    if (process.running) return
    action = nextAction
    actionFailed = false
    message = "Working…"
    process.capturedStdout = ""
    process.capturedStderr = ""
    process.outputBytes = 0
    process.outputTruncated = false
    process.command = [cli, "--qml"].concat(args)
    process.running = true
  }

  function refresh() { run("status", ["--json", "status"]) }
  function fetchRemoteStatus() { run("status-fetch", ["--json", "status", "--fetch"]) }
  function checkSnapshot() { run("snapshot-check", ["--json", "snapshot"]) }
  function triggerSync() {
    var msg = commitMessage.trim() || ("Omarchy configuration sync " + Qt.formatDateTime(new Date(), "yyyy-MM-dd hh:mm"))
    run("sync", ["--json", "sync", "--message", msg])
  }

  function parse(raw) {
    try { return JSON.parse(String(raw || "{}")) }
    catch (error) { return null }
  }

  function applyStatus(data) {
    if (!data) return
    repository = String(data.repository || "Not selected")
    repoDraft = repository === "Not selected" ? "" : repository
    branch = String(data.branch || "—")
    origin = String(data.origin || "")
    originDraft = origin
    remoteState = String(data.remoteState || "unconfigured")
    repoState = String(data.state || "uninitialized")
    dirty = Number(data.dirtyFileCount !== undefined ? data.dirtyFileCount : (data.dirtyFiles || []).length)
    ahead = Number(data.ahead || 0)
    behind = Number(data.behind || 0)
  }

  function formatPath(rawPath) {
    var p = String(rawPath || "")
    var action = "+"
    if (p.indexOf("/M ") >= 0) action = "~"
    else if (p.indexOf("/D ") >= 0) action = "-"
    else if (p.indexOf("/A ") >= 0) action = "+"

    var cleanPath = p.replace(/^(portable|device|manifests|metadata)\/[AMD]\s+/, "")
    cleanPath = cleanPath.replace(/^home\//, "~/")
    cleanPath = cleanPath.replace(/^[a-zA-Z0-9_-]+\/home\//, "~/")
    return "  " + action + " " + cleanPath
  }

  function friendlyOutput(data, raw) {
    if (!data) return raw || "No output"
    if (data.error) return "❌ ERROR:\n──────────────────────────────────────────────────────────\n" + String(data.error)

    if (data.synced) {
      if (data.alreadyUpToDate) {
        return [
          "✨ SYSTEM SYNCHRONIZED",
          "──────────────────────────────────────────────────────────",
          "• Status:           All configuration files are up to date.",
          "• Remote Origin:    " + (root.origin || "Configured"),
          "• Active Branch:    " + (root.branch || "main"),
          "• Working Tree:     Clean",
          "",
          "No changes detected between your system and GitHub."
        ].join("\n")
      }
      return [
        "✅ SYNCHRONIZATION COMPLETE",
        "──────────────────────────────────────────────────────────",
        "• Commit:           " + String(data.commit || "OK"),
        "• Message:          " + String(data.commitMessage || ""),
        "• Branch:           " + String(data.pushed || "main") + " → " + String(data.origin || root.origin || "origin"),
        "• Repository:       " + String(root.repository),
        "",
        "All configuration files successfully captured, committed, and pushed."
      ].join("\n")
    }

    if (data.stage) {
      var stageTitles = {
        "check": "🔍 BASE COMPATIBILITY CHECK",
        "packages": "📦 PACKAGE DEPENDENCIES",
        "plugins": "🧩 THIRD-PARTY PLUGINS",
        "mime": "📄 APPLICATION & MIME DEFAULTS",
        "reload": "🔄 SYSTEM COMPONENT RELOAD",
        "report": "📑 NEW LAPTOP SEED REPORT"
      }
      var sTitle = stageTitles[data.stage] || ("🌱 SEED STAGE: " + data.stage.toUpperCase())
      var out = [sTitle, "──────────────────────────────────────────────────────────"]
      if (data.summary) out.push("• Summary:          " + String(data.summary), "")

      if (data.lines && data.lines.length) {
        for (var l = 0; l < data.lines.length; l++) {
          var block = String(data.lines[l])
          var parts = block.split("\n")
          out.push("▶ " + parts[0])
          for (var p = 1; p < parts.length; p++) {
            out.push("    " + parts[p].trim())
          }
          out.push("")
        }
      }

      if (data.actions && data.actions.length) {
        out.push("INSTALLED PLUGINS (" + data.actions.length + "):")
        for (var a = 0; a < data.actions.length; a++) {
          var pl = data.actions[a]
          var sec = (pl.placement && pl.placement.section) ? (" [Bar: " + pl.placement.section + "]") : ""
          out.push("  • " + String(pl.id) + sec + " (" + String(pl.state || "active") + ")")
        }
        if (data.manual && data.manual.length) {
          out.push("", "⚠️ MANUAL INSTALLATION NEEDED:")
          for (var m = 0; m < data.manual.length; m++) out.push("  - " + data.manual[m])
        }
      }
      return out.join("\n").trim()
    }

    if (data.selected) {
      return [
        "📁 CONFIGURATION REPOSITORY SELECTED",
        "──────────────────────────────────────────────────────────",
        "• Path:             " + String(data.selected),
        "• Settings:         " + String(data.settings || "~/.config/omarchy/omarchy-synchro.json"),
        "",
        "Repository path updated and active."
      ].join("\n")
    }

    if (data.initialized) {
      return [
        "✨ REPOSITORY INITIALIZED",
        "──────────────────────────────────────────────────────────",
        "• Path:             " + String(data.initialized),
        "• Policy Allowlist: Created from template",
        "",
        "Repository scaffold ready for snapshots and sync."
      ].join("\n")
    }

    if (data.origin !== undefined) {
      return [
        "🌐 GITHUB REMOTE CONFIGURATION",
        "──────────────────────────────────────────────────────────",
        "• Remote URL:       " + (data.origin || "No remote configured"),
        "• Remote Name:      origin",
        "",
        data.origin ? "Remote origin saved and tracked." : "Origin removed."
      ].join("\n")
    }

    if (data.summary && data.repositoryStatus) {
      var slines = []
      var totalChanges = (data.changes || []).length
      
      if (totalChanges === 0) {
        slines.push("✨ LOCAL SNAPSHOT UP TO DATE")
        slines.push("──────────────────────────────────────────────────────────")
        slines.push("• Managed Files:    " + (data.summary.files || 0) + " tracked files (" + ((data.summary.bytes || 0) / (1024 * 1024)).toFixed(2) + " MB)")
        slines.push("• Device ID:        " + (data.summary.deviceId || "unknown-device"))
        slines.push("• Repository:       " + (data.repositoryStatus.repository || root.repository))
        slines.push("• Branch:           " + (data.repositoryStatus.branch || "main"))
        slines.push("• Working Tree:     " + (data.repositoryStatus.state === "clean" ? "Clean" : "Modified"))
        slines.push("")
        slines.push("No uncommitted changes pending in your active configuration.")
        return slines.join("\n")
      }

      slines.push("📋 SNAPSHOT PREVIEW (" + totalChanges + " files ready to sync)")
      slines.push("──────────────────────────────────────────────────────────")

      var cats = data.categoryDetails || {}
      var catHeaders = [
        { key: "themes", title: "🎨 Themes & Wallpapers" },
        { key: "screensavers", title: "📺 Custom Screensavers" },
        { key: "terminals", title: "💻 Terminal Emulators" },
        { key: "wm", title: "🪟 Window Manager & Keybindings" },
        { key: "scripts", title: "📜 Custom Scripts & Binaries (~/.local/bin)" },
        { key: "manifests", title: "📦 System Package Manifests" },
        { key: "device", title: "🖥️ Hardware & Displays (Device Specific)" },
        { key: "other", title: "📁 Other Configurations" }
      ]

      for (var c = 0; c < catHeaders.length; c++) {
        var group = catHeaders[c]
        var items = cats[group.key] || []
        if (items.length > 0) {
          slines.push("")
          slines.push(group.title + " (" + items.length + "):")
          for (var i = 0; i < items.length; i++) {
            slines.push(formatPath(items[i]))
          }
        }
      }

      return slines.join("\n")
    }

    if (data.mode === "applied" && data.backup) {
      return [
        "📦 RESTORE APPLIED SUCCESSFULLY",
        "──────────────────────────────────────────────────────────",
        "• Safety Backup:    " + String(data.backup),
        "• Files Restored:   " + ((data.changes || []).length) + " files",
        "",
        "Configuration has been safely updated on this machine."
      ].join("\n")
    }

    if (data.changes && data.mode) {
      if (data.changes.length === 0) return "✨ No differences found between repository and system."
      var rlines = [
        "📋 RESTORE PREVIEW (" + data.changes.length + " files would change)",
        "──────────────────────────────────────────────────────────"
      ]
      for (var r = 0; r < data.changes.length; r++) {
        var item = data.changes[r]
        if (typeof item === "string") {
          rlines.push(formatPath(item))
        } else {
          var scopeTag = (item.scope === "device") ? " [Hardware]" : ""
          rlines.push("  • ~/" + String(item.destination || "").replace(/^home\//, "") + scopeTag)
        }
      }
      return rlines.join("\n")
    }

    if (data.lines && data.lines.length) {
      return data.lines.join("\n\n")
    }

    return String(raw || "Action completed.")
  }

  function requestConfirmation(kind) {
    confirmAction = kind
    if (kind === "sync") {
      confirmDialog.message = "Capture all local changes, commit them to your repository, and push to GitHub?"
      confirmDialog.confirmText = "Sync to GitHub"
    } else if (kind === "restore") {
      confirmDialog.message = "Apply the previewed configuration to this laptop? Existing files will be backed up first."
      confirmDialog.confirmText = "Apply restore"
    } else if (kind === "origin") {
      confirmDialog.message = "Remove origin from the configuration repository? Files and commits will not be changed."
      confirmDialog.confirmText = "Remove origin"
    }
    confirmDialog.opened = true
  }

  function runConfirmed() {
    confirmDialog.opened = false
    if (confirmAction === "sync") triggerSync()
    else if (confirmAction === "restore") {
      var restoreArgs = ["--json", "restore", "--apply"]
      if (includeDevice) restoreArgs.push("--include-device")
      run("restore-apply", restoreArgs)
    } else if (confirmAction === "origin") {
      run("origin-remove", ["--json", "repo", "origin", "remove"])
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "harel-omarchy-synchro"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      visible: root.opened
      color: Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      enabled: root.opened
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      visible: root.opened
      width: Math.min(Style.space(980), panel.width - Style.space(48))
      height: Math.min(Style.space(660), panel.height - Style.space(48))
      anchors.centerIn: parent
      color: root.background
      borderSpec: Border.surfaceSpec("menu", "border", root.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      padding: 0

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: {
          if (root.easterEggOpen) root.easterEggOpen = false
          else root.dismiss()
        }

        RowLayout {
          anchors.fill: parent
          spacing: 0

          // Sidebar Navigation
          Rectangle {
            Layout.preferredWidth: Style.space(230)
            Layout.fillHeight: true
            color: Util.alpha(root.foreground, 0.035)

            Column {
              anchors.fill: parent
              anchors.margins: Style.space(18)
              spacing: Style.space(8)

              Row {
                height: Style.space(58)
                spacing: Style.space(12)
                Text { text: "󰓦"; color: root.accent; font.family: root.fontFamily; font.pixelSize: Style.font.display }
                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  Text {
                    id: pluginName
                    text: "Omarchy Synchro"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                  }
                  Text { text: "Git Config Sync"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                }
              }

              Item { width: 1; height: Style.space(8) }

              Repeater {
                model: root.pages
                Rectangle {
                  required property int index
                  required property var modelData
                  width: parent.width
                  height: Style.space(54)
                  radius: Style.cornerRadius
                  color: root.page === index ? Util.alpha(root.accent, 0.13) : (navMouse.containsMouse ? Util.alpha(root.foreground, 0.06) : "transparent")
                  border.color: root.page === index ? Util.alpha(root.accent, 0.5) : "transparent"
                  border.width: root.page === index ? 1 : 0

                  Row {
                    anchors.fill: parent
                    anchors.margins: Style.space(12)
                    spacing: Style.space(12)
                    Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.icon; color: root.page === index ? root.accent : root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.icon }
                    Column {
                      anchors.verticalCenter: parent.verticalCenter
                      Text { text: modelData.title; color: root.page === index ? root.accent : root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
                      Text { text: modelData.subtitle; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                    }
                  }
                  MouseArea {
                    id: navMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.page = index
                      root.message = "Ready"
                      if (index === 0) root.checkSnapshot()
                      else if (index === 1) root.run("restore-preview", ["--json", "restore"])
                    }
                  }
                }
              }

              Item { width: 1; height: Style.space(12) }
              Rectangle { width: parent.width; height: 1; color: Util.alpha(root.border, 0.6) }
              
              // Repository & Machine Info
              Text { width: parent.width; text: root.repository; textFormat: Text.PlainText; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideMiddle }
              
              Row {
                spacing: Style.space(6)
                Rectangle {
                  width: 8; height: 8; radius: 4
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.dirty > 0 || root.pendingChangesCount > 0 ? root.warning : (root.repoState === "clean" ? root.success : root.urgent)
                }
                Text {
                  text: root.dirty > 0 || root.pendingChangesCount > 0 ? "Changes to sync" : (root.repoState === "clean" ? "Up to date" : "Setup needed")
                  color: root.dirty > 0 || root.pendingChangesCount > 0 ? root.warning : (root.repoState === "clean" ? root.success : root.urgent)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: root.border }

          // Main View Content
          Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ColumnLayout {
              anchors.fill: parent
              anchors.margins: Style.space(24)
              spacing: Style.space(16)

              // Header
              RowLayout {
                Layout.fillWidth: true
                Column {
                  Layout.fillWidth: true
                  Text { text: root.pages[root.page].title; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.heading }
                  Text { text: root.pages[root.page].subtitle; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                }
                Button { text: "󰑐  Refresh"; bordered: true; enabled: !process.running; onClicked: root.refresh() }
                Button { text: "󰑐  Fetch Remote"; bordered: true; enabled: !process.running && root.origin !== ""; onClicked: root.fetchRemoteStatus() }
                Button { text: "Close"; bordered: true; onClicked: root.dismiss() }
              }

              Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.border }

              // Body Views
              Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                // ==========================================
                // PAGE 0: DASHBOARD (1-CLICK SYNC FLOW)
                // ==========================================
                Column {
                  visible: root.page === 0
                  anchors.fill: parent
                  spacing: Style.space(14)

                  // Primary Sync Hero Card
                  BorderSurface {
                    width: parent.width
                    height: Style.space(136)
                    color: Util.alpha(root.foreground, 0.03)
                    borderSpec: Border.flat(Util.alpha(root.accent, 0.4), 1)
                    radius: Style.cornerRadius
                    padding: Style.space(16)

                    Column {
                      anchors.fill: parent
                      anchors.margins: Style.space(14)
                      spacing: Style.space(10)

                      RowLayout {
                        width: parent.width
                        Row {
                          spacing: Style.space(8)
                          Text { text: root.dirty > 0 || root.pendingChangesCount > 0 ? "󰓦" : "󰄬"; color: root.dirty > 0 || root.pendingChangesCount > 0 ? root.warning : root.success; font.family: root.fontFamily; font.pixelSize: Style.font.title }
                          Text {
                            text: root.dirty > 0 || root.pendingChangesCount > 0 ? (root.pendingChangesCount + root.dirty) + " Changes Ready to Sync" : "Configuration is Up to Date"
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.title
                          }
                        }
                        Item { Layout.fillWidth: true }
                        Text { text: root.origin || "No origin configured"; textFormat: Text.PlainText; color: root.muted; font.family: "monospace"; font.pixelSize: Style.font.caption; elide: Text.ElideMiddle }
                      }

                      RowLayout {
                        width: parent.width
                        spacing: Style.space(10)

                        Button {
                          text: process.running && root.action === "sync" ? "󰑓  Syncing to GitHub…" : "󰆓  Sync to GitHub Now"
                          bordered: true
                          foreground: root.accent
                          accent: root.accent
                          enabled: !process.running && root.repoState !== "uninitialized"
                          onClicked: root.triggerSync()
                        }

                        Button {
                          text: "👁️  Review Changes"
                          bordered: true
                          enabled: !process.running
                          onClicked: root.checkSnapshot()
                        }

                        Button {
                          text: "📁  Open Repo"
                          bordered: true
                          enabled: !process.running && root.repoState !== "uninitialized"
                          onClicked: root.run("repo-open", ["repo", "open"])
                        }
                      }
                    }
                  }

                  // Category Breakdown Summary
                  Row {
                    width: parent.width
                    spacing: Style.space(8)

                    Repeater {
                      model: [
                        { label: "Themes & Wallpapers", icon: "🎨", count: root.categories.themes || 0 },
                        { label: "Screensavers", icon: "📺", count: root.categories.screensavers || 0 },
                        { label: "Terminals & WM", icon: "💻", count: (root.categories.terminals || 0) + (root.categories.wm || 0) },
                        { label: "Tools & Scripts", icon: "📜", count: root.categories.scripts || 0 },
                        { label: "Hardware Layout", icon: "🖥️", count: root.categories.device || 0 }
                      ]

                      BorderSurface {
                        required property var modelData
                        width: (parent.width - Style.space(32)) / 5
                        height: Style.space(64)
                        color: Util.alpha(root.foreground, 0.025)
                        borderSpec: Border.flat(Util.alpha(root.border, 0.5), 1)
                        radius: Style.cornerRadius
                        padding: Style.space(8)

                        Column {
                          anchors.centerIn: parent
                          spacing: Style.space(2)
                          Row {
                            spacing: Style.space(4)
                            anchors.horizontalCenter: parent.horizontalCenter
                            Text { text: modelData.icon; font.pixelSize: Style.font.body }
                            Text { text: String(modelData.count); color: modelData.count > 0 ? root.accent : root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
                          }
                          Text { text: modelData.label; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
                        }
                      }
                    }
                  }

                  // Live Output & Detail Log
                  OutputPanel {
                    width: parent.width
                    height: parent.height - Style.space(235)
                    title: "Live Synchronization Log"
                    content: root.detail
                    foreground: root.foreground
                    muted: root.muted
                    borderColor: root.border
                    fontFamily: root.fontFamily
                  }
                }

                // ==========================================
                // PAGE 1: RESTORE & HISTORY (ROLLBACKS & SEED)
                // ==========================================
                Column {
                  visible: root.page === 1
                  anchors.fill: parent
                  spacing: Style.space(12)

                  Text { width: parent.width; text: "Compare and restore configurations from your Git repository. Existing files are safely backed up before any restore."; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }

                  Row {
                    spacing: Style.space(8)
                    Button { text: root.includeDevice ? "󰍹  Include Hardware/Monitors" : "󰌢  Portable Files Only (Safe)"; bordered: true; onClicked: root.includeDevice = !root.includeDevice }
                    Button { text: "Preview Restore"; bordered: true; enabled: !process.running; onClicked: { var args=["--json","restore"]; if(root.includeDevice)args.push("--include-device"); root.run("restore-preview",args) } }
                    Button { text: "Apply Restore"; bordered: true; foreground: root.urgent; accent: root.urgent; enabled: !process.running; onClicked: root.requestConfirmation("restore") }
                  }

                  Rectangle { width: parent.width; height: 1; color: root.border }

                  Text { text: "New Laptop Setup Diagnostics (Seed):"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title }
                  Row {
                    spacing: Style.space(6)
                    Repeater {
                      model: ["check", "packages", "plugins", "mime", "reload", "report"]
                      Button { required property string modelData; text: modelData.toUpperCase(); bordered: true; enabled: !process.running; onClicked: root.run("seed", ["--json", "seed", "--stage", modelData]) }
                    }
                  }

                  OutputPanel {
                    width: parent.width
                    height: parent.height - Style.space(170)
                    title: "Restore & Diagnostics Preview"
                    content: root.detail
                    foreground: root.foreground
                    muted: root.muted
                    borderColor: root.border
                    fontFamily: root.fontFamily
                  }
                }

                // ==========================================
                // PAGE 2: SETTINGS & POLICY
                // ==========================================
                Column {
                  visible: root.page === 2
                  anchors.fill: parent
                  spacing: Style.space(14)

                  Text { text: "Configuration Repository Path"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title }
                  RowLayout {
                    width: parent.width; spacing: Style.space(8)
                    TextField { Layout.fillWidth: true; text: root.repoDraft; placeholderText: "~/omarchy-config"; onTextChanged: root.repoDraft = text }
                    Button { text: "Select"; bordered: true; enabled: root.repoDraft.trim() !== "" && !process.running; onClicked: root.run("config-select", ["--json", "config", "select", root.repoDraft.trim()]) }
                    Button { text: "Initialize"; bordered: true; enabled: !process.running; onClicked: root.run("repo-init", ["--json", "repo", "init"]) }
                  }

                  Rectangle { width: parent.width; height: 1; color: root.border }

                  Text { text: "GitHub Remote URL"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title }
                  TextField { width: parent.width; text: root.originDraft; placeholderText: "https://github.com/you/omarchy-config.git"; onTextChanged: root.originDraft = text }
                  Row {
                    spacing: Style.space(8)
                    Button { text: root.origin === "" ? "Set Remote" : "Update Remote"; bordered: true; enabled: root.originDraft.trim() !== "" && !process.running; onClicked: root.run("origin-set", ["--json", "repo", "origin", "set", root.originDraft.trim()]) }
                    Button { text: "Test Connection"; bordered: true; enabled: root.originDraft.trim() !== "" && !process.running; onClicked: root.run("origin-test", ["--json", "repo", "origin", "test", root.originDraft.trim()]) }
                    Button { text: "Remove Remote"; bordered: true; foreground: root.urgent; accent: root.urgent; enabled: root.origin !== "" && !process.running; onClicked: root.requestConfirmation("origin") }
                  }

                  Rectangle { width: parent.width; height: 1; color: root.border }
                  Text { text: "Allowlist Policy (policy/allowlist.tsv)"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title }
                  Text { width: parent.width; text: "Defines which files are included in the portable and device snapshots. Secrets, tokens, and browser caches are automatically excluded."; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                }
              }

              // Status Bar at Bottom
              BorderSurface {
                Layout.fillWidth: true
                Layout.preferredHeight: Style.space(38)
                color: root.actionFailed ? Util.alpha(root.urgent, 0.1) : Util.alpha(root.foreground, 0.025)
                borderSpec: Border.flat(root.actionFailed ? Util.alpha(root.urgent, 0.55) : Util.alpha(root.border, 0.6), 1)
                radius: Style.cornerRadius
                padding: Style.space(9)
                Row {
                  anchors.fill: parent
                  anchors.margins: Style.space(9)
                  spacing: Style.space(8)
                  Text { text: process.running ? "󰑓" : (root.actionFailed ? "󰅙" : "󰄬"); color: root.actionFailed ? root.urgent : root.accent; font.family: root.fontFamily; font.pixelSize: Style.font.body }
                  Text { width: parent.width - Style.space(32); text: root.message; textFormat: Text.PlainText; color: root.actionFailed ? root.urgent : root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
                }
              }
            }

            ConfirmDialog {
              id: confirmDialog
              anchors.fill: parent
              background: root.background
              foreground: root.foreground
              selectedText: root.accent
              fontFamily: root.fontFamily
              onCanceled: confirmDialog.opened = false
              onConfirmed: root.runConfirmed()
            }
          }
        }
      }
    }
  }

  Process {
    id: process
    property string capturedStdout: ""
    property string capturedStderr: ""
    property int outputBytes: 0
    property bool outputTruncated: false

    stdout: SplitParser {
      onRead: function(line) {
        if (process.outputTruncated) return
        process.outputBytes += line.length + 1
        if (process.outputBytes > 65536) {
          process.outputTruncated = true
          process.capturedStdout += "\n[Output truncated to safe UI limit]"
          return
        }
        process.capturedStdout += (process.capturedStdout === "" ? "" : "\n") + line
      }
    }

    stderr: SplitParser {
      onRead: function(line) {
        if (process.outputTruncated) return
        process.outputBytes += line.length + 1
        if (process.outputBytes > 65536) {
          process.outputTruncated = true
          process.capturedStderr += "\n[Stderr truncated to safe UI limit]"
          return
        }
        process.capturedStderr += (process.capturedStderr === "" ? "" : "\n") + line
      }
    }

    onExited: function(exitCode) {
      var raw = process.capturedStdout.trim()
      var parsed = root.parse(raw)
      root.actionFailed = exitCode !== 0 || (parsed && parsed.error !== undefined)

      if (parsed) {
        if (parsed.repositoryStatus) root.applyStatus(parsed.repositoryStatus)
        else root.applyStatus(parsed)
        if (parsed.changes !== undefined) root.pendingChangesCount = parsed.changes.length
        if (parsed.categories !== undefined) root.categories = parsed.categories
        if (parsed.synced) {
          root.pendingChangesCount = 0
          root.categories = ({})
          root.dirty = 0
        }
      }

      root.detail = root.friendlyOutput(parsed, raw || process.capturedStderr.trim())

      if (root.actionFailed) {
        root.message = (parsed && parsed.error) ? String(parsed.error) : (process.capturedStderr.trim() || "Action failed")
      } else {
        if (root.action === "sync") root.message = "Configuration synced to GitHub successfully"
        else if (root.action === "status" || root.action === "status-fetch") root.message = "Status refreshed"
        else if (root.action === "snapshot-check") root.message = "Snapshot check complete"
        else root.message = "Ready"
      }
    }
  }

  component OutputPanel: BorderSurface {
    id: outputPanel
    property string title: "Output"
    property string content: "Run a preview to see changes here."
    property color foreground: Color.foreground
    property color muted: Qt.darker(foreground, 1.5)
    property color borderColor: Color.menu.border
    property string fontFamily: Style.font.family
    color: Util.alpha(Color.menu.background, 0.8)
    borderSpec: Border.flat(Util.alpha(borderColor, 0.65), 1)
    radius: Style.cornerRadius
    padding: Style.space(14)
    Column {
      anchors.fill: parent
      anchors.margins: Style.space(14)
      spacing: Style.space(10)
      Row {
        spacing: Style.space(8)
        Text { text: "󰅩"; color: root.accent; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
        Text { text: outputPanel.title.toUpperCase(); textFormat: Text.PlainText; color: outputPanel.muted; font.family: outputPanel.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
      }
      Flickable {
        width: parent.width; height: parent.height - Style.space(32)
        contentWidth: width; contentHeight: outputText.implicitHeight
        clip: true; boundsBehavior: Flickable.StopAtBounds
        Text {
          id: outputText
          width: parent.width
          text: outputPanel.content || "Run a preview to see changes here."; textFormat: Text.PlainText
          color: outputPanel.foreground
          font.family: "monospace"
          font.pixelSize: Math.max(11, Style.font.bodySmall)
          lineHeight: 1.25
          wrapMode: Text.WrapAnywhere
        }
      }
    }
  }
}
