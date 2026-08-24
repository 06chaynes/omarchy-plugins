var API = Qt.resolvedUrl("hue-api.py").toString().replace("file://", "")

function apiCmd(args) {
  var cmd = ["python3", API]
  for (var i = 0; i < args.length; i++) cmd.push(String(args[i]))
  return cmd
}

function isValidIp(ip) {
  return /^(\d{1,3}\.){3}\d{1,3}$/.test(ip)
}

function isValidId(id) {
  return /^[a-zA-Z0-9_-]{1,40}$/.test(String(id))
}

function parseConfig(text) {
  var raw = String(text || "").trim()
  if (!raw) return null
  try {
    var parsed = JSON.parse(raw)
    if (!parsed || typeof parsed !== "object") return null
    var bridgeIp = String(parsed.bridgeIp || "").trim()
    var username = String(parsed.username || "").trim()
    var bridgeId = String(parsed.bridgeId || "").trim().toLowerCase()
    if (!bridgeIp || !isValidIp(bridgeIp)) return null
    if (!username || !isValidId(username)) return null
    if (bridgeId && !isValidId(bridgeId)) bridgeId = ""
    return { bridgeIp: bridgeIp, username: username, bridgeId: bridgeId }
  } catch (e) {
    return null
  }
}

function parseJsonObject(text) {
  var raw = String(text || "").trim()
  if (!raw) return null
  try {
    var parsed = JSON.parse(raw)
    return parsed && typeof parsed === "object" ? parsed : null
  } catch (e) {
    return null
  }
}

function parseLights(text) {
  var obj = parseJsonObject(text)
  if (!obj) return []
  var lights = []
  for (var id in obj) {
    if (!Object.prototype.hasOwnProperty.call(obj, id)) continue
    var light = obj[id]
    var state = light.state || {}
    var hasBri = typeof state.bri === "number"
    var hasCt = typeof state.ct === "number"
    var hasColor = typeof state.hue === "number" && typeof state.sat === "number"
    lights.push({
      id: String(id),
      name: String(light.name || "Light " + id),
      on: !!state.on,
      bri: hasBri ? Math.max(1, Math.min(254, state.bri)) : 0,
      hasBri: hasBri,
      ct: hasCt ? Math.max(153, Math.min(500, state.ct)) : 0,
      hasCt: hasCt,
      hue: hasColor ? state.hue : 0,
      sat: hasColor ? state.sat : 0,
      hasColor: hasColor,
      pickerOpen: false
    })
  }
  lights.sort(function(a, b) { return a.name.localeCompare(b.name) })
  return lights
}

function parseGroups(text) {
  var obj = parseJsonObject(text)
  if (!obj) return []
  var groups = []
  for (var id in obj) {
    if (!Object.prototype.hasOwnProperty.call(obj, id)) continue
    var group = obj[id]
    var type = String(group.type || "")
    if (type !== "Room") continue
    groups.push({
      id: String(id),
      name: String(group.name || "Group " + id),
      type: type,
      on: !!(group.state && group.state.any_on),
      allOn: !!(group.state && group.state.all_on),
      lightIds: Array.isArray(group.lights) ? group.lights.map(String) : []
    })
  }
  groups.sort(function(a, b) { return a.name.localeCompare(b.name) })
  return groups
}

function roomLights(room, byId) {
  var result = []
  for (var i = 0; i < room.lightIds.length; i++) {
    var light = byId[room.lightIds[i]]
    if (light) result.push(light)
  }
  return result
}
