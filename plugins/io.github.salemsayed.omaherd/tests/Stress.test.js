const assert = require("node:assert/strict")
const test = require("node:test")
const Model = require("../Model.js")


test("twenty thousand agents survive every presentation transform", () => {
  const states = ["blocked", "done", "working", "idle", "unknown"]
  const agents = Array.from({ length: 20_000 }, (_, index) => ({
    key: `${index % 8 === 0 ? "local" : `host-${index % 8}`}|s${index % 4}|p${index}`,
    host: index % 8 === 0 ? "local" : `host-${index % 8}`,
    session: `s${index % 4}`,
    paneId: `p${index}`,
    status: states[index % states.length],
    workspaceNumber: index % 500,
    tabNumber: index % 30,
    workspaceLabel: `workspace-${index % 500}`,
    name: index % 2 ? "codex" : "claude",
    title: `Stress task ${index}`
  }))

  const attention = Model.agentSections(agents, "attention")
  const byHost = Model.agentSections(agents, "host")
  assert.equal(Model.flattenSections(attention).length, agents.length)
  assert.equal(byHost.reduce((total, section) => total + section.agents.length, 0), agents.length)
  assert.equal(byHost.length, 8)

  const rows = Model.panelRows(attention, [], { quietExpanded: true })
  assert.equal(rows.filter(row => row.kind === "agent").length, agents.length)
  assert.equal(new Set(rows.map(row => row.key)).size, rows.length)

  const active = agents.filter(agent => ["blocked", "done", "working"].includes(agent.status)).length
  const herd = Model.herdDotGroups(agents, 6)
  assert.equal(herd.groups.reduce((total, group) => total + group.dots.length, 0), 6)
  assert.equal(herd.overflow, active - 6)

  const statesMap = Model.agentStateMap(agents)
  assert.equal(Object.keys(statesMap).length, agents.length)
  const previous = Object.fromEntries(agents.map(agent => [`$${agent.key}`, "working"]))
  const hosts = Object.fromEntries(agents.map(agent => [`$${agent.host}`, true]))
  const events = Model.notificationEvents(previous, hosts, agents)
  assert.equal(events.length, agents.filter(agent => agent.status === "blocked" || agent.status === "done").length)
})


test("meter allocation keeps its invariants across randomized hostile shares", () => {
  let seed = 0x5eed1234
  const random = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32)
  const oddShares = [NaN, Infinity, -1, 0]

  for (let trial = 0; trial < 5_000; trial++) {
    const count = 1 + Math.floor(random() * 7)
    const available = random() * 1_000
    const minimum = random() * 50
    const segments = Array.from({ length: count }, () => ({
      share: random() < 0.08 ? oddShares[Math.floor(random() * oddShares.length)] : random() * 10
    }))
    const widths = Model.meterWidths(segments, available, minimum)
    assert.equal(widths.length, count)
    assert.ok(widths.every(width => Number.isFinite(width) && width >= -1e-9))

    const hasShare = segments.some(segment => Number.isFinite(segment.share) && segment.share > 0)
    const total = widths.reduce((sum, width) => sum + width, 0)
    assert.ok(hasShare ? Math.abs(total - available) < 1e-6 : total === 0)
  }
})


test("large malformed status payloads fail soft without leaking non-record rows", () => {
  const agents = Array.from({ length: 10_000 }, (_, index) =>
    index % 4 === 0 ? null : index % 4 === 1 ? "bad" : index % 4 === 2 ? [] : { key: `a${index}` })
  const status = Model.parseStatus(JSON.stringify({
    ok: true,
    targets: [null, "bad", { host: "local" }],
    discoveredHosts: { not: "a list" },
    agents,
    counts: []
  }))
  assert.equal(status.ok, true)
  assert.equal(status.targets.length, 1)
  assert.equal(status.discoveredHosts.length, 0)
  assert.equal(status.agents.length, 2_500)
  assert.deepEqual(status.counts, Model.defaultCounts())
})
