const assert = require("node:assert/strict")
const test = require("node:test")
const Model = require("../Model.js")

test("status parser accepts normalized data and fails closed", () => {
  const status = Model.parseStatus(JSON.stringify({
    ok: true,
    installed: true,
    targets: [{ host: "local" }],
    discoveredHosts: [{ host: "workbox", source: "SSH config" }],
    agents: [{ status: "blocked" }],
    counts: { total: 1, attention: 1, blocked: 1 }
  }))
  assert.equal(status.agents.length, 1)
  assert.equal(status.discoveredHosts.length, 1)
  assert.equal(status.counts.attention, 1)
  assert.equal(Model.parseStatus("broken").ok, false)
  assert.equal(Model.parseStatus("").ok, false)
  assert.equal(Model.parseStatus("[]").ok, false)
  assert.deepEqual(Model.parseStatus(JSON.stringify({ ok: true, agents: [null, "bad", { key: "a" }] })).agents,
    [{ key: "a" }])
})

test("state labels and order put attention first", () => {
  assert.ok(Model.stateRank("blocked") < Model.stateRank("working"))
  assert.ok(Model.stateRank("done") < Model.stateRank("idle"))
  assert.equal(Model.stateLabel("blocked"), "Needs input")
  assert.equal(Model.stateLabel("done"), "Done")
  assert.equal(Model.stateGlyph("working"), "\u{f0765}")
  assert.equal(Model.stateGlyph("nonsense"), Model.stateGlyph("unknown"))
  assert.ok(Model.compareAgents(
    { key: "a", status: "working", workspaceNumber: "bad", tabNumber: Infinity },
    { key: "b", status: "working", workspaceNumber: null, tabNumber: null }
  ) < 0)
})

test("agent labels retain host, session, and workspace context", () => {
  const agent = {
    host: "workbox",
    session: "agents",
    workspaceLabel: "omarchy",
    tabLabel: "shell",
    cwdLabel: "omarchy",
    name: "reviewer"
  }
  assert.equal(Model.agentTitle(agent), "omarchy · reviewer")
  assert.equal(Model.agentMeta(agent), "workbox · agents · shell")
  // The row itself sits under a host heading, so it drops the host.
  assert.equal(Model.agentDetail(agent), "agents · shell")
  // A numbered tab says so, rather than reading as a stray count.
  assert.equal(Model.agentDetail({ workspaceLabel: "omarchy", tabLabel: "3" }), "tab 3")
  assert.equal(Model.agentDetail({ workspaceLabel: "omarchy", tabLabel: "omarchy" }), "")
  assert.equal(Model.targetLabel("local"), "Local")
})

test("connection rows collapse remote sessions into monitoring hosts", () => {
  const rows = Model.connectionRows([
    {
      host: "local",
      local: true,
      reachable: true,
      sessions: [{ name: "default", running: false, agentCount: 0 }]
    },
    {
      host: "workbox",
      local: false,
      reachable: true,
      sessions: [
        { name: "default", running: true, agentCount: 2 },
        { name: "review", running: true, agentCount: 1 }
      ]
    },
    { host: "offline", local: false, reachable: false, sessions: [] }
  ])
  assert.deepEqual(rows.map(row => row.key), [
    "local|default", "workbox|monitor", "offline|monitor"
  ])
  assert.equal(rows[1].meta, "3 agents monitored")
  assert.equal(rows[2].meta, "Unavailable · Retrying in background")
})

test("connection rows append zero-config discoveries without duplicates", () => {
  const rows = Model.connectionRows(
    [{ host: "local", local: true, sessions: [] }],
    [
      { host: "workbox", source: "SSH config", detail: "Configured SSH host" },
      { host: "gpu.tailnet.ts.net", source: "Tailscale", detail: "gpu" },
      { host: "local", source: "SSH config" }
    ]
  )
  assert.deepEqual(rows.map(row => row.host), ["local", "workbox", "gpu.tailnet.ts.net"])
  assert.equal(rows[1].discovered, true)
  assert.equal(rows[1].meta, "SSH config · Configured SSH host")
  assert.equal(rows[2].meta, "Tailscale · gpu")
})

