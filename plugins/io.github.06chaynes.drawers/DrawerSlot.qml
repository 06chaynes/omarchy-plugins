import QtQuick
import qs.Commons
import qs.Ui

Item {
    id: slot

    required property var entry
    property var bar: null
    property var hostDrawer: null

    readonly property string moduleId: entry && entry.id ? String(entry.id) : ""
    readonly property var moduleSettings: entry && entry.settings ? entry.settings : ({})
    readonly property bool hasModule: moduleId.length > 0

    // Reading `widgets` — not just calling through it — is what creates the
    // binding dependency on registry mutation. Same trick as Bar.qml:1535-1539.
    readonly property var registryEntry: {
        if (!bar || !bar.barWidgetRegistry) return null
        var widgets = bar.barWidgetRegistry.widgets
        if (!widgets) return null
        return widgets[String(moduleId).trim()] || null
    }

    readonly property bool isRegistered: registryEntry !== null
    readonly property var activeItem: loader.item
    // Only paint the placeholder for an id we were asked for but cannot resolve.
    // An empty id (the idle satellite) must collapse to nothing instead.
    readonly property bool showFallback: hasModule && !isRegistered

    property bool hasAlert: false

    // Bar.qml:1044 gates the bar's tooltip surface to bar-window items, so a
    // tucked widget can never raise one. Held as an object reference rather
    // than re-walked per read, so the binding below tracks the widget's own
    // updates to its text.
    property var tooltipSource: null
    readonly property bool hovered: slotHover.hovered

    readonly property string tooltipText: {
        if (tooltipSource) {
            var live = String(tooltipSource.tooltipText || "")
            if (live.length > 0) return live
        }
        var meta = registryEntry ? registryEntry.metadata : null
        if (meta && meta.displayName) return String(meta.displayName)
        return moduleId
    }

    signal alertTriggered(string id)

    function injectProps() {
        var item = loader.item
        if (!item) return
        if ("bar" in item) item.bar = slot.bar
        if ("settings" in item) item.settings = slot.moduleSettings
        // Last and guarded: `"x" in item` is true for readonly properties too,
        // and assigning to one throws — which would abort the injections above.
        // Every shipped widget self-declares moduleName, so this only fills in
        // the Ui/BarWidget.qml default of "" and never clobbers a live binding.
        if ("moduleName" in item && !item.moduleName) {
            try { item.moduleName = slot.moduleId } catch (e) {}
        }
        repointPanels(item, 0)
        slot.tooltipSource = findTooltipSource(item, 0)
    }

    // Widgets declare tooltipText on an inner button, not on their root.
    function findTooltipSource(node, depth) {
        if (!node || depth > 4) return null
        var kids = node.data
        if (!kids || kids.length === undefined) return null
        for (var i = 0; i < kids.length; i++) {
            var child = kids[i]
            if (!child) continue
            try {
                if ("tooltipText" in child && String(child.tooltipText || "").length > 0) return child
            } catch (e) {}
            var deeper = findTooltipSource(child, depth + 1)
            if (deeper) return deeper
        }
        return null
    }

    // A tucked widget's own panel anchors to a button that now lives inside the
    // drawer's popup, so KeyboardPanel resolves `anchorItem.QsWindow.window` to
    // the popup instead of the bar surface and positions the panel against the
    // wrong geometry (PopupCard's `contentItem` is a list alias, which shows up
    // as a TypeError in anchorScreenPos). Re-point any panel we can reach at the
    // drawer's own bar-resident pill.
    //
    // Widgets re-run their panel injection on `bar`/`settings` changes — which
    // this very function triggers — so this has to run last, and again from the
    // Qt.callLater pass below.
    function repointPanels(node, depth) {
        if (!node || depth > 3) return
        var anchor = slot.hostDrawer && slot.hostDrawer.barAnchorItem
            ? slot.hostDrawer.barAnchorItem : null
        if (!anchor) return
        var kids = node.data
        if (!kids || kids.length === undefined) return
        for (var i = 0; i < kids.length; i++) {
            var child = kids[i]
            if (!child) continue
            try {
                if ("anchorItem" in child && child.anchorItem !== anchor) child.anchorItem = anchor
            } catch (e) {}
            repointPanels(child, depth + 1)
        }
    }

    // Size the slot to the widget, mirroring Bar.qml:1565-1568. Deliberately no
    // `visible:` binding: `visible: implicitWidth > 0` deadlocks, because an
    // invisible slot makes its child report visible === false, so the
    // measurement branch never runs. Positioners already skip zero-sized
    // children, so an empty slot collapses on its own.
    implicitWidth: !hasModule ? 0
                 : (isRegistered ? (activeItem && activeItem.visible ? activeItem.implicitWidth : 0)
                                 : Style.space(32))
    implicitHeight: !hasModule ? 0
                  : (isRegistered ? (activeItem && activeItem.visible ? activeItem.implicitHeight : 0)
                                  : Style.space(32))
    width: implicitWidth
    height: implicitHeight

    onActiveItemChanged: injectProps()
    onModuleSettingsChanged: injectProps()

    HoverHandler { id: slotHover }

    Loader {
        id: loader
        active: slot.isRegistered
        sourceComponent: slot.registryEntry ? slot.registryEntry.component : null
        anchors.fill: parent

        // Deferred as well as immediate: widgets re-inject their own panel
        // wiring on the settings change this very pass triggers.
        onLoaded: Qt.callLater(slot.injectProps)
    }

    // Satellite alerts. The shell's bar-widget base class carries no alert
    // concept, so the drawer defines one: a tucked widget signals attention by
    // exposing any of these boolean properties on its root. First one present
    // wins; a false -> true edge slides the widget out beside the pill.
    readonly property var alertProbe: {
        var item = loader.item
        if (!item) return false
        var names = ["hasAlert", "alert", "urgent", "attention", "needsAttention"]
        for (var i = 0; i < names.length; i++) {
            if (names[i] in item) return item[names[i]] === true
        }
        return false
    }

    onAlertProbeChanged: {
        if (alertProbe && !hasAlert) {
            hasAlert = true
            slot.alertTriggered(slot.moduleId)
        } else if (!alertProbe) {
            hasAlert = false
        }
    }

    // Placeholder for an id absent from the registry: plugin disabled or removed.
    BorderSurface {
        visible: slot.showFallback
        anchors.fill: parent
        radius: Style.cornerRadius
        color: Util.alpha(Color.foreground, 0.08)

        Text {
            anchors.centerIn: parent
            text: {
                if (slot.moduleId.indexOf("music") !== -1) return "󰝚"
                if (slot.moduleId.indexOf("retro") !== -1 || slot.moduleId.indexOf("game") !== -1) return "󰊖"
                if (slot.moduleId.indexOf("lantern") !== -1) return "󰒓"
                return slot.moduleId.charAt(0).toUpperCase()
            }
            font.family: Style.font.family
            font.pixelSize: Style.space(15)
            color: Color.foreground
        }
    }
}
