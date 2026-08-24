var STATE_RANK = {
  blocked: 0,
  done: 1,
  working: 2,
  unknown: 3,
  idle: 4
}

function defaultCounts() {
  return { total: 0, attention: 0, blocked: 0, done: 0, working: 0, idle: 0, unknown: 0 }
}

function defaultStatus() {
  return {
    ok: true,
    installed: false,
    generatedAt: 0,
    statusText: "Checking…",
    targets: [],
    discoveredHosts: [],
    agents: [],
    counts: defaultCounts(),
    hasErrors: false,
    lastError: ""
  }
}

function parseStatus(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw).trim()
  if (text === "") return failedStatus()
  try {
    var parsed = JSON.parse(text)
    if (!isRecord(parsed)) return failedStatus()
    parsed.targets = recordList(parsed.targets)
    parsed.discoveredHosts = recordList(parsed.discoveredHosts)
    parsed.agents = recordList(parsed.agents)
    parsed.counts = isRecord(parsed.counts)
      ? parsed.counts : defaultCounts()
    return parsed
  } catch (error) {
    return failedStatus()
  }
}

function isRecord(value) {
  return !!value && typeof value === "object" && !Array.isArray(value)
}

function recordList(value) {
  return (Array.isArray(value) ? value : []).filter(isRecord)
}

function failedStatus() {
  var failed = defaultStatus()
  failed.ok = false
  failed.statusText = "Omaherd status failed"
  failed.lastError = "Failed to parse HerdR status"
  return failed
}

function stateRank(state) {
  var key = String(state || "unknown").toLowerCase()
  return STATE_RANK[key] === undefined ? STATE_RANK.unknown : STATE_RANK[key]
}

function stateLabel(state) {
  var key = String(state || "unknown").toLowerCase()
  if (key === "blocked") return "Needs input"
  if (key === "done") return "Done"
  if (key === "working") return "Working"
  if (key === "idle") return "Idle"
  return "Unknown"
}

// Every state reads as the same kind of mark — a round badge — so the row
// glyphs line up as one column and only their color and fill carry meaning.
function stateGlyph(state) {
  var key = String(state || "unknown").toLowerCase()
  if (key === "blocked") return "󰀨"
  if (key === "done") return "󰗠"
  if (key === "working") return "󰝥"
  if (key === "idle") return "󰄰"
  return "󰋗"
}

function agentsLabel(count) {
  var value = Number(count) || 0
  return value + (value === 1 ? " agent" : " agents")
}

// stateLabel names a single agent's state ("Needs input"); a chip counts a
// group of them and has to read as one phrase after the number.
function tallyLabel(state) {
  var key = String(state || "unknown").toLowerCase()
  if (key === "blocked") return "need input"
  if (key === "done") return "done"
  if (key === "working") return "working"
  if (key === "idle") return "idle"
  return "unknown"
}

// The states worth a chip above the inbox, most urgent first. Idle is left
// out on purpose: the hero already counts those agents, and a chip saying
// nothing is happening competes with the two that mean come and look.
function stateTally(status) {
  var counts = (status && status.counts) || defaultCounts()
  var order = ["blocked", "done", "working"]
  var tally = []
  for (var index = 0; index < order.length; index++) {
    var state = order[index]
    var count = Number(counts[state] || 0)
    if (count > 0) tally.push({ state: state, label: tallyLabel(state), count: count })
  }
  return tally
}

function hostCount(status) {
  var targets = status ? status.targets : null
  return Array.isArray(targets) ? targets.length : 0
}

function targetLabel(host) {
  return String(host || "local") === "local" ? "Local" : String(host)
}

// The two halves of an agent's name are split out so the panel can weight
// them differently: the workspace is the long, variable part that elides,
// the agent is the short constant that stays readable.
function agentWorkspace(agent) {
  return agent ? String(agent.workspaceLabel || "Workspace") : "Workspace"
}

function agentName(agent) {
  if (!agent) return "Agent"
  return String(agent.name || agent.displayAgent || agent.agent || "Agent")
}

function agentTitle(agent) {
  return agentWorkspace(agent) + " · " + agentName(agent)
}

// A HerdR tab keeps its index until someone names it. A bare "3" next to a
// workspace reads as a count; "tab 3" reads as a place to go.
function tabLabel(agent) {
  var label = String((agent && agent.tabLabel) || "")
  if (label === "" || label === String((agent && agent.workspaceLabel) || "")) return ""
  return /^[0-9]+$/.test(label) ? "tab " + label : label
}

// Where the agent sits within its host. The panel groups rows under a host
// heading, so the row itself only has to say the part the heading does not.
function agentDetail(agent) {
  if (!agent) return ""
  var parts = []
  var session = String(agent.session || "default")
  if (session !== "default") parts.push(session)
  var tab = tabLabel(agent)
  if (tab !== "") parts.push(tab)
  var cwd = String(agent.cwdLabel || "")
  if (cwd !== "" && cwd !== String(agent.workspaceLabel || "")) parts.push(cwd)
  return parts.join(" · ")
}

