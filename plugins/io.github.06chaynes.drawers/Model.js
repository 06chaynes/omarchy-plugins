// shell.json values reach a widget's `settings` through QVariant, and a JSON
// array arrives as a Qt sequence wrapper rather than a true JS Array —
// `Array.isArray()` reports false on it even though it indexes and reports
// `length` correctly. Anything that inspects a settings array has to duck-type
// instead, or it silently sees an empty list.
function toArray(value) {
    if (!value) return []
    if (typeof value === "string") return []
    if (typeof value.length !== "number") return []
    // Always a fresh array, never the caller's own. Callers mutate the result
    // and assign it back to a `var` property to signal a change; handing back
    // the same object reference means QML sees no change and the UI never
    // updates.
    var out = []
    for (var i = 0; i < value.length; i++) out.push(value[i])
    return out
}

function normalizeWidgetList(raw) {
    var list = toArray(raw)
    var normalized = []
    var seen = {}
    for (var i = 0; i < list.length; i++) {
        var item = list[i]
        var id = ""
        var copy = {}
        if (typeof item === "string") {
            id = item.trim()
        } else if (item && typeof item === "object" && item.id) {
            id = String(item.id).trim()
            for (var k in item) {
                if (k !== "id") copy[k] = item[k]
            }
        }
        // A duplicate id would mount the same widget twice, giving it two live
        // IpcHandler registrations and two poll timers.
        if (id.length === 0 || seen[id]) continue
        seen[id] = true
        normalized.push({ id: id, settings: copy })
    }
    return normalized
}



function formatTooltip(customTooltip, label, widgetCount, hasAlert) {
    if (customTooltip && String(customTooltip).trim().length > 0) {
        return String(customTooltip).trim() + (hasAlert ? " · Alert active" : "")
    }
    var prefix = label && String(label).trim().length > 0 ? String(label).trim() : "Drawer"
    if (widgetCount === 0) {
        return prefix + " · Empty"
    }
    var base = prefix + " · " + widgetCount + " " + (widgetCount === 1 ? "item" : "items")
    return hasAlert ? base + " · Alert active" : base
}
