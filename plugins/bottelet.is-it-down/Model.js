// Service registry + response parsing for the status watcher.
//
// To add a service: append an entry to registry() below and mirror it in
// manifest.json's barWidget.schema "services" options so it appears in the
// widget settings form. Services with defaultEnabled show when the user has
// made no selection yet.
//
// Two provider types are supported:
//   "statuspage" — any Atlassian Statuspage site (GitHub, Cloudflare, npm,
//                  OpenAI, Discord, ...). Point `api` at its
//                  /api/v2/summary.json endpoint.
//   "aws"        — the AWS Health public current-events feed (UTF-16 JSON).

var SEV_UNKNOWN = -1
var SEV_OK = 0
var SEV_MINOR = 1
var SEV_MAJOR = 2

function registry() {
  return [
    { key: "github", name: "GitHub", type: "statuspage", defaultEnabled: true,
      api: "https://www.githubstatus.com/api/v2/summary.json", page: "https://www.githubstatus.com" },
    { key: "aws", name: "AWS", type: "aws", defaultEnabled: true,
      api: "https://health.aws.amazon.com/public/currentevents", page: "https://health.aws.amazon.com/health/status" },
    { key: "azure", name: "Azure", type: "azure", defaultEnabled: true,
      api: "https://azure.status.microsoft/en-us/status/feed/", page: "https://azure.status.microsoft/en-us/status" },
    { key: "cloudflare", name: "Cloudflare", type: "statuspage", defaultEnabled: true,
      api: "https://www.cloudflarestatus.com/api/v2/summary.json", page: "https://www.cloudflarestatus.com" },
    { key: "npm", name: "npm", type: "statuspage", defaultEnabled: true,
      api: "https://status.npmjs.org/api/v2/summary.json", page: "https://status.npmjs.org" },
    { key: "claude", name: "Claude", type: "statuspage", defaultEnabled: false,
      api: "https://status.claude.com/api/v2/summary.json", page: "https://status.claude.com" },
    { key: "openai", name: "OpenAI", type: "statuspage", defaultEnabled: false,
      api: "https://status.openai.com/api/v2/summary.json", page: "https://status.openai.com" },
    { key: "vercel", name: "Vercel", type: "statuspage", defaultEnabled: false,
      api: "https://www.vercel-status.com/api/v2/summary.json", page: "https://www.vercel-status.com" },
    { key: "pypi", name: "PyPI", type: "statuspage", defaultEnabled: false,
      api: "https://status.python.org/api/v2/summary.json", page: "https://status.python.org" },
    { key: "discord", name: "Discord", type: "statuspage", defaultEnabled: false,
      api: "https://discordstatus.com/api/v2/summary.json", page: "https://discordstatus.com" },
    { key: "netlify", name: "Netlify", type: "statuspage", defaultEnabled: false,
      api: "https://www.netlifystatus.com/api/v2/summary.json", page: "https://www.netlifystatus.com" }
  ]
}

function defaultKeys() {
  var all = registry()
  var out = []
  for (var i = 0; i < all.length; i++) {
    if (all[i].defaultEnabled) out.push(all[i].key)
  }
  return out
}

// Settings selection → ordered service list. A missing selection (null,
// undefined, or blank string) means the default set, so a fresh install works
// without touching settings; an explicit array is honored as-is, including
// empty. Comma-separated strings are accepted for the CLI path.
function enabledServices(selectedKeys, customServices) {
  var all = fullRegistry(customServices)
  var defaults = []
  for (var d = 0; d < all.length; d++) if (all[d].defaultEnabled) defaults.push(all[d].key)
  var keys
  if (selectedKeys === null || selectedKeys === undefined) keys = defaults
  else if (typeof selectedKeys === "string") keys = normalizeList(selectedKeys).length ? normalizeList(selectedKeys) : defaults
  else keys = selectedKeys
  var out = []
  for (var i = 0; i < all.length; i++) {
    if (keys.indexOf(all[i].key) !== -1) out.push(all[i])
  }
  return out
}