test("manual remote target validation allows SSH destinations but rejects commands", () => {
  assert.equal(Model.validRemoteTarget("workbox"), true)
  assert.equal(Model.validRemoteTarget("salem@workbox"), true)
  assert.equal(Model.validRemoteTarget("ssh://salem@workbox:2222"), true)
  assert.equal(Model.validRemoteTarget("ssh://build_box:2222"), true)
  assert.equal(Model.validRemoteTarget("ssh://deploy@[2001:db8::1]:2222"), true)
  assert.equal(Model.validRemoteTarget("ssh://workbox:70000"), false)
  assert.equal(Model.validRemoteTarget("ssh://salem:secret@workbox"), false)
  assert.equal(Model.validRemoteTarget("workbox;reboot"), false)
  for (const unusable of ["@", "-", ".", "..", "a@", "@b", "a@@b", "ssh://-host", "ssh://."])
    assert.equal(Model.validRemoteTarget(unusable), false, unusable)
})

test("notification transitions deduplicate state and suppress a newly monitored host", () => {
  const previousStates = {
    "$local|default|p1": "working",
    "$workbox|default|p2": "blocked"
  }
  const previousHosts = { "$local": true, "$workbox": true }
  const agents = [
    { key: "local|default|p1", host: "local", status: "done" },
    { key: "workbox|default|p2", host: "workbox", status: "blocked" },
    { key: "workbox|default|p3", host: "workbox", status: "blocked" },
    { key: "newbox|default|p4", host: "newbox", status: "done" }
  ]
  const events = Model.notificationEvents(previousStates, previousHosts, agents)
  assert.deepEqual(events.map(event => [event.agent.key, event.state]), [
    ["local|default|p1", "done"],
    ["workbox|default|p3", "blocked"]
  ])
  assert.deepEqual(Model.agentStateMap(agents), {
    "$local|default|p1": "done",
    "$workbox|default|p2": "blocked",
    "$workbox|default|p3": "blocked",
    "$newbox|default|p4": "done"
  })
  assert.deepEqual(Model.hostMap([{ host: "local" }, { host: "newbox" }]), {
    "$local": true,
    "$newbox": true
  })
})

test("notification state survives failed scopes without replaying recovered hosts", () => {
  const previous = {
    "$local|default|p1": "blocked",
    "$workbox|default|p2": "done",
    "$workbox|review|p3": "blocked"
  }
  const targets = [
    { host: "local", reachable: true, sessions: [{ name: "default", error: "" }] },
    { host: "workbox", reachable: false, error: "Command timed out", sessions: [] }
  ]
  const scopes = Model.unavailableAgentScopes(targets)
  const current = Model.agentStateMap([{ key: "local|default|p1", status: "working" }])
  assert.deepEqual(Model.notificationCloses(previous,
    [{ key: "local|default|p1", status: "working" }], "all", scopes),
  ["local|default|p1"])
  assert.deepEqual(Model.retainUnavailableStates(previous, current, scopes), {
    "$local|default|p1": "working",
    "$workbox|default|p2": "done",
    "$workbox|review|p3": "blocked"
  })
  assert.deepEqual(Model.hostMap(targets), { "$local": true })

  const sessionScopes = Model.unavailableAgentScopes([{
    host: "workbox", reachable: true, sessions: [
      { name: "default", error: "" }, { name: "review", error: "socket closed" }
    ]
  }])
  assert.deepEqual(Model.notificationCloses(previous, [], "all", sessionScopes).sort(),
    ["local|default|p1", "workbox|default|p2"])
})

test("notification modes close states that are no longer allowed", () => {
  const previous = { "$a": "blocked", "$b": "done" }
  const current = [{ key: "a", status: "done" }, { key: "b", status: "done" }]
  assert.deepEqual(Model.notificationCloses(previous, current, "blocked"), ["a"])
  assert.deepEqual(Model.notificationCloses(previous, current, "off"), [])
  assert.deepEqual(Model.notificationKeepKeys([
    { key: "a", status: "blocked" }, { key: "b", status: "done" }, { status: "blocked" }
  ], "blocked"), ["a"])
  assert.deepEqual(Model.notificationKeepKeys([{ key: "a", status: "blocked" }], "off"), [])
})

