import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
    id: root

    moduleName: "io.github.06chaynes.drawers"

    // --- Configurable Settings -------------------------------------------
    readonly property string iconGlyph: settings && settings.icon ? String(settings.icon) : "󰉋"
    readonly property string labelText: settings && settings.label ? String(settings.label) : ""
    readonly property bool showLabel: settings && settings.showLabel === true
    readonly property string customTooltip: settings && settings.tooltip ? String(settings.tooltip) : ""
    readonly property string drawerLayout: settings && settings.layout ? String(settings.layout) : "row"
    readonly property int gridColumns: settings && settings.columns ? Math.max(1, Number(settings.columns)) : 2
    readonly property string alertMode: settings && settings.alertMode ? String(settings.alertMode) : "slideout"
    readonly property int alertDurationSec: settings && settings.alertDuration ? Math.max(2, Number(settings.alertDuration)) : 8
    // Stamped by drawer-config.py on first save so a second drawer instance
    // (allowMultiple is true) is addressable without guessing from its label.
    readonly property string drawerId: settings && settings.drawerId ? String(settings.drawerId) : ""
    readonly property var widgetList: Model.normalizeWidgetList(settings ? settings.widgets : null)

    // --- State & Popout Control ------------------------------------------
    property bool popupOpen: false

    property bool hasActiveAlert: false
    property string activeSatelliteId: ""
    property var tooltipSlot: null

    // Resolve the real entry so the slid-out copy gets the widget's settings
    // rather than an empty object.
    readonly property var activeSatelliteEntry: {
        if (activeSatelliteId === "") return null
        for (var i = 0; i < widgetList.length; i++) {
            if (widgetList[i].id === activeSatelliteId) return widgetList[i]
        }
        return null
    }

    readonly property bool opened: popupOpen

    // The bar exposes this item so tucked widgets can anchor their own panels
    // to the pill on the bar surface instead of to the drawer popup.
    readonly property Item barAnchorItem: mainButton

    function open() { popupOpen = true }
    function close() { popupOpen = false }
    function toggle() { popupOpen = !popupOpen }

    // Configuration is global and lives on the panel entry point, so the pill
    // asks for it the same way the Omarchy menu does. That keeps one manager
    // for every drawer instead of one per pill.
    function openManager() {
        close()
        managerProcess.running = false
        managerProcess.command = ["omarchy-shell", "io.github.06chaynes.drawers", "edit", root.drawerId]
        managerProcess.running = true
    }

    // True when `owner` lives inside this drawer's dropdown — i.e. the popout
    // being claimed belongs to one of our own tucked widgets.
    function hostsPopoutOwner(owner) {
        if (!owner) return false
        for (var node = owner; node; node = node.parent) {
            if (node === slotGrid) return true
        }
        return false
    }

    // Bar.qml's popout coordinator (Bar.qml:316-323) assumes every owner is a
    // peer on the bar, so a tucked widget opening its own panel asks us — its
    // host — to close. Defer one tick: the bar calls this *before* assigning
    // activePopout, so the incoming owner is only knowable next tick.
    function closeForPopoutSwitch() {
        Qt.callLater(root.resolvePopoutSwitch)
    }

    function resolvePopoutSwitch() {
        if (!popupOpen) return
        var owner = root.bar ? root.bar.activePopout : null
        if (hostsPopoutOwner(owner)) return
        root.close()
    }

    readonly property string buttonLabel: {
        var str = iconGlyph
        if (showLabel && labelText.length > 0) {
            str += " " + labelText
        }
        str += " " + (popupOpen ? "▴" : "▾")
        return str
    }

    function triggerSatelliteAlert(widgetId) {
        if (alertMode === "off") return
        hasActiveAlert = true
        if (alertMode === "slideout" && widgetId !== "") {
            activeSatelliteId = widgetId
        }
        // Armed for every mode that shows something: badge-only has no
        // slide-out to fold back, so without this the dot latches on forever.
        satelliteTimer.restart()
    }


    // --- IPC ------------------------------------------------------------

    // Diagnostic snapshot of what each slot resolved to. Answers "is the
    // widget live, or is this a placeholder tile?" without opening the drawer.
    function slotReport() {
        var out = []
        for (var i = 0; i < slotRepeater.count; i++) {
            var s = slotRepeater.itemAt(i)
            if (!s) continue
            out.push({
                id: s.moduleId,
                registered: s.isRegistered,
                live: s.activeItem !== null,
                width: Math.round(s.implicitWidth),
                height: Math.round(s.implicitHeight)
            })
        }
        return out
    }

    // Every drawer instance would otherwise claim the same IPC target and all
    // but one would be silently inert. Elect the first peer the bar knows
    // about; an empty list means the slots have not registered yet, so nobody
    // claims it and the losing-handler warning never fires.
    readonly property var ipcPeers: bar && typeof bar.moduleWidgets === "function"
        ? bar.moduleWidgets(moduleName) : []
    readonly property bool ownsIpc: ipcPeers.length > 0 && ipcPeers[0] === root

    IpcHandler {
        // Configuration lives on the panel entry point, which is loaded even
        // with no drawer on the bar. This target only drives the dropdowns.
        target: "io.github.06chaynes.drawers.bar"
        enabled: root.ownsIpc

        function open(): void { root.broadcast("open") }
        function close(): void { root.broadcast("close") }
        function toggle(): void { root.broadcast("toggle") }

        // One report per drawer on the bar, not just the electee's.
        function status(): string {
            var out = []
            for (var i = 0; i < root.ipcPeers.length; i++) {
                var peer = root.ipcPeers[i]
                out.push({
                    label: peer.labelText,
                    drawerId: peer.drawerId,
                    open: peer.popupOpen,
                    layout: peer.drawerLayout,
                    configured: peer.widgetList.length,
                    slots: peer.slotReport()
                })
            }
            return JSON.stringify(out)
        }
    }

    implicitWidth: layoutRow.implicitWidth
    implicitHeight: layoutRow.implicitHeight

    // A tucked widget that releases the popout slot leaves activePopout null
    // while our dropdown is still open, which would let the next bar widget
    // claim it without ever asking us to close. Re-claim it instead.
    Connections {
        target: root.bar
        ignoreUnknownSignals: true
        function onActivePopoutChanged() {
            if (!root.popupOpen) return
            if (root.bar && root.bar.activePopout === null) {
                root.bar.requestPopout(popup.coordinatorKey)
            }
        }
    }

    RowLayout {
        id: layoutRow
        spacing: Style.space(2)
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined

        // --- Main Drawer Button ------------------------------------------
        WidgetButton {
            id: mainButton
            bar: root.bar
            text: root.buttonLabel
            tooltipText: Model.formatTooltip(root.customTooltip, root.labelText, root.widgetList.length, root.hasActiveAlert) + " (Right-click to edit)"

            onPressed: function(buttonCode) {
                if (buttonCode === Qt.LeftButton) {
                    root.toggle()
                } else if (buttonCode === Qt.RightButton) {
                    root.openManager()
                }
            }

            // Alert indicator badge dot
            Rectangle {
                visible: root.hasActiveAlert && !root.popupOpen
                width: Style.space(6)
                height: Style.space(6)
                radius: width / 2
                color: Color.bar.active
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: Style.space(2)
            }
        }

        // --- Satellite Alert Slide-Out Slot ------------------------------
        Item {
            // Deliberately NO `visible:` binding. Gating visibility on width
            // deadlocks: an invisible container makes the hosted widget report
            // visible === false, so DrawerSlot's measurement branch never runs,
            // so the width stays 0 forever. A zero-width Item is already
            // skipped by the layout and paints nothing.
            implicitHeight: satelliteSlot.implicitHeight
            implicitWidth: satelliteSlot.implicitWidth
            clip: true

            width: root.activeSatelliteId !== "" ? satelliteSlot.implicitWidth : 0

            Behavior on width {
                NumberAnimation {
                    duration: 350
                    easing.type: Easing.OutCubic
                }
            }

            DrawerSlot {
                id: satelliteSlot
                entry: root.activeSatelliteEntry
                bar: root.bar
                hostDrawer: root
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    Timer {
        id: satelliteTimer
        interval: root.alertDurationSec * 1000
        repeat: false
        onTriggered: {
            root.activeSatelliteId = ""
            root.hasActiveAlert = false
        }
    }

    // --- Native Popout Dropdown Card -------------------------------------
    PopupCard {
        id: popup
        anchorItem: root
        bar: root.bar
        owner: root
        open: root.popupOpen
        triggerMode: "click"

        padding: Style.space(8)

        // Drive the card off measured content instead of a per-slot guess.
        // fittedContentWidth (PopupCard.qml:40-45) adds no insets, so padding
        // is added here; fittedContentHeight (:47-52) already adds
        // verticalContentInset, so height must not add it again.
        contentWidth: popup.fittedContentWidth(slotGrid.implicitWidth + popup.padding * 2)
        contentHeight: popup.fittedContentHeight(slotGrid.implicitHeight)

        // One positioner for both layouts. Two Repeaters (a visible Row and a
        // hidden Grid) would each instantiate the full slot set — `visible:
        // false` does not stop delegate creation — giving every tucked widget
        // two live instances, two IpcHandler registrations and two poll timers.
        // A Grid whose columns equal the item count lays out as a single row,
        // so switching layout re-flows without rebuilding the hosted widgets.
        Grid {
            id: slotGrid
            anchors.centerIn: parent
            spacing: Style.space(8)

            // The popup's content is laid out in the bar's scene even while the
            // popup is closed, at the bar's left edge (x=8,48,88,... y=10) --
            // invisible, but underneath the real icons and still hit-testable,
            // so a click in a gap of the workspace switcher lands on whichever
            // tucked widget occupies that x. Gating `enabled` does not help:
            // WidgetButton's own MouseArea carries `enabled: root.interactive`,
            // which defaults true.
            //
            // `visible` is what removes an item from hit-testing. Delegates are
            // still created (visible:false does not stop that), so the drawer's
            // widgets stay live -- only their input and painting stop.
            visible: root.popupOpen
            columns: root.drawerLayout === "grid"
                ? Math.max(1, root.gridColumns)
                : Math.max(1, root.widgetList.length + 1)

            Repeater {
                id: slotRepeater
                model: root.widgetList

                delegate: DrawerSlot {
                    id: slotDelegate
                    // Required. DrawerSlot declares `required property var
                    // entry`, which puts this delegate into required-property
                    // mode and removes the context `modelData`. Without this
                    // line `entry: modelData` raises a ReferenceError and every
                    // slot falls back to a placeholder tile. Same shape as
                    // Bar.qml:1499-1503.
                    required property var modelData

                    entry: modelData
                    bar: root.bar
                    hostDrawer: root
                    onAlertTriggered: function(id) { root.triggerSatelliteAlert(id) }
                    onHoveredChanged: {
                        if (hovered) root.tooltipSlot = slotDelegate
                        else if (root.tooltipSlot === slotDelegate) root.tooltipSlot = null
                    }
                }
            }

            // Quick add / edit tile
            BorderSurface {
                width: Style.space(32)
                height: Style.space(32)
                radius: Style.cornerRadius
                color: editHover.hovered ? Util.alpha(Color.foreground, 0.14) : Util.alpha(Color.foreground, 0.05)

                Text {
                    anchors.centerIn: parent
                    text: "+"
                    font.family: Style.font.family
                    font.pixelSize: Style.space(16)
                    font.weight: Font.Bold
                    color: editHover.hovered ? Color.accent : Util.alpha(Color.foreground, 0.6)
                }

                HoverHandler { id: editHover }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.close()
                        root.openManager()
                    }
                }
            }
        }
    }


    Timer {
        id: tooltipDelay
        interval: 400
        repeat: false
        onTriggered: root.tooltipVisible = root.tooltipSlot !== null && root.popupOpen
    }

    property bool tooltipVisible: false
    readonly property string tooltipBody: tooltipSlot ? String(tooltipSlot.tooltipText || "") : ""

    onTooltipSlotChanged: {
        if (tooltipSlot === null) {
            tooltipVisible = false
            tooltipDelay.stop()
        } else if (tooltipVisible) {
            // Sliding between neighbouring icons should retarget immediately
            // instead of replaying the open delay.
            tooltipDelay.stop()
        } else {
            tooltipDelay.restart()
        }
    }

    onPopupOpenChanged: if (!popupOpen) tooltipSlot = null

    PopupWindow {
        id: slotTooltip

        visible: root.tooltipVisible && root.tooltipSlot !== null && root.tooltipBody !== ""
        color: "transparent"
        implicitWidth: Math.ceil(tooltipBubble.implicitWidth)
        implicitHeight: Math.ceil(tooltipBubble.implicitHeight)

        anchor {
            id: tooltipAnchor
            // Anchored to the bar surface, not to the dropdown: a popup
            // anchored to another popup is positioned in that popup's tiny
            // coordinate space, which pushes the bubble off-surface. The bar
            // window is the common parent both the pill and the dropdown
            // resolve against.
            window: root.QsWindow.window
            adjustment: PopupAdjustment.Slide
            edges: Edges.Top | Edges.Left
            gravity: Edges.Bottom | Edges.Right
            rect.width: 1
            rect.height: 1

            onAnchoring: {
                var target = root.tooltipSlot
                if (!target) return
                var host = root.QsWindow.window
                if (!host) return
                var point = host.contentItem.mapFromItem(
                    target,
                    target.width / 2 - slotTooltip.implicitWidth / 2,
                    target.height + Style.space(6))
                tooltipAnchor.rect.x = Math.round(point.x)
                tooltipAnchor.rect.y = Math.round(point.y)
            }
        }

        BorderSurface {
            id: tooltipBubble
            anchors.fill: parent
            color: Color.tooltip.background
            borderSpec: Border.localOrSurfaceSpec("tooltip", "border", Color.tooltip.border, Color.tooltip.border, Style.normalBorderWidth)
            radius: Style.cornerRadius
            implicitWidth: tooltipLabel.implicitWidth
            implicitHeight: tooltipLabel.implicitHeight

            Text {
                id: tooltipLabel
                anchors.centerIn: parent
                text: root.tooltipBody
                color: Color.tooltip.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                leftPadding: Style.spacing.controlPaddingX
                rightPadding: Style.spacing.controlPaddingX
                topPadding: Style.spacing.controlPaddingY
                bottomPadding: Style.spacing.controlPaddingY
            }
        }
    }

    Process {
        id: managerProcess
        running: false
    }
}