// Per-service ignore rules from settings: `ignore` maps service key → list of
// muted entries (AWS: region code or display name; statuspage: component
// name). The legacy `awsIgnoreRegions` key folds into the AWS list.
function ignoreListFor(settings, serviceKey) {
  var out = []
  var table = settings && settings.ignore ? settings.ignore : null
  if (table && table[serviceKey]) out = out.concat(normalizeList(table[serviceKey]))
  if (serviceKey === "aws" && settings && settings.awsIgnoreRegions !== undefined)
    out = out.concat(normalizeList(settings.awsIgnoreRegions))
  return out
}

// User-defined services from settings (`customServices` in the widget's
// shell.json entry): [{key, name, api, page}] pointing at any Statuspage
// /api/v2/summary.json. Lets new services be added without code changes.
function normalizeCustomServices(value) {
  var list = Array.isArray(value) ? value : []
  var out = []
  var builtin = {}
  var all = registry()
  for (var b = 0; b < all.length; b++) builtin[all[b].key] = true
  for (var i = 0; i < list.length; i++) {
    var e = list[i]
    if (!e || !e.key || !e.api) continue
    var key = String(e.key).toLowerCase()
    if (builtin[key]) continue
    out.push({
      key: key,
      name: String(e.name || e.key),
      type: "statuspage",
      defaultEnabled: e.defaultEnabled !== false,
      api: String(e.api),
      page: String(e.page || e.api).replace(/\/api\/v2\/.*$/, "")
    })
  }
  return out
}

function fullRegistry(customServices) {
  return registry().concat(normalizeCustomServices(customServices))
}

function serviceByKey(key, customServices) {
  var all = fullRegistry(customServices)
  for (var i = 0; i < all.length; i++) {
    if (all[i].key === key) return all[i]
  }
  return null
}

// Cap on bytes buffered from any single fetch. Custom services point at
// arbitrary hosts, so a hostile endpoint could otherwise stream without end
// into StdioCollector (unbounded memory). curl --max-filesize rejects an
// oversized Content-Length up front; head -c bounds the chunked/no-length
// case where --max-filesize can't see the size in advance.
var MAX_BYTES = 10485760

// POSIX single-quote escaping: wrap in single quotes and turn any embedded
// quote into '\''. Service URLs come from user config (customServices), so
// they must never be interpolated into a shell line unescaped.
function shArg(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'"
}

// AWS serves its public events feed as UTF-16; transcode before parsing.
function fetchCommand(service) {
  var api = shArg(service.api)
  var fetch = "curl -fsS --max-filesize " + MAX_BYTES + " --max-time 8 " + api + " | head -c " + MAX_BYTES
  if (service.type === "aws")
    return ["sh", "-c", fetch + " | iconv -f UTF-16 -t UTF-8"]
  return ["sh", "-c", fetch]
}

function indicatorSeverity(indicator) {
  var v = String(indicator || "").toLowerCase()
  if (v === "none") return SEV_OK
  if (v === "minor" || v === "maintenance") return SEV_MINOR
  if (v === "major" || v === "critical") return SEV_MAJOR
  return SEV_UNKNOWN
}

function componentSeverity(status) {
  var v = String(status || "").toLowerCase()
  if (v === "operational") return SEV_OK
  if (v === "degraded_performance" || v === "partial_outage" || v === "under_maintenance") return SEV_MINOR
  if (v === "major_outage") return SEV_MAJOR
  return SEV_UNKNOWN
}

function humanizeStatus(status) {
  var v = String(status || "").replace(/_/g, " ")
  return v === "" ? "" : v.charAt(0).toUpperCase() + v.slice(1)
}

// The fetch failed or returned junk. Deliberately not counted as an outage:
// if the status pages themselves are unreachable, the answer to "is it me or
// is it down" is probably "it's you".
function unreachableResult() {
  return { severity: SEV_UNKNOWN, headline: "Unreachable — maybe it's you", detail: "", items: [], error: true }
}