test("tooltip and hero summarize only actionable state", () => {
  const status = {
    installed: true,
    statusText: "3 agents",
    targets: [{ host: "local" }],
    counts: { total: 3, blocked: 1, done: 1, working: 1 }
  }
  assert.equal(Model.tooltip(status), "1 blocked · 1 done · 1 working")
  // The hero carries scope; the chips below it carry state.
  assert.equal(Model.heroMeta(status), "3 agents")
  assert.equal(Model.heroMeta({ ...status, targets: [{ host: "local" }, { host: "workbox" }] }),
    "3 agents · 2 hosts")
  assert.equal(Model.heroMeta({ statusText: "HerdR is stopped", counts: { total: 0 } }),
    "HerdR is stopped")
})

test("the state tally chips only the states worth walking over for", () => {
  const tally = Model.stateTally({ counts: { total: 5, blocked: 2, done: 1, working: 1, idle: 1 } })
  assert.deepEqual(tally.map((entry) => entry.state), ["blocked", "done", "working"])
  assert.deepEqual(tally[0], { state: "blocked", label: "need input", count: 2 })
  assert.deepEqual(Model.stateTally({ counts: { total: 2, idle: 2 } }), [])
  assert.deepEqual(Model.stateTally(null), [])
  assert.equal(Model.agentsLabel(1), "1 agent")
  assert.equal(Model.agentsLabel(4), "4 agents")
})

test("an agent's task is its title unless the title only names a place", () => {
  assert.equal(Model.agentTask({ title: "Calculation methods and release", workspaceLabel: "prayers" }),
    "Calculation methods and release")
  assert.equal(Model.agentTask({ title: "edgerouter", workspaceLabel: "edgerouter" }), "")
  assert.equal(Model.agentTask({ title: "/home/salem/Work/edgerouter", cwdLabel: "edgerouter" }), "")
  assert.equal(Model.agentTask({ title: "salem@pc:~/Work" }), "")
  assert.equal(Model.agentTask({ title: "  spaced   out  " }), "spaced out")
  // Frames the row already supplies are peeled off: a leading glyph or agent
  // name, the workspace before a colon, the workspace again after a dash.
  assert.equal(Model.agentTask({
    title: "π - storefront: Assistant identity introduction - storefront",
    workspaceLabel: "storefront", name: "pi", agent: "pi"
  }), "Assistant identity introduction")
  assert.equal(Model.agentTask({ title: "✳ Fix the bar", workspaceLabel: "omarchy" }), "Fix the bar")
  assert.equal(Model.agentTask({ title: "claude - omarchy", workspaceLabel: "omarchy", name: "claude" }), "")
  assert.equal(Model.agentTask({ title: "أداء فريق المبيعات", workspaceLabel: "storefront" }), "أداء فريق المبيعات")
  assert.equal(Model.agentTask(null), "")
})

test("elapsed labels fit a row corner and read as a sentence elsewhere", () => {
  const now = 1_000_000_000_000
  assert.equal(Model.sinceLabel(now - 20_000, now), "now")
  assert.equal(Model.sinceLabel(now - 4 * 60_000, now), "4m")
  assert.equal(Model.sinceLabel(now - 3 * 3_600_000, now), "3h")
  assert.equal(Model.sinceLabel(now - 2 * 86_400_000, now), "2d")
  assert.equal(Model.sinceLabel(0, now), "")
  assert.equal(Model.sinceLabel(now + 1, now), "")
  assert.equal(Model.sinceSentence("blocked", now - 4 * 60_000, now), "waiting 4m")
  assert.equal(Model.sinceSentence("done", now - 4 * 60_000, now), "finished 4m ago")
  assert.equal(Model.sinceSentence("blocked", now - 1_000, now), "just asked")
})

