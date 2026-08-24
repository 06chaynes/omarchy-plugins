import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "bottelet.is-it-down"
  ipcTarget: "bottelet.is-it-down"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so everything the bar identifies a panel by must be that
  // widget (popout coordinator, switchPanelFrom).
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string fontName: bar ? bar.fontFamily : Style.font.family

  // Status colors. Red follows the theme's urgent color; green/yellow have no
  // theme role, so they ship with defaults that can be overridden per widget
  // via `omarchy bar set bottelet.is-it-down okColor "#a6e3a1"` etc.
  readonly property color okColor: settings && settings.okColor ? settings.okColor : "#98c379"
  readonly property color warnColor: settings && settings.warnColor ? settings.warnColor : "#e5c07b"
  readonly property color downColor: settings && settings.downColor ? settings.downColor : Color.urgent

  readonly property var customServices: setting("customServices", [])
  readonly property var services: Model.enabledServices(setting("services", null), customServices)
  readonly property var enabledKeys: services.map(function(s) { return s.key })

  // Region codes discovered live from AWS's public ip-ranges feed, so new
  // regions show up in settings without a plugin update.
  property var awsLiveRegionCodes: []
  property var results: ({})
  property bool settingsMode: false

  // "" shows the service list page; a service key shows that service's
  // regions/components drill-down page.
  property string settingsServiceKey: ""
  readonly property var settingsService: settingsServiceKey ? Model.serviceByKey(settingsServiceKey, customServices) : null
  property string settingsFilter: ""
  readonly property var settingsRows: settingsService
    ? Model.filterCatalog(
        Model.settingsCatalog(settingsService, results[settingsServiceKey] || null, ignoreFor(settingsServiceKey), awsLiveRegionCodes),
        settingsFilter, 60)
    : ({ rows: [], hidden: 0 })

  function openServicePage(key) {
    settingsFilter = ""
    if (catalogFilterField) catalogFilterField.text = ""
    settingsServiceKey = key
  }

  function closeServicePage() {
    settingsFilter = ""
    settingsServiceKey = ""
  }

  // Toggle every row matching the current filter. Disabling stores one key
  // per row (the canonical one); enabling clears every alias.
  function setAllRows(enabled) {
    var rows = settingsRows.all || []
    var keys = []
    for (var i = 0; i < rows.length; i++) {
      if (enabled) keys = keys.concat(rows[i].muteKeys)
      else keys.push(rows[i].muteKeys[0])
    }
    setIgnoreState(settingsServiceKey, keys, !enabled)
  }
  property int currentIndex: 0
  readonly property var currentService: services.length > 0 ? services[Math.min(currentIndex, services.length - 1)] : null
  readonly property var currentResult: currentService ? (results[currentService.key] || null) : null
  property string lastChecked: ""

  readonly property int issueCount: Model.issueCount(services, results)
  readonly property int worstSeverity: Model.worstSeverity(services, results)
  readonly property color worstColor: colorForSeverity(worstSeverity)

  // Refresh cadence in minutes; override via
  // `omarchy bar set bottelet.is-it-down refreshMinutes 10`.
  readonly property int refreshMinutes: Math.max(1, parseInt(setting("refreshMinutes", 3), 10) || 3)

  signal refreshRequested()

  function colorForSeverity(severity) {
    if (severity === Model.SEV_OK) return okColor
    if (severity === Model.SEV_MINOR) return warnColor
    if (severity === Model.SEV_MAJOR) return downColor
    return Color.muted
  }

  function severityFor(key) {
    var r = results[key]
    return r ? r.severity : Model.SEV_UNKNOWN
  }

  function refreshAll() {
    refreshRequested()
  }

  // Settings changes (service list, ignore rules, colors) are patched into
  // running widgets live by the bar; re-fetch so filters apply immediately
  // instead of waiting out the poll interval.
  onSettingsChanged: refreshAll()

  // Applied locally first so the panel redraws on the click itself; the
  // shell.json write comes back through the bar as the same value (same
  // pattern as the built-in clock panel).
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function toggleService(key) {
    var keys = enabledKeys.slice()
    var at = keys.indexOf(key)
    if (at === -1) keys.push(key)
    else keys.splice(at, 1)
    persistSettings({ services: keys })
  }

  function ignoreFor(key) {
    return Model.ignoreListFor(root.settings, key)
  }

  // Add or remove entries from a service's ignore list. The legacy
  // awsIgnoreRegions key is folded into the table on any AWS write so it can
  // never silently re-add a region.
  function setIgnoreState(serviceKey, muteKeys, ignored) {
    var table = {}
    var current = settings && settings.ignore ? settings.ignore : {}
    for (var k in current) table[k] = Model.normalizeList(current[k])
    var list = table[serviceKey] || []
    if (serviceKey === "aws" && settings && settings.awsIgnoreRegions !== undefined) {
      var legacy = Model.normalizeList(settings.awsIgnoreRegions)
      for (var l = 0; l < legacy.length; l++) {
        if (list.indexOf(legacy[l]) === -1) list.push(legacy[l])
      }
    }
    for (var i = 0; i < muteKeys.length; i++) {
      var entry = String(muteKeys[i] || "").toLowerCase()
      if (entry === "") continue
      var at = list.indexOf(entry)
      if (ignored && at === -1) list.push(entry)
      if (!ignored && at !== -1) list.splice(at, 1)
    }
    table[serviceKey] = list
    if (serviceKey === "aws" && settings && settings.awsIgnoreRegions !== undefined)
      persistSettings({ ignore: table, awsIgnoreRegions: "" })
    else
      persistSettings({ ignore: table })
  }

  function muteItem(serviceKey, muteKey) {
    setIgnoreState(serviceKey, [muteKey], true)
  }

  function applyResult(service, raw) {
    var parsed = Model.parseResult(service, raw, { ignore: ignoreFor(service.key) })
    var next = {}
    for (var k in results) next[k] = results[k]
    next[service.key] = parsed
    results = next
    lastChecked = Qt.formatTime(new Date(), "HH:mm")
    if (opened && !userPickedTab) focusFirstIssue()
  }

  // Quote the URL and require an http(s) scheme: service.page comes from user
  // config (customServices), so a raw single quote would otherwise break out
  // of the shell line, and a non-http scheme could hand xdg-open a file:// or
  // other handler target.
  function shArg(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function openPage(service) {
    if (service && service.page && root.bar && /^https?:\/\//i.test(String(service.page)))
      root.bar.run("xdg-open " + shArg(service.page))
  }

  // While the panel is open and the user hasn't picked a tab themselves,
  // results arriving may refocus onto a troubled service.
  property bool userPickedTab: false

  // Jump to the first troubled service when the current tab is all green —
  // opening the panel should show the culprit, not whatever was selected.
  function focusFirstIssue() {
    if (currentService && severityFor(currentService.key) >= Model.SEV_MINOR) return
    for (var i = 0; i < services.length; i++) {
      var r = results[services[i].key]
      if (r && r.severity >= Model.SEV_MINOR) {
        currentIndex = i
        return
      }
    }
  }

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    userPickedTab = false
    root.focusFirstIssue()
    root.refreshAll()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    userPickedTab = false
    root.focusFirstIssue()
    root.refreshAll()
    // Deferred for the same popout-handoff reason as the weather panel.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    settingsMode = false
    closeServicePage()
    root.controller.hide()
  }

  function openSettings() {
    openFromHotkey()
    settingsMode = true
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // One fetcher per enabled service; all run in parallel. Created fetchers
  // fire immediately (first load and whenever the service selection changes),
  // then re-fire on every refreshRequested.
  Instantiator {
    model: root.services

    delegate: QtObject {
      id: fetcher
      required property var modelData

      readonly property Process proc: Process {
        command: Model.fetchCommand(fetcher.modelData)
        stdout: StdioCollector {
          waitForEnd: true
          onStreamFinished: root.applyResult(fetcher.modelData, text)
        }
      }

      readonly property Connections conn: Connections {
        target: root
        function onRefreshRequested() {
          if (!fetcher.proc.running) fetcher.proc.running = true
        }
      }

      Component.onCompleted: proc.running = true
    }
  }

  Timer {
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.refreshAll()
  }

  // One-shot region discovery (regions change rarely); retried by the timer
  // below until it succeeds, e.g. when the shell starts before the network.
  Process {
    id: awsRegionsProc
    command: ["sh", "-c", "curl -fsS --max-filesize 20971520 --max-time 10 https://ip-ranges.amazonaws.com/ip-ranges.json | head -c 20971520 | jq -c '[.prefixes[].region | ascii_downcase] | unique'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var codes = JSON.parse(String(text || "").trim())
          if (Array.isArray(codes) && codes.length) root.awsLiveRegionCodes = codes
        } catch (e) { /* retried by the timer */ }
      }
    }
    Component.onCompleted: running = true
  }

  Timer {
    interval: 60000
    repeat: true
    running: root.awsLiveRegionCodes.length === 0
    onTriggered: if (!awsRegionsProc.running) awsRegionsProc.running = true
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refreshAll() }
    function settings(): void { root.openSettings() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(watcherColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: catalogFilterField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: watcherScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: watcherColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: watcherColumn
          width: watcherScroll.width
          spacing: Style.space(12)

          // ---- Header: title left, last-check + refresh right.
          Item {
            width: parent.width
            height: Math.max(headerLeft.implicitHeight, headerRight.implicitHeight)

            Row {
              id: headerLeft
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                text: ""
                color: root.fg
                font.family: root.fontName
                font.pixelSize: Style.font.heading
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                text: "IS IT DOWN?"
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Row {
              id: headerRight
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                visible: root.lastChecked !== ""
                text: root.lastChecked
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              Rectangle {
                width: Style.space(20)
                height: Style.space(20)
                radius: Math.min(4, Style.cornerRadius)
                color: refreshArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  anchors.centerIn: parent
                  text: ""
                  color: root.dim
                  font.family: root.fontName
                  font.pixelSize: Style.font.bodySmall
                }

                MouseArea {
                  id: refreshArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.refreshAll()
                }
              }

              Rectangle {
                width: Style.space(20)
                height: Style.space(20)
                radius: Math.min(4, Style.cornerRadius)
                color: root.settingsMode || gearArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  anchors.centerIn: parent
                  text: ""
                  color: root.settingsMode ? Color.accent : root.dim
                  font.family: root.fontName
                  font.pixelSize: Style.font.bodySmall
                }

                MouseArea {
                  id: gearArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.settingsMode = !root.settingsMode
                }
              }
            }
          }

          // ---- Service tabs, borders tinted by each service's state.
          Flow {
            visible: !root.settingsMode
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.services

              Rectangle {
                id: tabPill
                required property var modelData
                required property int index

                readonly property int sev: root.severityFor(modelData.key)
                readonly property color sevColor: root.colorForSeverity(sev)
                readonly property bool selected: index === root.currentIndex

                width: tabRow.implicitWidth + Style.space(18)
                height: tabRow.implicitHeight + Style.space(10)
                radius: Style.cornerRadius
                color: selected || tabArea.containsMouse
                  ? Style.hoverFillFor(root.fg, Color.accent)
                  : "transparent"
                border.width: 1
                border.color: Qt.rgba(sevColor.r, sevColor.g, sevColor.b, selected ? 0.9 : 0.45)

                Row {
                  id: tabRow
                  anchors.centerIn: parent
                  spacing: Style.space(6)

                  Rectangle {
                    width: Style.space(7)
                    height: Style.space(7)
                    radius: width / 2
                    color: tabPill.sevColor
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: tabPill.modelData.name
                    textFormat: Text.PlainText
                    color: tabPill.selected ? Style.hoverStateColor(root.fg, Color.accent) : root.fg
                    font.family: root.fontName
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                MouseArea {
                  id: tabArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.userPickedTab = true
                    root.currentIndex = tabPill.index
                  }
                }
              }
            }
          }

          // ---- Detail card for the selected service.
          BorderSurface {
            visible: !root.settingsMode && !!root.currentService
            width: parent.width
            implicitHeight: cardColumn.implicitHeight + Style.space(24)
            radius: Style.cornerRadius

            readonly property color sevColor: root.currentService
              ? root.colorForSeverity(root.severityFor(root.currentService.key))
              : Color.muted

            color: Qt.rgba(sevColor.r, sevColor.g, sevColor.b, 0.06)
            borderSpec: Border.flat(Qt.rgba(sevColor.r, sevColor.g, sevColor.b, 0.55), 1)

            Column {
              id: cardColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(12)
              spacing: Style.space(10)

              // Headline row.
              Item {
                width: parent.width
                height: Math.max(headlineText.implicitHeight, sevBadge.implicitHeight)

                Text {
                  id: headlineText
                  anchors.left: parent.left
                  anchors.right: sevBadge.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.currentResult ? root.currentResult.headline : "Checking…"
                  textFormat: Text.PlainText
                  color: root.fg
                  font.family: root.fontName
                  font.pixelSize: Style.font.title
                  elide: Text.ElideRight
                }

                Text {
                  id: sevBadge
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.currentResult ? Model.severityLabel(root.currentResult.severity) : ""
                  color: root.currentService ? root.colorForSeverity(root.severityFor(root.currentService.key)) : root.dim
                  font.family: root.fontName
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1
                }
              }

              // Active incident names (statuspage services).
              Text {
                visible: !!(root.currentResult && root.currentResult.detail)
                width: parent.width
                text: root.currentResult ? root.currentResult.detail : ""
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              PanelSeparator {
                visible: componentList.count > 0
                foreground: root.fg
              }

              // Per-component (or per-event) rows.
              Repeater {
                id: componentList
                model: root.currentResult ? root.currentResult.items : []

                Item {
                  id: itemRow
                  required property var modelData
                  width: cardColumn.width
                  height: nameText.implicitHeight + Style.space(4)

                  MouseArea {
                    id: rowHover
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                  }

                  Rectangle {
                    id: compDot
                    width: Style.space(6)
                    height: Style.space(6)
                    radius: width / 2
                    color: root.colorForSeverity(itemRow.modelData.severity)
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    id: nameText
                    anchors.left: compDot.right
                    anchors.leftMargin: Style.space(8)
                    anchors.right: statusText.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: itemRow.modelData.name
                    textFormat: Text.PlainText
                    color: root.fg
                    font.family: root.fontName
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }

                  Text {
                    id: statusText
                    anchors.right: muteButton.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    text: itemRow.modelData.status
                    textFormat: Text.PlainText
                    color: itemRow.modelData.severity === Model.SEV_OK ? root.dim : root.colorForSeverity(itemRow.modelData.severity)
                    font.family: root.fontName
                    font.pixelSize: Style.font.bodySmall
                  }

                  // Mute this component/region: adds it to the service's
                  // ignore list (manage in the ⚙ settings view).
                  Item {
                    id: muteButton
                    width: Style.space(14)
                    height: parent.height
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      anchors.centerIn: parent
                      visible: rowHover.containsMouse || muteArea.containsMouse
                      text: "✕"
                      color: muteArea.containsMouse ? Color.accent : root.dim
                      font.family: root.fontName
                      font.pixelSize: Style.font.bodySmall
                    }

                    MouseArea {
                      id: muteArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: if (root.currentService) root.muteItem(root.currentService.key, itemRow.modelData.muteKey)
                    }
                  }
                }
              }

              // Summary for services with too many components to list
              // (e.g. Cloudflare's per-city PoPs).
              Text {
                visible: !!(root.currentResult && (root.currentResult.hiddenOk > 0 || root.currentResult.hiddenIssues > 0))
                width: parent.width
                text: {
                  if (!root.currentResult) return ""
                  var parts = []
                  if (root.currentResult.hiddenIssues > 0) parts.push("+" + root.currentResult.hiddenIssues + " more with issues")
                  if (root.currentResult.hiddenOk > 0) parts.push(root.currentResult.hiddenOk + " components operational")
                  return parts.join(" · ")
                }
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
              }

              PanelSeparator {
                foreground: root.fg
              }

              // Click-through to the real status page.
              Item {
                width: parent.width
                height: openText.implicitHeight + Style.space(4)

                Row {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    text: ""
                    color: openArea.containsMouse ? Color.accent : root.dim
                    font.family: root.fontName
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    id: openText
                    text: root.currentService ? "Open " + root.currentService.name + " status page" : ""
                    textFormat: Text.PlainText
                    color: openArea.containsMouse ? Color.accent : root.dim
                    font.family: root.fontName
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                MouseArea {
                  id: openArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openPage(root.currentService)
                }
              }
            }
          }

          Text {
            visible: !root.settingsMode
            width: parent.width
            text: "refreshes every " + root.refreshMinutes + " min"
            color: root.dim
            font.family: root.fontName
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          // ================= Settings: service list page =================
          Column {
            visible: root.settingsMode && root.settingsServiceKey === ""
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "SERVICES"
              foreground: root.fg
              fontFamily: root.fontName
            }

            Repeater {
              model: Model.fullRegistry(root.customServices)

              Item {
                id: serviceRow
                required property var modelData
                readonly property bool on: root.enabledKeys.indexOf(modelData.key) !== -1

                width: parent.width
                height: Style.space(36)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: serviceRowArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                }

                MouseArea {
                  id: serviceRowArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openServicePage(serviceRow.modelData.key)
                }

                Row {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    text: serviceRow.modelData.name
                    textFormat: Text.PlainText
                    // Watched services read brighter; toggled-off ones recede.
                    color: serviceRow.on ? root.fg : root.dim
                    opacity: serviceRow.on ? 1.0 : 0.7
                    font.family: root.fontName
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: "›"
                    color: root.dim
                    font.family: root.fontName
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                Row {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(10)

                  Text {
                    text: serviceRow.on ? "ENABLED" : "DISABLED"
                    color: serviceRow.on ? root.okColor : root.dim
                    opacity: serviceRow.on ? 1.0 : 0.7
                    font.family: root.fontName
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  ToggleSwitch {
                    checked: serviceRow.on
                    foreground: root.fg
                    accent: Color.accent
                    anchors.verticalCenter: parent.verticalCenter
                    onToggled: root.toggleService(serviceRow.modelData.key)
                  }
                }
              }
            }

            Text {
              width: parent.width
              topPadding: Style.space(8)
              text: "click a service to choose its regions / components"
              color: root.dim
              font.family: root.fontName
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }

          // ============ Settings: per-service drill-down page ============
          Column {
            visible: root.settingsMode && root.settingsServiceKey !== ""
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              height: Style.space(24)

              Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                Rectangle {
                  width: backRow.implicitWidth + Style.space(12)
                  height: Style.space(20)
                  radius: Style.cornerRadius
                  color: backArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                  anchors.verticalCenter: parent.verticalCenter

                  Row {
                    id: backRow
                    anchors.centerIn: parent
                    spacing: Style.space(4)

                    Text {
                      text: "‹"
                      color: root.dim
                      font.family: root.fontName
                      font.pixelSize: Style.font.body
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      text: "SERVICES"
                      color: root.dim
                      font.family: root.fontName
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 1
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  MouseArea {
                    id: backArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.closeServicePage()
                  }
                }
              }

              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.settingsService
                  ? root.settingsService.name.toUpperCase() + (root.settingsService.type === "aws" || root.settingsService.type === "azure" ? " · REGIONS" : " · COMPONENTS")
                  : ""
                textFormat: Text.PlainText
                color: Qt.darker(root.fg, 1.2)
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
              }
            }

            TextField {
              id: catalogFilterField
              width: parent.width
              placeholderText: "Filter…"
              foreground: root.fg
              font.family: root.fontName
              onTextChanged: root.settingsFilter = text

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }
            }

            Row {
              spacing: Style.space(8)

              Button {
                text: root.settingsFilter !== "" ? "ENABLE MATCHES" : "ENABLE ALL"
                bordered: true
                foreground: root.fg
                fontFamily: root.fontName
                fontSize: Style.font.caption
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.setAllRows(true)
              }

              Button {
                text: root.settingsFilter !== "" ? "DISABLE MATCHES" : "DISABLE ALL"
                bordered: true
                foreground: root.fg
                fontFamily: root.fontName
                fontSize: Style.font.caption
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.setAllRows(false)
              }
            }

            Repeater {
              model: root.settingsRows.rows

              Item {
                id: catalogRow
                required property var modelData

                width: parent.width
                height: Style.space(32)

                Row {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.right: catalogRight.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)
                  clip: true

                  Text {
                    text: catalogRow.modelData.label
                    textFormat: Text.PlainText
                    color: catalogRow.modelData.enabled ? root.fg : root.dim
                    opacity: catalogRow.modelData.enabled ? 1.0 : 0.7
                    font.family: root.fontName
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    visible: text !== ""
                    text: catalogRow.modelData.desc ? "(" + catalogRow.modelData.desc + ")" : ""
                    textFormat: Text.PlainText
                    color: root.dim
                    opacity: catalogRow.modelData.enabled ? 1.0 : 0.7
                    font.family: root.fontName
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                Row {
                  id: catalogRight
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(10)

                  Text {
                    text: catalogRow.modelData.enabled ? "ENABLED" : "DISABLED"
                    color: catalogRow.modelData.enabled ? root.okColor : root.dim
                    opacity: catalogRow.modelData.enabled ? 1.0 : 0.7
                    font.family: root.fontName
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  ToggleSwitch {
                    checked: catalogRow.modelData.enabled
                    foreground: root.fg
                    accent: Color.accent
                    anchors.verticalCenter: parent.verticalCenter
                    // Disabling stores one canonical key; enabling clears
                    // every alias (e.g. both region code and display name).
                    onToggled: root.setIgnoreState(
                      root.settingsServiceKey,
                      catalogRow.modelData.enabled ? [catalogRow.modelData.muteKeys[0]] : catalogRow.modelData.muteKeys,
                      catalogRow.modelData.enabled)
                  }
                }
              }
            }

            Text {
              visible: root.settingsRows.hidden > 0
              width: parent.width
              text: "+" + root.settingsRows.hidden + " more — refine the filter"
              color: root.dim
              font.family: root.fontName
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              visible: root.settingsRows.rows.length === 0
              width: parent.width
              text: root.settingsFilter !== ""
                ? "nothing matches the filter"
                : "waiting for the first fetch to list components…"
              color: root.dim
              font.family: root.fontName
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }
    }
  }
}