function parseStatuspage(raw, ignoreList) {
  var data = JSON.parse(raw)
  var ignore = normalizeList(ignoreList)
  var incidents = data.incidents || []
  // With ignore rules active the site-wide indicator can't be trusted — it
  // may reflect exactly the components being muted (e.g. Cloudflare PoP
  // maintenance) — so severity is recomputed from what remains, keeping the
  // indicator only while real incidents are open.
  var overall = ignore.length
    ? (incidents.length ? indicatorSeverity(data.status ? data.status.indicator : "") : SEV_OK)
    : indicatorSeverity(data.status ? data.status.indicator : "")
  var items = []
  var catalog = []
  var comps = data.components || []
  for (var i = 0; i < comps.length; i++) {
    var c = comps[i]
    if (!c || c.group === true) continue
    // GitHub ships a fake "Visit www.githubstatus.com ..." component.
    if (String(c.name || "").indexOf("Visit www.") === 0) continue
    var name = String(c.name || "")
    var muteKey = name.toLowerCase()
    var sev = componentSeverity(c.status)
    // Every component — ignored or not — lands in the catalog so the
    // settings drill-down page can toggle it either way.
    catalog.push({ name: name, muteKey: muteKey, status: humanizeStatus(c.status), severity: sev })
    if (ignore.indexOf(muteKey) !== -1) continue
    if (sev > overall) overall = sev
    items.push({ name: name, muteKey: muteKey, status: humanizeStatus(c.status), severity: sev })
  }
  var names = []
  for (var j = 0; j < incidents.length && names.length < 3; j++) {
    if (incidents[j] && incidents[j].name) names.push(String(incidents[j].name))
  }
  var headline = data.status && data.status.description
    ? String(data.status.description)
    : (overall === SEV_OK ? "All systems operational" : "Status unknown")
  var shown = collapseItems(items)
  var collapsed = items.length > COLLAPSE_THRESHOLD
  return {
    severity: overall,
    headline: headline,
    detail: names.join(" · "),
    error: false,
    items: shown,
    catalog: catalog,
    hiddenOk: collapsed ? countOk(items) : 0,
    hiddenIssues: collapsed ? (items.length - countOk(items)) - shown.length : 0
  }
}

// Statuspage sites like Cloudflare list hundreds of per-PoP components; the
// panel only has room for the interesting ones. Past the threshold, show the
// non-operational components (capped) and summarize the healthy rest.
var COLLAPSE_THRESHOLD = 15
var MAX_SHOWN_ITEMS = 25

function countOk(items) {
  var n = 0
  for (var i = 0; i < items.length; i++) if (items[i].severity === SEV_OK) n++
  return n
}

function collapseItems(items) {
  if (items.length <= COLLAPSE_THRESHOLD) return items
  var issues = []
  for (var i = 0; i < items.length && issues.length < MAX_SHOWN_ITEMS; i++) {
    if (items[i].severity !== SEV_OK) issues.push(items[i])
  }
  return issues
}

// Known AWS regions for the per-service settings page. Codes match the event
// ARNs; names match the feed's region_name display strings.
function awsRegions() {
  return [
    { code: "us-east-1", name: "N. Virginia" },
    { code: "us-east-2", name: "Ohio" },
    { code: "us-west-1", name: "N. California" },
    { code: "us-west-2", name: "Oregon" },
    { code: "ca-central-1", name: "Canada Central" },
    { code: "sa-east-1", name: "São Paulo" },
    { code: "eu-west-1", name: "Ireland" },
    { code: "eu-west-2", name: "London" },
    { code: "eu-west-3", name: "Paris" },
    { code: "eu-central-1", name: "Frankfurt" },
    { code: "eu-central-2", name: "Zurich" },
    { code: "eu-north-1", name: "Stockholm" },
    { code: "eu-south-1", name: "Milan" },
    { code: "eu-south-2", name: "Spain" },
    { code: "me-central-1", name: "UAE" },
    { code: "me-south-1", name: "Bahrain" },
    { code: "il-central-1", name: "Tel Aviv" },
    { code: "af-south-1", name: "Cape Town" },
    { code: "ap-south-1", name: "Mumbai" },
    { code: "ap-south-2", name: "Hyderabad" },
    { code: "ap-southeast-1", name: "Singapore" },
    { code: "ap-southeast-2", name: "Sydney" },
    { code: "ap-southeast-3", name: "Jakarta" },
    { code: "ap-southeast-4", name: "Melbourne" },
    { code: "ap-northeast-1", name: "Tokyo" },
    { code: "ap-northeast-2", name: "Seoul" },
    { code: "ap-northeast-3", name: "Osaka" },
    { code: "ap-east-1", name: "Hong Kong" },
    { code: "global", name: "Global / non-regional" }
  ]
}