test("attention sections put whoever wants a person first, across hosts", () => {
  const agents = [
    { key: "a", host: "local", status: "idle", workspaceNumber: 1 },
    { key: "b", host: "local", status: "working", workspaceNumber: 2 },
    { key: "c", host: "workbox", status: "blocked", workspaceNumber: 1 },
    { key: "d", host: "workbox", status: "done", workspaceNumber: 2 },
    { key: "e", host: "local", status: "blocked", workspaceNumber: 3 }
  ]
  const sections = Model.agentSections(agents, "attention")
  assert.deepEqual(sections.map((s) => s.key), ["attention", "working", "quiet"])
  assert.deepEqual(sections[0].agents.map((a) => a.key), ["e", "c", "d"])
  assert.equal(sections[0].meta, "2 need input · 1 done")
  assert.equal(sections[0].loud, true)
  assert.equal(sections[1].meta, "1 agent")
  assert.deepEqual(Model.flattenSections(sections).map((a) => a.key), ["e", "c", "d", "b", "a"])

  const byHost = Model.agentSections(agents, "host")
  assert.deepEqual(byHost.map((s) => s.heading), ["LOCAL", "WORKBOX"])
  assert.deepEqual(byHost[0].agents.map((a) => a.key), ["e", "b", "a"])
  assert.equal(byHost[1].loud, true)
  assert.deepEqual(Model.agentSections([], "attention"), [])

  assert.equal(Model.hostChip(agents[2], "attention"), "workbox")
  assert.equal(Model.hostChip(agents[0], "attention"), "")
  assert.equal(Model.hostChip(agents[0], "attention", true), "local")
  assert.equal(Model.hostChip(agents[2], "host"), "")

  const dots = Model.herdDotGroups(agents, 4)
  assert.deepEqual(dots.groups.map((g) => g.label), ["Local", "workbox"])
  assert.deepEqual(dots.groups.map((g) => g.dots), [["blocked", "working"], ["blocked", "done"]])
  // The idle agent is not a dot, so four active agents fit a cap of four.
  assert.equal(dots.overflow, 0)
  assert.equal(Model.herdDotGroups(agents, 3).overflow, 1)
  assert.deepEqual(Model.herdDotGroups([{ status: "idle" }, { status: "unknown" }], 6), { groups: [], overflow: 0 })
  assert.deepEqual(Model.herdDotGroups([], 6), { groups: [], overflow: 0 })

  // Leaving dots linger as ghosts for one animation: a working dot that
  // went quiet, and a whole host whose agents all went quiet.
  const before = { groups: [
    { host: "local", label: "Local", dots: ["blocked", "working", "working"] },
    { host: "workbox", label: "workbox", dots: ["done"] }
  ] }
  const after = { groups: [{ host: "local", label: "Local", dots: ["blocked", "working"] }] }
  const ghosted = Model.ghostDotGroups(before, after)
  assert.deepEqual(ghosted.map((g) => g.host), ["local", "workbox"])
  assert.deepEqual(ghosted[0].dots, [
    { state: "blocked", ghost: false, fresh: false },
    { state: "working", ghost: false, fresh: false },
    { state: "working", ghost: true, fresh: false }
  ])
  assert.deepEqual(ghosted[1].dots, [{ state: "done", ghost: true, fresh: false }])
  assert.equal(Model.hasGhosts(ghosted), true)
  assert.equal(Model.hasGhosts(Model.ghostDotGroups(after, after)), false)
  // Nothing before: everything is fresh. Nothing after: everything is a ghost.
  assert.deepEqual(Model.ghostDotGroups(null, after)[0].dots.map((d) => d.fresh), [true, true])
  assert.deepEqual(Model.ghostDotGroups(after, { groups: [] })[0].dots.map((d) => d.ghost), [true, true])
  // A dot that only changed state is one ghost plus one fresh dot.
  const flipped = Model.ghostDotGroups(after, { groups: [{ host: "local", label: "Local", dots: ["blocked", "done"] }] })
  assert.deepEqual(flipped[0].dots.map((d) => [d.state, d.ghost, d.fresh]), [["blocked", false, false], ["done", false, true], ["working", true, false]])
  assert.deepEqual(Model.hostBreakdown({ agents }), ["Local · 1 need input · 1 working · 1 quiet", "workbox · 1 need input · 1 done"])
})

test("host grouping and connection discovery handle object-prototype aliases", () => {
  const sections = Model.agentSections([
    { key: "a", host: "constructor", status: "working" },
    { key: "b", host: "__proto__", status: "idle" }
  ], "host")
  assert.deepEqual(sections.map(section => section.host), ["constructor", "__proto__"])
  const rows = Model.connectionRows([], [
    { host: "constructor", source: "SSH config" },
    { host: "__proto__", source: "SSH config" }
  ])
  assert.deepEqual(rows.map(row => row.host), ["constructor", "__proto__"])
})