// The same thing with the host restored, for notifications and tooltips that
// arrive with no surrounding panel to explain where the agent lives.
function agentMeta(agent) {
  if (!agent) return ""
  var detail = agentDetail(agent)
  var host = targetLabel(agent.host)
  return detail === "" ? host : host + " · " + detail
}

// What the agent says it is doing. HerdR passes the pane's terminal title
// through as structured metadata; Claude Code writes its current task there,
// most other agents write the directory. A title that only repeats a place
// the row already names is not a task and stays hidden.
function agentTask(agent) {
  if (!agent) return ""
  var title = String(agent.title || "").replace(/\s+/g, " ").trim()
  if (title === "") return ""
  if (/^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:/.test(title)) return ""
  var places = [agentWorkspace(agent), String(agent.cwdLabel || ""),
    String(agent.cwd || ""), agentName(agent), String(agent.agent || "")]
    .map(function(value) { return String(value || "").trim() })
    .filter(function(value) { return value !== "" })
  // Some agents frame the title with things the row already says: a glyph
  // or their own name up front, the workspace before a colon, the workspace
  // again after a dash. Peel those off and keep what is left.
  var changed = true
  while (changed) {
    changed = false
    var trimmed = title.replace(/^[^A-Za-z0-9\u0600-\u06FF\u0590-\u05FF\u0400-\u04FF\u3040-\u30FF\u4E00-\u9FFF]+/, "")
    if (trimmed !== title) { title = trimmed.trim(); changed = true }
    for (var index = 0; index < places.length; index++) {
      var place = places[index]
      var lowered = title.toLowerCase()
      var key = place.toLowerCase()
      if (lowered === key || lowered.endsWith("/" + key)) return ""
      var prefix = new RegExp("^" + escapeRegExp(place) + "\\s*[:\\-–—·|]\\s*", "i")
      var suffix = new RegExp("\\s*[:\\-–—·|]\\s*" + escapeRegExp(place) + "$", "i")
      var next = title.replace(prefix, "").replace(suffix, "").trim()
      if (next !== title) { title = next; changed = true }
    }
  }
  return title
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

// How long an agent has been in its current state, sized for a row corner:
// "now", "4m", "2h", "3d". Empty when either clock is missing.
function sinceLabel(sinceMs, nowMs) {
  var since = Number(sinceMs || 0)
  var now = Number(nowMs || 0)
  if (!(since > 0) || !(now > 0) || now < since) return ""
  var seconds = Math.floor((now - since) / 1000)
  if (seconds < 60) return "now"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return minutes + "m"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h"
  return Math.floor(hours / 24) + "d"
}

// The elapsed time read as a sentence, for tooltips and notifications where
// a bare "4m" has nothing beside it to explain what the minutes were.
function sinceSentence(state, sinceMs, nowMs) {
  var label = sinceLabel(sinceMs, nowMs)
  if (label === "") return ""
  var key = String(state || "unknown").toLowerCase()
  if (label === "now") return key === "blocked" ? "just asked" : "just now"
  if (key === "blocked") return "waiting " + label
  if (key === "done") return "finished " + label + " ago"
  if (key === "working") return "working " + label
  return key + " " + label
}

var SECTIONS = [
  { key: "attention", heading: "NEEDS YOU", states: ["blocked", "done"], loud: true },
  { key: "working", heading: "WORKING", states: ["working"], loud: false },
  { key: "quiet", heading: "QUIET", states: ["idle", "unknown"], loud: false }
]

function sectionForState(state) {
  var key = String(state || "unknown").toLowerCase()
  for (var index = 0; index < SECTIONS.length; index++)
    if (SECTIONS[index].states.indexOf(key) >= 0) return SECTIONS[index]
  return SECTIONS[SECTIONS.length - 1]
}

function compareAgents(a, b) {
  var left = isRecord(a) ? a : {}
  var right = isRecord(b) ? b : {}
  var rank = stateRank(left.status) - stateRank(right.status)
  if (rank !== 0) return rank
  var aLocal = String(left.host || "local") === "local" ? 0 : 1
  var bLocal = String(right.host || "local") === "local" ? 0 : 1
  if (aLocal !== bLocal) return aLocal - bLocal
  var host = String(left.host || "").localeCompare(String(right.host || ""))
  if (host !== 0) return host
  var workspace = finiteNumber(left.workspaceNumber) - finiteNumber(right.workspaceNumber)
  if (workspace !== 0) return workspace
  var tab = finiteNumber(left.tabNumber) - finiteNumber(right.tabNumber)
  if (tab !== 0) return tab
  var session = String(left.session || "").localeCompare(String(right.session || ""))
  if (session !== 0) return session
  return String(left.key || "").localeCompare(String(right.key || ""))
}

function finiteNumber(value) {
  var number = Number(value || 0)
  return isFinite(number) ? number : 0
}

// The inbox in sections. "attention" puts every agent that wants a person at
// the top no matter where it runs, then the ones working, then the quiet
// ones; "host" keeps HerdR's own grouping by machine. Either way the order
// the sections flatten to is the order the keyboard cursor walks.
function agentSections(agents, mode) {
  var list = recordList(agents)
  var sections = []
  var byKey = {}
  if (String(mode || "attention").toLowerCase() === "host") {
    for (var hostIndex = 0; hostIndex < list.length; hostIndex++) {
      var agent = list[hostIndex]
      var host = String(agent.host || "local")
      var hostKey = "$" + host
      if (!byKey[hostKey]) {
        byKey[hostKey] = { key: "host:" + host, heading: targetLabel(host).toUpperCase(),
          host: host, loud: false, agents: [] }
        sections.push(byKey[hostKey])
      }
      byKey[hostKey].agents.push(agent)
    }
    for (var hostSection = 0; hostSection < sections.length; hostSection++) {
      sections[hostSection].agents.sort(compareAgents)
      sections[hostSection].meta = agentsLabel(sections[hostSection].agents.length)
      sections[hostSection].loud = sections[hostSection].agents.some(function(entry) {
        return stateRank(entry.status) <= STATE_RANK.done
      })
    }
    return sections
  }
  var sorted = list.slice().sort(compareAgents)
  for (var index = 0; index < sorted.length; index++) {
    var section = sectionForState(sorted[index].status)
    if (!byKey[section.key]) {
      byKey[section.key] = { key: section.key, heading: section.heading, host: "",
        loud: section.loud, agents: [] }
      sections.push(byKey[section.key])
    }
    byKey[section.key].agents.push(sorted[index])
  }
  for (var metaIndex = 0; metaIndex < sections.length; metaIndex++)
    sections[metaIndex].meta = sectionMeta(sections[metaIndex])
  return sections
}

// "2 need input · 1 done" for the attention section, a plain count elsewhere.
function sectionMeta(section) {
  var agents = section && Array.isArray(section.agents) ? section.agents : []
  if (!section || section.key !== "attention") return agentsLabel(agents.length)
  var counts = {}
  for (var index = 0; index < agents.length; index++) {
    var agent = isRecord(agents[index]) ? agents[index] : {}
    var state = String(agent.status || "unknown").toLowerCase()
    counts[state] = (counts[state] || 0) + 1
  }
  var parts = []
  if (counts.blocked) parts.push(counts.blocked + " " + tallyLabel("blocked"))
  if (counts.done) parts.push(counts.done + " " + tallyLabel("done"))
  return parts.join(" · ")
}

// The line under the meter. Idle and unknown are one word here — "quiet" —
// because that is the fold they live in, and five counts wrap where four fit.
function herdLegend(counts) {
  var source = counts || defaultCounts()
  var entries = []
  var order = ["blocked", "done", "working"]
  for (var index = 0; index < order.length; index++) {
    var count = Number(source[order[index]] || 0)
    if (count > 0) entries.push({ state: order[index], count: count, label: tallyLabel(order[index]) })
  }
  var quiet = Number(source.idle || 0) + Number(source.unknown || 0)
  if (quiet > 0) entries.push({ state: "idle", count: quiet, label: "quiet" })
  return entries
}

function flattenSections(sections) {
  var agents = []
  var list = Array.isArray(sections) ? sections : []
  for (var index = 0; index < list.length; index++) {
    var entries = list[index] && Array.isArray(list[index].agents) ? list[index].agents : []
    for (var entry = 0; entry < entries.length; entry++) agents.push(entries[entry])
  }
  return agents
}

// The herd as marks: one state per agent, loudest first, capped so the bar
// stays a bar. `overflow` is how many agents the cap hid.
function herdDots(agents, cap) {
  var list = recordList(agents)
  var rawLimit = Number(cap)
  var limit = isFinite(rawLimit) && rawLimit > 0 ? Math.floor(rawLimit) : list.length
  limit = Math.min(limit, list.length)
  var order = ["blocked", "done", "working", "unknown", "idle"]
  var counts = { blocked: 0, done: 0, working: 0, unknown: 0, idle: 0 }
  for (var index = 0; index < list.length; index++) {
    var state = String(list[index].status || "unknown").toLowerCase()
    if (counts[state] === undefined) state = "unknown"
    counts[state]++
  }
  var dots = []
  for (var rank = 0; rank < order.length && dots.length < limit; rank++) {
    for (var count = 0; count < counts[order[rank]] && dots.length < limit; count++)
      dots.push(order[rank])
  }
  return { dots: dots, overflow: Math.max(0, list.length - limit) }
}

// Segments of a stacked meter, in the order the eye should meet them.
function herdSegments(counts) {
  var source = counts || defaultCounts()
  var order = ["blocked", "done", "working", "idle", "unknown"]
  var total = 0
  var segments = []
  for (var index = 0; index < order.length; index++) {
    var count = Number(source[order[index]] || 0)
    if (count > 0) {
      segments.push({ state: order[index], count: count })
      total += count
    }
  }
  for (var segment = 0; segment < segments.length; segment++)
    segments[segment].share = total > 0 ? segments[segment].count / total : 0
  return segments
}

// A host the way you would say it: "studio", not
// "studio.tail1234.ts.net"; the alias, not the ssh:// URI around it.
function shortHost(host) {
  var value = String(host || "").trim()
  if (value === "" || value === "local") return "Local"
  value = value.replace(/^ssh:\/\//, "").replace(/\/$/, "")
  value = value.replace(/^[^@]+@/, "")
  value = value.replace(/:[0-9]{1,5}$/, "")
  var labels = value.split(".")
  var numeric = labels.every(function(label) { return /^[0-9]+$/.test(label) })
  if (labels.length >= 3 && !numeric) return labels[0]
  return value
}

// Where an agent lives, said only when the row would otherwise not know:
// attention sections mix hosts, so a remote agent names its machine — and
// once more than one machine is in play, so does a local one, or "local"
// would be the only row without a name.
function hostChip(agent, mode, multiHost) {
  if (!agent) return ""
  if (String(mode || "attention").toLowerCase() === "host") return ""
  var host = String(agent.host || "local")
  if (host === "local") return multiHost === true ? "local" : ""
  return shortHost(host)
}

// The bar's dots, grouped by machine: the loudest `cap` agents overall,
// then bucketed by host with the local machine first, so a breathing dot
// in the second group is visibly "a remote one" without a label. Quiet
// agents draw nothing — a row of idle dots is space spent saying "nothing".
function herdDotGroups(agents, cap) {
  var list = recordList(agents).filter(function(agent) {
    var state = String(agent.status || "unknown").toLowerCase()
    return state === "blocked" || state === "done" || state === "working"
  }).sort(compareAgents)
  var limit = Math.max(0, Number(cap) || 0) || list.length
  var taken = list.slice(0, limit)
  var groups = []
  var byHost = {}
  for (var index = 0; index < taken.length; index++) {
    var host = String(taken[index].host || "local")
    var key = "$" + host
    if (!byHost[key]) {
      byHost[key] = { host: host, label: host === "local" ? "Local" : shortHost(host), dots: [] }
      groups.push(byHost[key])
    }
    byHost[key].dots.push(String(taken[index].status || "unknown").toLowerCase())
  }
  groups.sort(function(a, b) {
    if (a.host === "local") return -1
    if (b.host === "local") return 1
    return a.host.localeCompare(b.host)
  })
  return { groups: groups, overflow: Math.max(0, list.length - taken.length) }
}

// What the bar draws while dots are leaving: the new groups, plus a ghost
// for every dot the previous frame had and this one does not, so a dot can
// shrink away instead of vanishing. Ghosts live one animation long; the
// caller swaps in the plain groups once it has played.
function ghostDotGroups(previous, next) {
  var before = previous && Array.isArray(previous.groups) ? previous.groups : []
  var after = next && Array.isArray(next.groups) ? next.groups : []
  var seen = {}
  var merged = []
  for (var index = 0; index < after.length; index++) {
    var group = after[index]
    seen["$" + group.host] = true
    var old = null
    for (var find = 0; find < before.length; find++)
      if (before[find].host === group.host) old = before[find]
    // Match this frame's dots against the last one's, state for state: the
    // matched ones are steady, the unmatched new ones are fresh (they pop
    // in), the unmatched old ones are ghosts (they shrink out).
    var unmatched = old ? old.dots.slice() : []
    var dots = group.dots.map(function(state) {
      var at = unmatched.indexOf(state)
      if (at >= 0) { unmatched.splice(at, 1); return { state: state, ghost: false, fresh: false } }
      return { state: state, ghost: false, fresh: true }
    })
    for (var leftover = 0; leftover < unmatched.length; leftover++)
      dots.push({ state: unmatched[leftover], ghost: true, fresh: false })
    merged.push({ host: group.host, label: group.label, dots: dots })
  }
  for (var gone = 0; gone < before.length; gone++) {
    if (seen["$" + before[gone].host]) continue
    merged.push({ host: before[gone].host, label: before[gone].label,
      dots: before[gone].dots.map(function(state) { return { state: state, ghost: true, fresh: false } }) })
  }
  merged.sort(function(a, b) {
    if (a.host === "local") return -1
    if (b.host === "local") return 1
    return a.host.localeCompare(b.host)
  })
  return merged
}

function hasGhosts(groups) {
  var list = Array.isArray(groups) ? groups : []
  for (var index = 0; index < list.length; index++)
    for (var dot = 0; dot < list[index].dots.length; dot++)
      if (list[index].dots[dot].ghost) return true
  return false
}

// One line per host for the tooltip: "workbox · 1 working · 2 quiet".
function hostBreakdown(status) {
  var agents = status && Array.isArray(status.agents) ? status.agents : []
  var order = []
  var byHost = {}
  for (var index = 0; index < agents.length; index++) {
    var agent = agents[index] || {}
    var host = String(agent.host || "local")
    var key = "$" + host
    if (!byHost[key]) {
      byHost[key] = { host: host, counts: defaultCounts() }
      order.push(byHost[key])
    }
    var state = String(agent.status || "unknown").toLowerCase()
    byHost[key].counts[state in byHost[key].counts ? state : "unknown"] += 1
    byHost[key].counts.total += 1
  }
  order.sort(function(a, b) {
    if (a.host === "local") return -1
    if (b.host === "local") return 1
    return a.host.localeCompare(b.host)
  })
  return order.map(function(entry) {
    var parts = herdLegend(entry.counts).map(function(item) { return item.count + " " + item.label })
    return (entry.host === "local" ? "Local" : shortHost(entry.host)) + " · " + parts.join(" · ")
  })
}

// Segment widths for the herd meter: proportional to the herd, but never so
// thin that one blocked agent among twenty disappears into the gap. What the
// thin segments are owed comes out of the wide ones in proportion.
function meterWidths(segments, available, minimum) {
  var list = Array.isArray(segments) ? segments : []
  var room = Math.max(0, Number(available) || 0)
  if (list.length === 0) return []
  if (room === 0) return list.map(function() { return 0 })
  var floor = Math.min(Math.max(0, Number(minimum) || 0), room / list.length)
  var shares = list.map(function(segment) {
    var share = Number(segment && segment.share)
    return isFinite(share) && share > 0 ? share : 0
  })
  var shareTotal = shares.reduce(function(total, share) { return total + share }, 0)
  if (shareTotal <= 0) return list.map(function() { return 0 })
  var widths = shares.map(function(share) { return room * share / shareTotal })
  var owed = 0
  var flexible = 0
  for (var index = 0; index < widths.length; index++) {
    if (widths[index] < floor) owed += floor - widths[index]
    else flexible += widths[index] - floor
  }
  for (var fix = 0; fix < widths.length; fix++) {
    if (widths[fix] < floor) widths[fix] = floor
    else if (flexible > 0) widths[fix] -= owed * ((widths[fix] - floor) / flexible)
  }
  return widths
}

function connectionRows(targets, discoveredHosts) {
  var rows = []
  var list = Array.isArray(targets) ? targets : []
  var seenHosts = {}
  for (var targetIndex = 0; targetIndex < list.length; targetIndex++) {
    var target = list[targetIndex] || {}
    var host = String(target.host || "local")
    seenHosts["$" + host] = true
    var sessions = Array.isArray(target.sessions) ? target.sessions : []
    var local = target.local === true || host === "local"

    if (!local) {
      var remoteAgentCount = 0
      for (var remoteSessionIndex = 0; remoteSessionIndex < sessions.length; remoteSessionIndex++)
        remoteAgentCount += Math.max(0, finiteNumber((sessions[remoteSessionIndex] || {}).agentCount))
      rows.push({
        key: host + "|monitor",
        host: host,
        session: "default",
        local: false,
        reachable: target.reachable !== false,
        running: sessions.length > 0,
        agentCount: remoteAgentCount,
        title: host,
        meta: target.reachable === false
          ? "Unavailable · Retrying in background"
          : (remoteAgentCount > 0
            ? remoteAgentCount + " " + (remoteAgentCount === 1 ? "agent" : "agents") + " monitored"
            : "Background monitoring")
      })
      continue
    }
    var addedDefault = false
    var targetStart = rows.length

    for (var sessionIndex = 0; sessionIndex < sessions.length; sessionIndex++) {
      var session = sessions[sessionIndex] || {}
      var name = String(session.name || "default")
      if (name === "default") addedDefault = true
      rows.push(connectionRow(target, host, session, name))
    }

    if (!addedDefault) rows.splice(targetStart, 0, connectionRow(target, host, {}, "default"))
  }

  var discovered = Array.isArray(discoveredHosts) ? discoveredHosts : []
  for (var discoveredIndex = 0; discoveredIndex < discovered.length; discoveredIndex++) {
    var item = discovered[discoveredIndex] || {}
    var discoveredHost = String(item.host || "").trim()
    if (discoveredHost === "" || seenHosts["$" + discoveredHost]) continue
    seenHosts["$" + discoveredHost] = true
    var source = String(item.source || "Discovered")
    var detail = String(item.detail || "")
    rows.push({
      key: discoveredHost + "|default",
      host: discoveredHost,
      session: "default",
      local: false,
      reachable: true,
      running: false,
      agentCount: 0,
      discovered: true,
      source: source,
      title: discoveredHost,
      meta: source + (detail !== "" && detail !== discoveredHost ? " · " + detail : "")
    })
  }
  return rows
}

function validRemoteTarget(value) {
  var target = String(value || "").trim()
  // A plain destination is either an SSH alias/hostname or one user@host
  // pair. Requiring both sides to start with a useful character keeps
  // punctuation-only values such as "@", ".", and "-" out of settings.
  if (/^(?:[A-Za-z0-9._~-]+@)?[A-Za-z0-9_][A-Za-z0-9_.-]*$/.test(target)) return true
  var match = /^ssh:\/\/(?:[A-Za-z0-9._~-]+@)?(?:[A-Za-z0-9_][A-Za-z0-9_.-]*|\[[A-Fa-f0-9:.]+\])(?::([0-9]{1,5}))?\/?$/.exec(target)
  if (!match) return false
  if (match[1] !== undefined) {
    var port = Number(match[1])
    if (port < 1 || port > 65535) return false
  }
  return true
}

function agentStateMap(agents) {
  var states = {}
  var list = Array.isArray(agents) ? agents : []
  for (var index = 0; index < list.length; index++) {
    var agent = list[index] || {}
    var key = String(agent.key || "")
    if (key !== "") states["$" + key] = String(agent.status || "unknown")
  }
  return states
}

function hostMap(targets) {
  var hosts = {}
  var list = Array.isArray(targets) ? targets : []
  for (var index = 0; index < list.length; index++) {
    var target = list[index] || {}
    var host = String(target.host || "")
    if (host !== "" && target.reachable !== false && String(target.error || "") === "")
      hosts["$" + host] = true
  }
  return hosts
}

// A failed target or session says "unknown", not "gone". Keep the previous
// state for that scope until a successful snapshot can prove the agent moved
// on; otherwise one SSH timeout withdraws every toast and recovery replays it.
function unavailableAgentScopes(targets) {
  var scopes = {}
  var list = recordList(targets)
  for (var index = 0; index < list.length; index++) {
    var target = list[index]
    var host = String(target.host || "local")
    if (target.reachable === false || String(target.error || "") !== "") {
      scopes["$" + host + "|"] = true
      continue
    }
    var sessions = recordList(target.sessions)
    for (var sessionIndex = 0; sessionIndex < sessions.length; sessionIndex++) {
      var session = sessions[sessionIndex]
      if (String(session.error || "") !== "")
        scopes["$" + host + "|" + String(session.name || "default") + "|"] = true
    }
  }
  return scopes
}

function agentScopeUnavailable(key, scopes) {
  var value = String(key || "")
  var map = scopes && typeof scopes === "object" ? scopes : {}
  var first = value.indexOf("|")
  if (first < 0) return false
  if (map["$" + value.slice(0, first + 1)] === true) return true
  var second = value.indexOf("|", first + 1)
  return second >= 0 && map["$" + value.slice(0, second + 1)] === true
}

function retainUnavailableStates(previousStates, nextStates, scopes) {
  var previous = previousStates && typeof previousStates === "object" ? previousStates : {}
  var next = nextStates && typeof nextStates === "object" ? nextStates : {}
  var merged = {}
  for (var current in next) merged[current] = next[current]
  for (var entry in previous) {
    if (merged[entry] === undefined && agentScopeUnavailable(entry.slice(1), scopes))
      merged[entry] = previous[entry]
  }
  return merged
}

function notificationEvents(previousStates, previousHosts, agents) {
  var events = []
  var states = previousStates && typeof previousStates === "object" ? previousStates : {}
  var hosts = previousHosts && typeof previousHosts === "object" ? previousHosts : {}
  var list = Array.isArray(agents) ? agents : []
  for (var index = 0; index < list.length; index++) {
    var agent = list[index] || {}
    var host = String(agent.host || "local")
    var key = String(agent.key || "")
    var state = String(agent.status || "unknown")
    if (key === "" || hosts["$" + host] !== true) continue
    if (state !== "blocked" && state !== "done") continue
    if (states["$" + key] === state) continue
    events.push({ state: state, agent: agent })
  }
  return events
}

// Agents whose toast should come down: they were asking for a person last
// time and now are not — answered, moved on, or gone. An agent that flipped
// from one loud state to the other is not here; its raise replaces the toast.
function notificationCloses(previousStates, agents, mode, unavailableScopes) {
  var states = previousStates && typeof previousStates === "object" ? previousStates : {}
  var present = {}
  var list = Array.isArray(agents) ? agents : []
  for (var index = 0; index < list.length; index++) {
    var agent = list[index] || {}
    var key = String(agent.key || "")
    if (key !== "") present["$" + key] = String(agent.status || "unknown")
  }
  var closes = []
  for (var entry in states) {
    if (!stateIsNotifiable(states[entry], mode)) continue
    var now = present[entry]
    if ((now === undefined || !stateIsNotifiable(now, mode))
        && !agentScopeUnavailable(entry.slice(1), unavailableScopes))
      closes.push(entry.slice(1))
  }
  return closes
}

function stateIsNotifiable(state, mode) {
  var notifyMode = String(mode || "all").toLowerCase()
  if (notifyMode === "off") return false
  var key = String(state || "unknown").toLowerCase()
  if (notifyMode === "blocked") return key === "blocked"
  return stateIsLoud(key)
}

function notificationKeepKeys(agents, mode) {
  var keys = []
  var list = recordList(agents)
  for (var index = 0; index < list.length; index++) {
    var key = String(list[index].key || "")
    if (key !== "" && stateIsNotifiable(list[index].status, mode)) keys.push(key)
  }
  return keys
}

// What a toast says. The summary names the agent and the ask; the body
// leads with the task when there is one, then where the agent lives.
function notificationText(agent) {
  var blocked = String(agent && agent.status || "") === "blocked"
  var summary = agentTitle(agent) + (blocked ? " needs input" : " finished")
  var task = agentTask(agent)
  var meta = agentMeta(agent)
  var body = task !== "" ? (meta !== "" ? task + "\n" + meta : task) : meta
  return { summary: summary, body: body }
}

function connectionRow(target, host, session, name) {
  var local = target.local === true || host === "local"
  var running = session.running === true
  var reachable = target.reachable !== false
  var agentCount = Math.max(0, finiteNumber(session.agentCount))
  var meta = name === "default" ? "Default session" : "Session " + name
  if (!reachable) meta += " · Connect interactively"
  else if (running) meta += agentCount > 0
    ? " · " + agentCount + " " + (agentCount === 1 ? "agent" : "agents")
    : " · Running"
  else meta += " · Start or attach"
  return {
    key: host + "|" + name,
    host: host,
    session: name,
    local: local,
    reachable: reachable,
    running: running,
    agentCount: agentCount,
    title: local ? "Local" : host,
    meta: meta
  }
}

function tooltip(status) {
  if (!status) return "Checking HerdR…"
  if (status.installed !== true && (!status.targets || status.targets.length <= 1))
    return "HerdR is not installed"
  var counts = status.counts || defaultCounts()
  var parts = []
  if (Number(counts.blocked || 0) > 0) parts.push(counts.blocked + " blocked")
  if (Number(counts.done || 0) > 0) parts.push(counts.done + " done")
  if (Number(counts.working || 0) > 0) parts.push(counts.working + " working")
  if (parts.length === 0) parts.push(String(status.statusText || "HerdR"))
  var line = parts.join(" · ")
  var breakdown = hostBreakdown(status)
  if (breakdown.length > 1) line += "\n" + breakdown.join("\n")
  var agents = recordList(status.agents)
  var first = null
  for (var index = 0; index < agents.length; index++)
    if (!first || compareAgents(agents[index], first) < 0) first = agents[index]
  if (first && stateIsLoud(first.status)) {
    var task = agentTask(first)
    line += "\n" + agentTitle(first) + " · " + stateLabel(first.status).toLowerCase()
    if (task !== "") line += "\n" + task
  }
  return line
}

function stateIsLoud(state) {
  var key = String(state || "unknown").toLowerCase()
  return key === "blocked" || key === "done"
}

// Scope, not state: how much herd there is and how far it reaches. The state
// tally gets its own chips, so repeating it here would say the same thing
// twice in two type sizes.
function heroMeta(status) {
  if (!status) return "Checking…"
  var counts = status.counts || defaultCounts()
  var total = Number(counts.total || 0)
  if (total === 0) return String(status.statusText || "No active agents")
  var parts = [agentsLabel(total)]
  var hosts = hostCount(status)
  if (hosts > 1) parts.push(hosts + " hosts")
  return parts.join(" · ")
}

function filePath(url) {
  var value = String(url || "").replace(/^file:\/\//, "")
  try { return decodeURIComponent(value) }
  catch (error) { return value }
}

// Preserve what the cursor means while a poll inserts, removes, or reorders
// rows underneath it. The manual row has an identity too, so editing it does
// not jump onto a newly arrived host.
// Hosts the person has said they do not want offered: discovered aliases
// that live in ~/.ssh/config for other reasons.
function ignoredHostList(raw) {
  var fields = String(raw || "").split(/[\s,]+/)
  var hosts = []
  for (var index = 0; index < fields.length; index++) {
    var host = fields[index].trim()
    if (host !== "" && hosts.indexOf(host) < 0) hosts.push(host)
  }
  return hosts
}

function visibleConnections(connections, ignored) {
  var hidden = Array.isArray(ignored) ? ignored : ignoredHostList(ignored)
  return recordList(connections).filter(function(connection) {
    return connection.discovered !== true || hidden.indexOf(String(connection.host || "")) < 0
  })
}

// One line that says where the herd is being watched: the local machine,
// each monitored host (offline ones in the urgent tone), and how many more
// could be added. Everything else about hosts stays folded away.
function hostsSummary(connections) {
  var parts = []
  var available = 0
  var seenLocal = false
  var list = recordList(connections)
  for (var index = 0; index < list.length; index++) {
    var connection = list[index]
    if (connection.discovered === true) { available++; continue }
    if (connection.local === true) {
      if (!seenLocal) parts.push({ label: "Local", tone: "text" })
      seenLocal = true
      continue
    }
    var offline = connection.reachable === false
    parts.push({ label: shortHost(connection.host) + (offline ? " offline" : ""),
      tone: offline ? "urgent" : "text" })
  }
  if (available > 0)
    parts.push({ label: available + " available", tone: "dim" })
  return { parts: parts, available: available }
}

function summaryText(summary) {
  var parts = summary && Array.isArray(summary.parts) ? summary.parts : []
  return parts.map(function(part) { return part.label }).join(" · ")
}

// The panel as a flat list of rows the cursor can walk: agents (the quiet
// ones folded behind one row unless opened), then one row for the hosts
// that unfolds into the chooser. Each row knows its own key so the cursor
// can find the same row again after a poll rebuilds the list.
function panelRows(sections, connections, options) {
  var opts = options || {}
  var rows = []
  var list = Array.isArray(sections) ? sections : []
  for (var index = 0; index < list.length; index++) {
    var section = list[index] || {}
    var agents = recordList(section.agents)
    var foldable = section.key === "quiet"
    if (foldable) {
      rows.push({ kind: "quiet", key: "quiet", heading: section.heading,
        count: agents.length, expanded: opts.quietExpanded === true })
      if (opts.quietExpanded !== true) continue
    }
    for (var agentIndex = 0; agentIndex < agents.length; agentIndex++) {
      var agent = agents[agentIndex]
      rows.push({
        kind: "agent",
        key: "agent:" + String(agent.key || (section.key + ":" + agentIndex)),
        agent: agent,
        sectionKey: String(section.key || ""),
        heading: !foldable && agentIndex === 0 ? String(section.heading || "") : "",
        loud: section.loud === true && stateIsLoud(agent.status)
      })
    }
  }
  var summary = hostsSummary(connections)
  rows.push({ kind: "hosts", key: "hosts", summary: summary,
    expanded: opts.hostsExpanded === true })
  if (opts.hostsExpanded === true) {
    var visible = recordList(connections)
    for (var hostIndex = 0; hostIndex < visible.length; hostIndex++) {
      var connection = visible[hostIndex]
      rows.push({ kind: "host", key: "host:" + String(connection.key || connection.host || hostIndex),
        connection: connection })
    }
    rows.push({ kind: "manual", key: "manual" })
  }
  return rows
}

function rowIndex(rows, key) {
  var value = String(key || "")
  if (value === "") return -1
  var list = Array.isArray(rows) ? rows : []
  for (var index = 0; index < list.length; index++)
    if (list[index] && String(list[index].key || "") === value) return index
  return -1
}

if (typeof module !== "undefined") {
  module.exports = {
    defaultCounts: defaultCounts,
    defaultStatus: defaultStatus,
    parseStatus: parseStatus,
    stateRank: stateRank,
    stateLabel: stateLabel,
    stateGlyph: stateGlyph,
    agentsLabel: agentsLabel,
    stateTally: stateTally,
    hostCount: hostCount,
    targetLabel: targetLabel,
    agentWorkspace: agentWorkspace,
    agentName: agentName,
    agentTitle: agentTitle,
    agentMeta: agentMeta,
    agentDetail: agentDetail,
    tabLabel: tabLabel,
    tallyLabel: tallyLabel,
    connectionRows: connectionRows,
    validRemoteTarget: validRemoteTarget,
    agentStateMap: agentStateMap,
    hostMap: hostMap,
    unavailableAgentScopes: unavailableAgentScopes,
    retainUnavailableStates: retainUnavailableStates,
    notificationEvents: notificationEvents,
    notificationCloses: notificationCloses,
    stateIsNotifiable: stateIsNotifiable,
    notificationKeepKeys: notificationKeepKeys,
    notificationText: notificationText,
    agentTask: agentTask,
    sinceLabel: sinceLabel,
    sinceSentence: sinceSentence,
    agentSections: agentSections,
    sectionMeta: sectionMeta,
    flattenSections: flattenSections,
    compareAgents: compareAgents,
    herdDots: herdDots,
    herdDotGroups: herdDotGroups,
    ghostDotGroups: ghostDotGroups,
    hasGhosts: hasGhosts,
    hostBreakdown: hostBreakdown,
    herdSegments: herdSegments,
    herdLegend: herdLegend,
    hostChip: hostChip,
    shortHost: shortHost,
    meterWidths: meterWidths,
    stateIsLoud: stateIsLoud,
    ignoredHostList: ignoredHostList,
    visibleConnections: visibleConnections,
    hostsSummary: hostsSummary,
    summaryText: summaryText,
    panelRows: panelRows,
    rowIndex: rowIndex,
    tooltip: tooltip,
    heroMeta: heroMeta,
    filePath: filePath,
  }
}