function azureRegions() {
  return [
    { code: "eastus", name: "East US" },
    { code: "eastus2", name: "East US 2" },
    { code: "southcentralus", name: "South Central US" },
    { code: "westus2", name: "West US 2" },
    { code: "westus3", name: "West US 3" },
    { code: "centralus", name: "Central US" },
    { code: "northcentralus", name: "North Central US" },
    { code: "westus", name: "West US" },
    { code: "canadacentral", name: "Canada Central" },
    { code: "canadaeast", name: "Canada East" },
    { code: "brazilsouth", name: "Brazil South" },
    { code: "northeurope", name: "North Europe (Ireland)" },
    { code: "westeurope", name: "West Europe (Netherlands)" },
    { code: "uksouth", name: "UK South (London)" },
    { code: "ukwest", name: "UK West (Cardiff)" },
    { code: "francecentral", name: "France Central (Paris)" },
    { code: "germanywestcentral", name: "Germany West Central (Frankfurt)" },
    { code: "switzerlandnorth", name: "Switzerland North (Zurich)" },
    { code: "norwayeast", name: "Norway East (Oslo)" },
    { code: "swedencentral", name: "Sweden Central" },
    { code: "polandcentral", name: "Poland Central" },
    { code: "italynorth", name: "Italy North (Milan)" },
    { code: "spaincentral", name: "Spain Central (Madrid)" },
    { code: "eastasia", name: "East Asia (Hong Kong)" },
    { code: "southeastasia", name: "Southeast Asia (Singapore)" },
    { code: "australiaeast", name: "Australia East (Sydney)" },
    { code: "australiasoutheast", name: "Australia Southeast (Melbourne)" },
    { code: "centralindia", name: "Central India (Pune)" },
    { code: "southindia", name: "South India (Chennai)" },
    { code: "westindia", name: "West India (Mumbai)" },
    { code: "japaneast", name: "Japan East (Tokyo)" },
    { code: "japanwest", name: "Japan West (Osaka)" },
    { code: "koreacentral", name: "Korea Central (Seoul)" },
    { code: "koreasouth", name: "Korea South (Busan)" },
    { code: "uaenorth", name: "UAE North (Dubai)" },
    { code: "southafricanorth", name: "South Africa North (Johannesburg)" },
    { code: "israelcentral", name: "Israel Central" },
    { code: "qatarcentral", name: "Qatar Central" },
    { code: "global", name: "Global / non-regional" }
  ]
}

// Rows for a service's settings drill-down page: everything that can be
// toggled on/off, with its current state. AWS and Azure pages list the static region
// catalog; statuspage pages list the components seen in the last fetch.
// Ignored entries that match nothing current are kept as extra rows so they
// can always be re-enabled.
function settingsCatalog(service, result, ignoreList, awsLiveRegionCodes) {
  var ignore = normalizeList(ignoreList)
  var rows = []
  var known = {}
  function has(entry) { return ignore.indexOf(entry) !== -1 }

  if (service && service.type === "aws") {
    var regions = awsRegions()
    for (var i = 0; i < regions.length; i++) {
      var r = regions[i]
      var nameKey = r.name.toLowerCase()
      known[r.code] = true
      known[nameKey] = true
      rows.push({
        label: r.code,
        desc: r.name,
        muteKeys: [r.code, nameKey],
        enabled: !(has(r.code) || has(nameKey))
      })
    }
    // Regions discovered live (from ip-ranges.amazonaws.com) that the
    // curated name map doesn't know yet — new regions appear here
    // automatically, just without a friendly name.
    var live = normalizeList(awsLiveRegionCodes).sort()
    for (var a = 0; a < live.length; a++) {
      if (known[live[a]]) continue
      known[live[a]] = true
      rows.push({ label: live[a], desc: "", muteKeys: [live[a]], enabled: !has(live[a]) })
    }
  } else if (service && service.type === "azure") {
    var azRegions = azureRegions()
    for (var az = 0; az < azRegions.length; az++) {
      var azR = azRegions[az]
      var azNameKey = azR.name.toLowerCase()
      known[azR.code] = true
      known[azNameKey] = true
      rows.push({
        label: azR.code,
        desc: azR.name,
        muteKeys: [azR.code, azNameKey],
        enabled: !(has(azR.code) || has(azNameKey))
      })
    }
  } else {
    var catalog = result && result.catalog ? result.catalog : []
    for (var j = 0; j < catalog.length; j++) {
      var c = catalog[j]
      known[c.muteKey] = true
      rows.push({
        label: c.name,
        desc: c.status,
        muteKeys: [c.muteKey],
        enabled: !has(c.muteKey)
      })
    }
  }

  for (var k = 0; k < ignore.length; k++) {
    if (known[ignore[k]]) continue
    rows.push({ label: ignore[k], desc: "custom entry", muteKeys: [ignore[k]], enabled: false })
  }
  return rows
}