test("hosts are named the way a person says them", () => {
  assert.equal(Model.shortHost("studio.tail1234.ts.net"), "studio")
  assert.equal(Model.shortHost("workbox"), "workbox")
  assert.equal(Model.shortHost("deploy@workbox"), "workbox")
  assert.equal(Model.shortHost("ssh://deploy@example.com:2222/"), "example.com")
  assert.equal(Model.shortHost("10.0.0.7"), "10.0.0.7")
  assert.equal(Model.shortHost("box.local"), "box.local")
  assert.equal(Model.shortHost("local"), "Local")
  assert.equal(Model.shortHost(""), "Local")
  assert.equal(Model.hostChip({ host: "studio.tail1234.ts.net" }, "attention"), "studio")
})

test("the meter keeps one blocked agent visible among twenty", () => {
  const segments = Model.herdSegments({ blocked: 1, working: 4, idle: 15 })
  // 1/20 of 100px is 5px: below the floor, so it is lifted to 8 and the
  // wide segments pay for it in proportion.
  const widths = Model.meterWidths(segments, 100, 8)
  assert.equal(widths.length, 3)
  assert.equal(widths[0], 8)
  assert.ok(Math.abs(widths.reduce((a, b) => a + b, 0) - 100) < 1e-6)
  assert.ok(widths[2] > widths[1])
  assert.ok(widths[1] < 20 && widths[2] < 75)
  assert.deepEqual(Model.meterWidths([], 400, 8), [])
  assert.deepEqual(Model.meterWidths(segments, 0, 8), [0, 0, 0])
  const narrow = Model.meterWidths(segments, 10, 8)
  assert.ok(narrow.every(width => width >= 0))
  assert.ok(Math.abs(narrow.reduce((a, b) => a + b, 0) - 10) < 1e-6)
})

test("a big mixed herd sections, flattens, and caps cleanly", () => {
  const fixture = require("./fixtures/many-agents.json")
  const sections = Model.agentSections(fixture.agents, "attention")
  assert.deepEqual(sections.map((s) => s.key), ["attention", "working", "quiet"])
  assert.equal(Model.flattenSections(sections).length, fixture.agents.length)
  assert.equal(sections[0].agents.length, fixture.counts.blocked + fixture.counts.done)
  assert.ok(sections[0].agents.every((a, i, list) => i === 0 || Model.stateRank(list[i - 1].status) <= Model.stateRank(a.status)))
  const dots = Model.herdDots(fixture.agents, 6)
  assert.equal(dots.dots.length, 6)
  assert.equal(dots.overflow, fixture.agents.length - 6)
  assert.equal(dots.dots[0], "blocked")
  const byHost = Model.agentSections(fixture.agents, "host")
  assert.equal(byHost.length, fixture.targets.filter((t) => t.agents.length > 0).length)
  assert.ok(Model.tooltip(fixture).split("\n").length >= 2)
})

test("the herd renders as capped dots and proportional segments", () => {
  const agents = [{ status: "idle" }, { status: "blocked" }, { status: "working" }, { status: "idle" }]
  assert.deepEqual(Model.herdDots(agents, 3), { dots: ["blocked", "working", "idle"], overflow: 1 })
  assert.deepEqual(Model.herdDots(agents, 0).dots.length, 4)
  assert.deepEqual(Model.herdDots([], 6), { dots: [], overflow: 0 })
  const legend = Model.herdLegend({ blocked: 1, working: 1, idle: 2, unknown: 1 })
  assert.deepEqual(legend.map((e) => e.count + " " + e.label), ["1 need input", "1 working", "3 quiet"])
  assert.deepEqual(Model.herdLegend({ total: 0 }), [])
  const segments = Model.herdSegments({ blocked: 1, working: 1, idle: 2 })
  assert.deepEqual(segments.map((s) => s.state), ["blocked", "working", "idle"])
  assert.equal(segments[2].share, 0.5)
  assert.deepEqual(Model.herdSegments(null), [])
  assert.deepEqual(Model.herdDots([{ status: null }, { status: { odd: true } }], 6),
    { dots: ["unknown", "unknown"], overflow: 0 })
})

