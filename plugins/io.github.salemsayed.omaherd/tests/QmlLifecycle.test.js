const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const path = require("node:path")
const test = require("node:test")

const service = readFileSync(path.join(__dirname, "..", "Service.qml"), "utf8")
const panel = readFileSync(path.join(__dirname, "..", "Panel.qml"), "utf8")
const bar = readFileSync(path.join(__dirname, "..", "BarWidget.qml"), "utf8")
const hookManifest = readFileSync(path.join(__dirname, "..", "herdr-plugin.toml"), "utf8")

test("the bar carries no number: attention is a bigger dot", () => {
  assert.ok(!/attentionCount > 99/.test(bar))
  assert.match(bar, /readonly property bool loud: dotState === "blocked" \|\| dotState === "done"/)
  assert.match(bar, /width: Style\.space\(loud \? 6 : 4\)/)
})

test("the HerdR hook plugin only pokes, and the bar answers it with a plain poll", () => {
  assert.match(bar, /function poke\(\) \{ if \(service\) service\.refresh\(false\)/)
  assert.match(bar, /function poke\(\): string \{ root\.broadcast\("poke"\)/)
  assert.match(bar, /function refresh\(\): string \{ root\.broadcast\("refresh"\)/)
  assert.match(hookManifest, /id = "io\.github\.salemsayed\.omaherd"/)
  for (const event of ["pane.agent_status_changed", "pane.agent_detected", "pane.closed"])
    assert.ok(hookManifest.includes(`on = "${event}"`), event)
  assert.ok(!hookManifest.includes("[[actions]]") && !hookManifest.includes("[[panes]]"))
})

test("status failures keep the last snapshot and notification helpers carry revisions", () => {
  assert.match(service, /if \(!parsed\.ok\) \{[\s\S]*hasErrors = true[\s\S]*return/)
  assert.match(service, /if \(statusProcess\.running\) \{[\s\S]*_refreshPending = true/)
  assert.match(service, /"--revision", String\(revision\)/)
  assert.match(service, /onNotifyModeChanged:[\s\S]*if \(_hasSnapshot\) reconcileNotifications/)
  assert.match(service, /retainUnavailableStates/)
  assert.match(service, /\^\-\?\[0-9\]\+\$\/\.test\(text\) \? Number\(text\) : fallback/)
  assert.match(service, /previous\.state === state && previous\.since <= stamped/)
  assert.match(service, /if \(includeDiscovery !== true\) command\.push\("--skip-discovery"\)/)
  assert.match(service, /if \(parsed\.discoveryIncluded !== false\)/)
  // Peeking is gated on the setting at the service, not only in the panel.
  assert.match(service, /function peekAgent\(agent\) \{\s*if \(!peekEnabled/)
  assert.match(service, /function replyAgent\(agent, text\) \{\s*if \(!peekEnabled/)
  const notificationBlock = service.slice(
    service.indexOf("function updateNotifications"),
    service.indexOf("function launchArgs"),
  )
  assert.match(notificationBlock, /"--hostname", String\(agent\.hostname \|\| ""\)/)
  // The hook is linked only under the setting, and only when not already listed.
  assert.match(service, /function ensureHook\(\) \{\s*if \(!instantUpdates/)
  assert.match(service, /"python3", statusHelperPath, "--ensure-hook", pluginRoot/)
  // Every stream entering the long-lived shell is producer-capped and then
  // retained through an explicit character cap instead of StdioCollector.
  assert.doesNotMatch(service, /StdioCollector/)
  assert.match(service, /function appendBounded\(current, chunk, maximum\)/)
  assert.match(service, /appendBounded\(root\._statusOutput,[\s\S]*524288/)
  assert.match(service, /appendBounded\(root\._peekOutput,[\s\S]*65536/)
})

test("the panel restores semantic cursor identity and guards deferred item access", () => {
  assert.match(panel, /property string selectedKey: ""/)
  assert.match(panel, /Model\.rowIndex\(root\.rows, root\.selectedKey\)/)
  assert.match(panel, /if \(!root\.opened \|\| !item \|\| !panelScroll\) return[\s\S]*try \{/)
  assert.match(panel, /if \(!root\.opened \|\| !root\.manualEditing \|\| !field \|\| !field\.visible\) return/)
  assert.match(panel, /Component\.onDestruction: if \(root && root\.replyField === replyField\)/)
})