function filterCatalog(rows, query, limit) {
  var q = String(query || "").replace(/^\s+|\s+$/g, "").toLowerCase()
  var out = []
  for (var i = 0; i < rows.length; i++) {
    if (q !== "" && String(rows[i].label).toLowerCase().indexOf(q) === -1
      && String(rows[i].desc || "").toLowerCase().indexOf(q) === -1) continue
    out.push(rows[i])
  }
  var max = limit || 60
  // `all` carries every filtered row (not just the rendered slice) so
  // toggle-all actions can cover the full match set.
  return { rows: out.slice(0, max), hidden: Math.max(0, out.length - max), all: out }
}

// The region an AWS event belongs to, both as code ("me-central-1", from the
// event ARN) and display name ("UAE"), lowercased for matching.
function awsEventRegion(event) {
  var parts = String(event.arn || "").split(":")
  return {
    code: (parts.length > 3 ? parts[3] : "").toLowerCase(),
    name: String(event.region_name || "").toLowerCase()
  }
}

// Accepts an array or a comma-separated string — `omarchy bar set` stores
// single values as plain strings, and quickshell's IPC CLI splits on commas,
// so string values are what the CLI path actually produces.
function normalizeList(value) {
  var list = typeof value === "string" ? value.split(",") : (value || [])
  var out = []
  for (var i = 0; i < list.length; i++) {
    var entry = String(list[i] || "").replace(/^\s+|\s+$/g, "").toLowerCase()
    if (entry !== "") out.push(entry)
  }
  return out
}

function awsRegionIgnored(event, ignoreList) {
  var ignore = normalizeList(ignoreList)
  if (!ignore.length) return false
  var region = awsEventRegion(event)
  return ignore.indexOf(region.code) !== -1 || ignore.indexOf(region.name) !== -1
}

// AWS current events: an empty array means all clear. Each event carries a
// log (newest first) whose status 0 marks it resolved; the event's own
// status escalates with impact, 3+ reading as a disruption. Events in
// ignored regions (matched by code or display name) are dropped entirely.
function parseAws(raw, ignoreRegions) {
  var data = JSON.parse(raw)
  var items = []
  var overall = SEV_OK
  for (var i = 0; i < (data ? data.length : 0); i++) {
    var e = data[i]
    if (!e) continue
    if (awsRegionIgnored(e, ignoreRegions)) continue
    var latest = e.event_log && e.event_log.length ? e.event_log[0] : null
    if (latest && parseInt(String(latest.status), 10) === 0) continue
    var sev = parseInt(String(e.status), 10) >= 3 ? SEV_MAJOR : SEV_MINOR
    if (sev > overall) overall = sev
    var region = awsEventRegion(e)
    items.push({
      name: String(e.service_name || "AWS") + (e.region_name ? " — " + String(e.region_name) : ""),
      muteKey: region.code || region.name,
      status: String(e.summary || "Event"),
      severity: sev
    })
  }
  var headline = items.length === 0
    ? "No current service events"
    : items.length + (items.length === 1 ? " active event" : " active events")
  return { severity: overall, headline: headline, detail: "", items: items, error: false }
}