test("the tooltip names the agent that has waited longest", () => {
  const status = {
    installed: true,
    counts: { total: 2, blocked: 1, working: 1 },
    targets: [{ host: "local" }],
    agents: [
      { host: "local", status: "working", workspaceLabel: "a", name: "claude" },
      { host: "local", status: "blocked", workspaceLabel: "omarchy", name: "codex", title: "Fix the bar" }
    ]
  }
  assert.equal(Model.tooltip(status), "1 blocked · 1 working\nomarchy · codex · needs input\nFix the bar")
  const twoHosts = { ...status, agents: [...status.agents, { host: "workbox", status: "idle", workspaceLabel: "x", name: "pi" }],
    targets: [{ host: "local" }, { host: "workbox" }], counts: { total: 3, blocked: 1, working: 1, idle: 1 } }
  assert.equal(Model.tooltip(twoHosts).split("\n").slice(0, 3).join("\n"), "1 blocked · 1 working\nLocal · 1 need input · 1 working\nworkbox · 1 quiet")
})

test("toasts come down when the agent stops asking, and say the task", () => {
  const previous = { "$a": "blocked", "$b": "done", "$c": "working", "$d": "blocked" }
  const now = [
    { key: "a", status: "working" },   // answered
    { key: "b", status: "blocked" },   // done -> blocked: replaced, not closed
    { key: "c", status: "blocked" }    // newly loud
    // d gone
  ]
  assert.deepEqual(Model.notificationCloses(previous, now).sort(), ["a", "d"])
  assert.deepEqual(Model.notificationCloses({}, now), [])
  const text = Model.notificationText({
    host: "workbox", status: "blocked", workspaceLabel: "omarchy", name: "claude",
    title: "Fix the bar", tabLabel: "2"
  })
  assert.deepEqual(text, { summary: "omarchy · claude needs input", body: "Fix the bar\nworkbox · tab 2" })
  assert.equal(Model.notificationText({ status: "done", workspaceLabel: "a", name: "pi" }).summary, "a · pi finished")
})

test("plugin paths decode spaces", () => {
  assert.equal(Model.filePath("file:///tmp/Oma%20herd/status.py"), "/tmp/Oma herd/status.py")
  assert.equal(Model.filePath("file:///tmp/bad%path"), "/tmp/bad%path")
})

test("the panel folds quiet agents and the host chooser behind one row each", () => {
  const sections = Model.agentSections([
    { key: "a", host: "local", status: "blocked", workspaceNumber: 1 },
    { key: "b", host: "local", status: "working", workspaceNumber: 2 },
    { key: "c", host: "workbox", status: "idle", workspaceNumber: 1 },
    { key: "d", host: "workbox", status: "unknown", workspaceNumber: 2 }
  ], "attention")
  const connections = Model.connectionRows(
    [{ host: "local", local: true, sessions: [] }, { host: "workbox", reachable: false, sessions: [] }],
    [{ host: "spare", source: "SSH config" }, { host: "noisy", source: "SSH config" }]
  )
  const folded = Model.panelRows(sections, connections, {})
  assert.deepEqual(folded.map((r) => r.kind), ["agent", "agent", "quiet", "hosts"])
  assert.equal(folded[0].heading, "NEEDS YOU")
  assert.equal(folded[0].loud, true)
  assert.equal(folded[1].heading, "WORKING")
  assert.equal(folded[2].count, 2)
  assert.equal(Model.summaryText(folded[3].summary), "Local · workbox offline · 2 available")
  assert.equal(folded[3].summary.parts[1].tone, "urgent")

  const open = Model.panelRows(sections, connections, { quietExpanded: true, hostsExpanded: true })
  assert.deepEqual(open.map((r) => r.kind), ["agent", "agent", "quiet", "agent", "agent", "hosts", "host", "host", "host", "host", "manual"])
  // unknown ranks ahead of idle inside QUIET, so d precedes c.
  assert.equal(Model.rowIndex(open, "agent:d"), 3)
  assert.equal(Model.rowIndex(open, "agent:c"), 4)
  assert.equal(Model.rowIndex(open, "hosts"), 5)
  assert.equal(Model.rowIndex(open, "manual"), 10)
  assert.equal(Model.rowIndex(open, "agent:gone"), -1)
  assert.equal(Model.rowIndex(open, ""), -1)

  // Hiding a discovered host drops it from the chooser and the count.
  const visible = Model.visibleConnections(connections, "noisy, gone")
  assert.deepEqual(visible.filter((c) => c.discovered).map((c) => c.host), ["spare"])
  assert.equal(Model.hostsSummary(visible).available, 1)
  assert.deepEqual(Model.ignoredHostList(" a,b  b\nc "), ["a", "b", "c"])
  assert.deepEqual(Model.panelRows([], [], {}).map((r) => r.kind), ["hosts"])
})
