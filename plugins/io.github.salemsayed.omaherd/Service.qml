import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})
  property bool installed: false
  property bool refreshing: false
  property var targets: []
  property var discoveredHosts: []
  property var agents: []
  property var counts: Model.defaultCounts()
  property string statusText: "Checking…"
  property string lastError: ""
  property bool hasErrors: false
  property double generatedAt: 0
  // The wall clock the latest snapshot landed on. Elapsed labels read this
  // rather than Date.now() so they only move when the rows do.
  property double now: 0
  readonly property var connections: Model.connectionRows(targets, discoveredHosts)

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 4, 2, 60)
  readonly property int sshTimeoutSec: intSetting("sshTimeoutSec", 3, 1, 15)
  // "all", "blocked", or "off". The older boolean setting still counts when
  // the enum has never been written.
  readonly property string notifyMode: {
    var raw = String(setting("notifyOn", "")).toLowerCase().trim()
    if (raw === "") raw = boolSetting("notifications", true) ? "all" : "off"
    if (raw === "off" || raw === "false" || raw === "none") return "off"
    if (raw.indexOf("only") >= 0 || raw === "blocked") return "blocked"
    return "all"
  }
  onNotifyModeChanged: {
    // A setting change is also a truth change for existing cards: switching
    // to blocked-only takes done cards down, and Off takes every card down.
    // Wait for the first snapshot so construction cannot erase restored
    // notifications before we know which agents are still loud.
    if (_hasSnapshot) reconcileNotifications(agents, nextNotificationRevision())
  }
  // Off by default: it is the one thing in Omaherd that reads pane output,
  // and it only ever does so when a person presses P.
  readonly property bool peekEnabled: boolSetting("peekAndReply", false)
  // What the last peek returned, and for which agent.
  property string peekKey: ""
  property string peekText: ""
  property string peekError: ""
  property bool peekBusy: false
  // Instant updates: the repo doubles as a HerdR plugin whose event hook
  // pokes this widget. Linking it is a one-time, idempotent HerdR change the
  // setting authorises; turning the setting off never unlinks (that is the
  // person's call, with `herdr plugin unlink`).
  readonly property bool instantUpdates: boolSetting("instantUpdates", true)
  readonly property string pluginRoot: Model.filePath(Qt.resolvedUrl("."))
  property string hookState: "unknown"
  readonly property string statusHelperPath: Model.filePath(Qt.resolvedUrl("omaherd-status.py"))
  readonly property string attachHelperPath: Model.filePath(Qt.resolvedUrl("omaherd-attach"))
  readonly property string notifyHelperPath: Model.filePath(Qt.resolvedUrl("omaherd-notify"))

  property string _statusOutput: ""
  property string _statusError: ""
  property string _peekOutput: ""
  property string _peekProcessError: ""
  property bool _refreshPending: false
  property bool _discoveryPending: false
  property bool _refreshIncludesDiscovery: false
  property bool _hasSnapshot: false
  property var _agentStates: ({})
  property var _knownHosts: ({})
  property double _notificationRevision: 0
  // When each agent entered the state it is in. HerdR only numbers state
  // changes, so the clock starts the first time this process sees a state
  // and carries across polls while the state holds.
  property var _stateSince: ({})

  function appendBounded(current, chunk, maximum) {
    var before = String(current || "")
    var room = Math.max(0, maximum - before.length)
    return room === 0 ? before : before + String(chunk || "").slice(0, room)
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, minimum, maximum) {
    var text = String(setting(name, fallback)).trim()
    var value = /^-?[0-9]+$/.test(text) ? Number(text) : fallback
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, value))
  }

  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    if (typeof value === "boolean") return value
    var text = String(value).toLowerCase().trim()
    if (text === "true" || text === "1" || text === "yes" || text === "on") return true
    if (text === "false" || text === "0" || text === "no" || text === "off") return false
    return fallback
  }

  function nextNotificationRevision() {
    _notificationRevision = Math.max(Date.now(), _notificationRevision + 1)
    return _notificationRevision
  }

  function remoteHosts() {
    var raw = String(setting("remoteHosts", ""))
    var fields = raw.split(/[\s,]+/)
    var hosts = []
    for (var index = 0; index < fields.length; index++) {
      var host = fields[index].trim()
      if (host !== "" && hosts.indexOf(host) < 0) hosts.push(host)
    }
    return hosts.slice(0, 8)
  }

  function isMonitored(host) {
    var value = String(host || "local")
    return value === "local" || remoteHosts().indexOf(value) >= 0
  }

  function refresh(includeDiscovery) {
    if (statusHelperPath === "") return
    if (statusProcess.running) {
      _refreshPending = true
      if (includeDiscovery === true && !_refreshIncludesDiscovery) _discoveryPending = true
      return
    }
    _statusOutput = ""
    _statusError = ""
    refreshing = true
    _refreshIncludesDiscovery = includeDiscovery === true
    var command = ["python3", statusHelperPath, "--timeout", String(sshTimeoutSec)]
    if (includeDiscovery !== true) command.push("--skip-discovery")
    var hosts = remoteHosts()
    for (var index = 0; index < hosts.length; index++) {
      command.push("--remote-host")
      command.push(hosts[index])
    }
    statusProcess.command = command
    statusProcess.running = true
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) {
      lastError = parsed.lastError || "Could not read HerdR status"
      statusText = parsed.statusText || "Omaherd status failed"
      hasErrors = true
      return
    }
    var stamped = Date.now()
    updateNotifications(parsed, nextNotificationRevision())
    installed = parsed.installed === true
    targets = parsed.targets || []
    if (parsed.discoveryIncluded !== false)
      discoveredHosts = parsed.discoveredHosts || []
    agents = stampStateClocks(parsed.agents || [], stamped)
    now = stamped
    counts = parsed.counts || Model.defaultCounts()
    statusText = String(parsed.statusText || "HerdR")
    lastError = String(parsed.lastError || "")
    hasErrors = parsed.hasErrors === true
    generatedAt = Number(parsed.generatedAt || 0)
  }

  function stampStateClocks(list, stamped) {
    var next = {}
    for (var index = 0; index < list.length; index++) {
      var agent = list[index] || {}
      var key = "$" + String(agent.key || "")
      var state = String(agent.status || "unknown")
      var previous = _stateSince[key]
      // A wall-clock correction can move Date.now() backwards. Do not carry
      // a future timestamp forward and leave the elapsed label blank until
      // the clock catches up again.
      var since = previous && previous.state === state && previous.since <= stamped
        ? previous.since : stamped
      agent.since = since
      next[key] = { state: state, since: since }
    }
    _stateSince = next
    return list
  }

  function notify(args) {
    if (notifyHelperPath === "") return
    Quickshell.execDetached([notifyHelperPath].concat(args))
  }

  // Toasts track the truth: one per agent, raised when it starts asking for
  // a person, replaced if the ask changes, withdrawn when it stops asking.
  function updateNotifications(parsed, revision) {
    var nextAgents = parsed.agents || []
    var unavailable = Model.unavailableAgentScopes(parsed.targets || [])
    if (_hasSnapshot) {
      var closes = Model.notificationCloses(_agentStates, nextAgents, notifyMode, unavailable)
      for (var closeIndex = 0; closeIndex < closes.length; closeIndex++)
        notify(["--key", closes[closeIndex], "--kind", "close",
          "--revision", String(revision)])
      if (notifyMode !== "off") {
        var events = Model.notificationEvents(_agentStates, _knownHosts, nextAgents)
        for (var index = 0; index < events.length; index++) {
          var event = events[index]
          if (event.state === "done" && notifyMode === "blocked") continue
          var agent = event.agent
          var text = Model.notificationText(agent)
          notify([
            "--key", String(agent.key || ""),
            "--kind", event.state,
            "--summary", text.summary,
            "--body", text.body,
            "--host", String(agent.host || "local"),
            "--session", String(agent.session || "default"),
            "--target", String(agent.paneId || ""),
            "--workspace", Model.agentWorkspace(agent),
            "--hostname", String(agent.hostname || ""),
            "--revision", String(revision)
          ])
        }
      }
    }
    if (!_hasSnapshot) reconcileNotifications(nextAgents, revision)
    _agentStates = Model.retainUnavailableStates(
      _agentStates, Model.agentStateMap(nextAgents), unavailable)
    _knownHosts = Model.hostMap(parsed.targets || [])
    _hasSnapshot = true
  }

  // The first snapshot after a (re)start: toasts the shell restored for
  // agents that are no longer asking come down, the rest stay.
  function reconcileNotifications(agents, revision) {
    var args = ["--kind", "reconcile", "--revision", String(revision || Date.now())]
    var keys = Model.notificationKeepKeys(agents, notifyMode)
    for (var index = 0; index < keys.length; index++) args.push("--keep", keys[index])
    notify(args)
  }

  function launchArgs(host, session, target) {
    var args = ["omarchy-launch-terminal", attachHelperPath, "--host", String(host || "local")]
    args.push("--session")
    args.push(String(session || "default"))
    if (target !== undefined && target !== null && String(target) !== "") {
      args.push("--target")
      args.push(String(target))
    }
    return args
  }

  // A: a fresh terminal on the exact pane — locally, or over ssh -t for a
  // remote host.
  function attachAgent(agent) {
    if (!agent || !agent.paneId || attachHelperPath === "") return
    Quickshell.execDetached(launchArgs(agent.host, agent.session, agent.paneId))
  }

  // Enter: bring the agent to the front in a window that is already showing
  // its session rather than opening another. The helper falls back to an
  // attach when nothing on screen is showing it.
  function focusAgent(agent) {
    if (!agent || !agent.paneId || attachHelperPath === "") return
    Quickshell.execDetached([attachHelperPath,
      "--host", String(agent.host || "local"),
      "--session", String(agent.session || "default"),
      "--target", String(agent.paneId),
      "--workspace", Model.agentWorkspace(agent),
      "--hostname", String(agent.hostname || ""),
      "--timeout", String(sshTimeoutSec),
      "--focus"])
  }

  function helperArgs(agent) {
    return [attachHelperPath,
      "--host", String(agent.host || "local"),
      "--session", String(agent.session || "default"),
      "--target", String(agent.paneId),
      "--timeout", String(sshTimeoutSec)]
  }

  // P: the agent's last few terminal lines, fetched now and held only in
  // memory until the panel closes or another peek replaces it.
  function peekAgent(agent) {
    if (!peekEnabled || !agent || !agent.paneId || attachHelperPath === "") return
    if (peekProcess.running) return
    peekKey = String(agent.key || "")
    peekText = ""
    peekError = ""
    _peekOutput = ""
    _peekProcessError = ""
    peekBusy = true
    peekProcess.command = helperArgs(agent).concat(["--peek", "--lines", "14"])
    peekProcess.running = true
  }

  function clearPeek() {
    peekKey = ""
    peekText = ""
    peekError = ""
  }

  // I: type into the pane and press Enter, then look again shortly after so
  // the row and any open peek reflect the answer.
  function replyAgent(agent, text) {
    if (!peekEnabled || !agent || !agent.paneId || attachHelperPath === "") return false
    var body = String(text || "").trim()
    if (body === "") return false
    Quickshell.execDetached(helperArgs(agent).concat(["--reply", body]))
    replySettle.restart()
    return true
  }

  Timer {
    id: replySettle
    interval: 1200
    repeat: false
    onTriggered: {
      root.refresh(false)
      if (root.peekKey !== "") {
        var agent = null
        for (var index = 0; index < root.agents.length; index++)
          if (String(root.agents[index].key || "") === root.peekKey) agent = root.agents[index]
        if (agent) root.peekAgent(agent)
      }
    }
  }

  Process {
    id: peekProcess
    running: false
    command: []
    stdout: SplitParser {
      onRead: function(data) {
        root._peekOutput = root.appendBounded(root._peekOutput, String(data) + "\n", 65536)
      }
    }
    stderr: SplitParser {
      onRead: function(data) {
        root._peekProcessError = root.appendBounded(
          root._peekProcessError, String(data) + "\n", 16384)
      }
    }
    onExited: function(exitCode) {
      root.peekBusy = false
      var text = String(root._peekOutput || "").replace(/[ \t]+$/gm, "").replace(/\n{3,}/g, "\n\n").trim()
      if (exitCode === 0) {
        root.peekText = text
        root.peekError = text === "" ? "Nothing on screen yet" : ""
      } else {
        root.peekText = ""
        root.peekError = String(root._peekProcessError || "Could not read the agent").trim()
      }
    }
  }

  function openHerdr(target) {
    var value = target || { host: "local", session: "default" }
    if (attachHelperPath === "") return
    Quickshell.execDetached(launchArgs(value.host, value.session, ""))
  }

  function defaultTarget() {
    for (var index = 0; index < targets.length; index++) {
      if (targets[index] && targets[index].local === true && targets[index].installed === true)
        return { host: "local", session: "default" }
    }
    return { host: "local", session: "default" }
  }

  function ensureHook() {
    if (!instantUpdates || pluginRoot === "" || statusHelperPath === "" || hookEnsureProcess.running) return
    hookEnsureProcess.command = ["python3", statusHelperPath, "--ensure-hook", pluginRoot]
    hookEnsureProcess.running = true
  }

  Component.onCompleted: Qt.callLater(ensureHook)
  onInstantUpdatesChanged: if (instantUpdates) Qt.callLater(ensureHook)

  Process {
    id: hookEnsureProcess
    running: false
    command: []
    onExited: function(exitCode) {
      root.hookState = exitCode === 0 ? "linked" : (exitCode === 127 ? "no-herdr" : "failed")
      if (exitCode !== 0 && exitCode !== 127)
        console.warn("Omaherd: could not link the HerdR hook (exit", exitCode + ")")
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: SplitParser {
      onRead: function(data) {
        root._statusOutput = root.appendBounded(root._statusOutput, String(data) + "\n", 524288)
      }
    }
    stderr: SplitParser {
      onRead: function(data) {
        root._statusError = root.appendBounded(root._statusError, String(data) + "\n", 65536)
      }
    }
    onExited: function(exitCode) {
      root.refreshing = false
      root._refreshIncludesDiscovery = false
      var stdout = String(root._statusOutput || "")
      var stderr = String(root._statusError || "")
      if (exitCode === 0) root.applyStatus(stdout)
      else {
        root.lastError = String(stderr || stdout || "Could not collect HerdR status").trim()
        root.statusText = "Omaherd status failed"
        root.hasErrors = true
      }
      if (root._refreshPending) {
        var includeDiscovery = root._discoveryPending
        root._refreshPending = false
        root._discoveryPending = false
        Qt.callLater(function() { root.refresh(includeDiscovery) })
      }
    }
  }
}