function parseAzure(raw, ignoreList) {
  var text = String(raw || "").trim()
  if (!text || (text.indexOf("<rss") === -1 && text.indexOf("<channel") === -1)) {
    return unreachableResult()
  }

  var items = []
  var overall = SEV_OK
  var ignore = normalizeList(ignoreList)

  var itemRegex = /<item[\s\S]*?<\/item>/gi
  var match
  while ((match = itemRegex.exec(text)) !== null) {
    var itemXml = match[0]
    var titleMatch = itemXml.match(/<title(?:\s+[^>]*)?>([\s\S]*?)<\/title>/i)
    var title = titleMatch ? titleMatch[1].replace(/<!\[CDATA\[(.*?)\]\]>/gi, "$1").trim() : ""
    var descMatch = itemXml.match(/<description(?:\s+[^>]*)?>([\s\S]*?)<\/description>/i)
    var desc = descMatch ? descMatch[1].replace(/<!\[CDATA\[(.*?)\]\]>/gi, "$1").replace(/<[^>]+>/g, "").trim() : ""

    if (!title && !desc) continue

    var titleLower = title.toLowerCase()
    var descLower = desc.toLowerCase()

    var isIgnored = false
    for (var k = 0; k < ignore.length; k++) {
      if (titleLower.indexOf(ignore[k]) !== -1 || descLower.indexOf(ignore[k]) !== -1) {
        isIgnored = true
        break
      }
    }
    if (isIgnored) continue

    var sev = SEV_MINOR
    if (titleLower.indexOf("outage") !== -1 || titleLower.indexOf("critical") !== -1 ||
        titleLower.indexOf("major") !== -1 || descLower.indexOf("major outage") !== -1) {
      sev = SEV_MAJOR
    } else if (titleLower.indexOf("resolved") !== -1 || descLower.indexOf("resolved") !== -1) {
      sev = SEV_OK
    }

    if (sev > overall) overall = sev

    items.push({
      name: title || "Azure Event",
      muteKey: (title || "").toLowerCase(),
      status: desc || (sev === SEV_MAJOR ? "Major Outage" : (sev === SEV_MINOR ? "Degradation" : "Operational")),
      severity: sev
    })
  }

  var headline = items.length === 0
    ? "All systems operational"
    : items.length + (items.length === 1 ? " active event" : " active events")

  return {
    severity: overall,
    headline: headline,
    detail: items.length > 0 ? items[0].name : "",
    items: items,
    catalog: [],
    hiddenOk: 0,
    hiddenIssues: 0,
    error: false
  }
}

function parseResult(service, raw, options) {
  var text = String(raw || "").trim()
  if (text === "") return unreachableResult()
  var ignore = options ? options.ignore : null
  try {
    if (service.type === "aws") return parseAws(text, ignore)
    if (service.type === "azure") return parseAzure(text, ignore)
    return parseStatuspage(text, ignore)
  } catch (e) {
    return unreachableResult()
  }
}

// Services currently reporting an issue. Unknown/unreachable does not count —
// only confirmed degradation should light up the detective.
function issueCount(services, results) {
  var n = 0
  for (var i = 0; i < services.length; i++) {
    var r = results[services[i].key]
    if (r && r.severity >= SEV_MINOR) n++
  }
  return n
}

function worstSeverity(services, results) {
  var worst = SEV_UNKNOWN
  for (var i = 0; i < services.length; i++) {
    var r = results[services[i].key]
    if (r && r.severity > worst) worst = r.severity
  }
  return worst
}

function severityLabel(severity) {
  if (severity === SEV_OK) return "OK"
  if (severity === SEV_MINOR) return "ISSUES"
  if (severity === SEV_MAJOR) return "OUTAGE"
  return "—"
}

if (typeof module !== "undefined") {
  module.exports = {
    SEV_UNKNOWN: SEV_UNKNOWN,
    SEV_OK: SEV_OK,
    SEV_MINOR: SEV_MINOR,
    SEV_MAJOR: SEV_MAJOR,
    registry: registry,
    defaultKeys: defaultKeys,
    normalizeCustomServices: normalizeCustomServices,
    fullRegistry: fullRegistry,
    enabledServices: enabledServices,
    serviceByKey: serviceByKey,
    fetchCommand: fetchCommand,
    indicatorSeverity: indicatorSeverity,
    componentSeverity: componentSeverity,
    humanizeStatus: humanizeStatus,
    parseStatuspage: parseStatuspage,
    parseAws: parseAws,
    parseAzure: parseAzure,
    awsEventRegion: awsEventRegion,
    awsRegionIgnored: awsRegionIgnored,
    normalizeList: normalizeList,
    ignoreListFor: ignoreListFor,
    awsRegions: awsRegions,
    azureRegions: azureRegions,
    settingsCatalog: settingsCatalog,
    filterCatalog: filterCatalog,
    parseResult: parseResult,
    issueCount: issueCount,
    worstSeverity: worstSeverity,
    severityLabel: severityLabel
  }
}
