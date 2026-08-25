import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Global drawer manager: every drawer on the bar, on the left; the selected
// drawer's contents, on the right.
//
// Everything is staged. Adding a drawer, removing one, renaming, and moving
// widgets between drawers all edit a local copy, and Save Changes reconciles
// the whole set in one atomic write. Nothing reaches shell.json before that.
Item {
    id: root

    property string helperScript: ""
    property string focusDrawerId: ""

    signal autoArrangeRequested()
    signal closeRequested()

    property var allPlugins: []
    property bool loaded: false
    property bool reading: false
    property bool writing: false
    readonly property bool busy: reading || writing
    property string errorText: ""
    property string statusText: ""

    // `staged` is the editable copy; `savedSnapshot` is what was loaded, kept only
    // to tell whether anything actually changed.
    property var staged: []
    property string savedSnapshot: "[]"
    property string selectedKey: ""
    property int newDrawerSeq: 0
    property string searchQuery: ""

    readonly property bool dirty: JSON.stringify(snapshot(staged)) !== savedSnapshot

    function snapshot(list) {
        var out = []
        for (var i = 0; i < list.length; i++) {
            var e = list[i]
            out.push({ drawerId: e.drawerId, label: e.label, icon: e.icon,
                       layout: e.layout, section: e.section, widgets: e.widgets })
        }
        return out
    }

    readonly property var selectedEntry: {
        for (var i = 0; i < staged.length; i++) {
            if (staged[i].key === selectedKey) return staged[i]
        }
        return null
    }

    readonly property var filteredPlugins: {
        var query = searchQuery.toLowerCase().trim()
        var list = Model.toArray(allPlugins)
        if (!query) return list
        var out = []
        for (var i = 0; i < list.length; i++) {
            var p = list[i]
            if ((p.name || "").toLowerCase().indexOf(query) !== -1
                || (p.id || "").toLowerCase().indexOf(query) !== -1
                || (p.category || "").toLowerCase().indexOf(query) !== -1) out.push(p)
        }
        return out
    }

    // Staged, so moving a widget out of one drawer and into another lands in a
    // single commit rather than needing two saves.
    function holderOf(id) {
        for (var i = 0; i < staged.length; i++) {
            if (staged[i].key === selectedKey) continue
            if (Model.toArray(staged[i].widgets).indexOf(id) !== -1) return staged[i].label || "another drawer"
        }
        return ""
    }

    function isSelected(id) {
        return selectedEntry ? Model.toArray(selectedEntry.widgets).indexOf(id) !== -1 : false
    }

    function updateSelected(field, value) {
        var next = []
        for (var i = 0; i < staged.length; i++) {
            var e = staged[i]
            if (e.key !== selectedKey) { next.push(e); continue }
            var copy = {}
            for (var k in e) copy[k] = e[k]
            copy[field] = value
            next.push(copy)
        }
        staged = next
    }

    function toggleWidget(id) {
        if (!selectedEntry || holderOf(id) !== "") return
        var ids = Model.toArray(selectedEntry.widgets)
        var index = ids.indexOf(id)
        if (index === -1) ids.push(id)
        else ids.splice(index, 1)
        updateSelected("widgets", ids)
    }

    function selectDrawer(key) {
        selectedKey = String(key || "")
        var found = selectedEntry
        iconField.text = found ? found.icon : ""
        labelField.text = found ? found.label : ""
    }

    function addDrawer() {
        newDrawerSeq++
        var next = Model.toArray(staged)
        var key = "new:" + newDrawerSeq
        next.push({ key: key, drawerId: "", label: "New drawer", icon: "\u{F024B}",
                    layout: "row", section: "center", widgets: [] })
        staged = next
        selectDrawer(key)
    }

    function removeDrawer(key) {
        var next = []
        for (var i = 0; i < staged.length; i++) {
            if (staged[i].key !== key) next.push(staged[i])
        }
        staged = next
        if (selectedKey === key) selectDrawer(next.length ? next[0].key : "")
    }

    function reload(preferKey) {
        errorText = ""
        reading = true
        stateProcess.preferKey = String(preferKey || selectedKey || focusDrawerId || "")
        stateProcess.running = false
        stateProcess.command = [helperScript, "get-state"]
        stateProcess.running = true
    }

    function save() {
        if (busy) return
        errorText = ""
        statusText = ""
        writing = true
        writeProcess.running = false
        writeProcess.command = [helperScript, "apply-drawers", "--payload",
                                JSON.stringify({ drawers: snapshot(staged) })]
        writeProcess.running = true
    }

    function revert() { reload() }

    Component.onCompleted: reload()

    // The wizard changes the bar behind this view's back, so re-read whenever
    // it comes forward. Skipped while there are staged edits a reload would
    // silently discard.
    onVisibleChanged: if (visible && !dirty) reload()

    Process {
        id: stateProcess
        property string preferKey: ""
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.reading = false
                var result = null
                try { result = JSON.parse(text) } catch (e) { result = null }
                if (!result || !result.ok) {
                    root.errorText = result && result.error
                        ? String(result.error) : "Could not read the drawer configuration."
                    return
                }
                root.allPlugins = result.plugins || []

                var next = []
                var list = Model.toArray(result.drawers)
                for (var i = 0; i < list.length; i++) {
                    var d = list[i]
                    var ids = []
                    var widgets = Model.toArray(d.widgets)
                    for (var j = 0; j < widgets.length; j++) ids.push(widgets[j].id)
                    next.push({ key: d.drawerId, drawerId: d.drawerId, label: d.label,
                                icon: d.icon, layout: d.layout, section: d.section, widgets: ids })
                }
                root.staged = next
                root.savedSnapshot = JSON.stringify(root.snapshot(next))
                root.loaded = true

                var want = stateProcess.preferKey
                var exists = false
                for (var k = 0; k < next.length; k++) if (next[k].key === want) exists = true
                root.selectDrawer(exists ? want : (next.length ? next[0].key : ""))
            }
        }
        stderr: StdioCollector { waitForEnd: true }
        onRunningChanged: {
            // A spawn that fails outright never reaches stdout, so the flag has
            // to be cleared here or the view wedges on "Loading".
            if (running || !root.reading) return
            root.reading = false
            if (root.errorText === "") root.errorText = "The drawer helper could not be started."
        }
    }

    Process {
        id: writeProcess
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var result = null
                try { result = JSON.parse(text) } catch (e) { result = null }
                // Cleared before the reload below, which arms `reading`.
                root.writing = false
                if (result && result.ok) {
                    root.statusText = "Saved. Restart the shell to see it on the bar."
                    root.reload()
                } else {
                    root.errorText = result && result.error
                        ? String(result.error) : "The change was not saved."
                }
            }
        }
        stderr: StdioCollector { waitForEnd: true }
        onRunningChanged: {
            if (running || !root.writing) return
            root.writing = false
            if (root.errorText === "") root.errorText = "The drawer helper could not be started."
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(14)
        spacing: Style.space(10)

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.space(12)

            // --- Drawer list ---------------------------------------------
            ColumnLayout {
                Layout.preferredWidth: Style.space(210)
                Layout.fillHeight: true
                spacing: Style.space(6)

                Text {
                    text: "Drawers (" + root.staged.length + ")"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.weight: Font.Bold
                    color: Color.foreground
                }

                Flickable {
                    id: listScroll
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentWidth: width
                    contentHeight: listColumn.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: contentHeight > height
                    QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

                    ColumnLayout {
                        id: listColumn
                        width: listScroll.width
                        spacing: Style.space(4)

                        Repeater {
                            model: root.staged

                            delegate: BorderSurface {
                                id: drawerRow
                                required property var modelData
                                readonly property bool current: modelData.key === root.selectedKey

                                Layout.fillWidth: true
                                implicitHeight: Style.space(40)
                                radius: Style.cornerRadius
                                color: current ? Util.alpha(Color.accent, 0.18) : Util.alpha(Color.foreground, 0.04)
                                borderSpec: current ? Border.flat(Color.accent, 1) : Border.flat(Color.popups.border, 1)

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.margins: Style.space(8)
                                    spacing: Style.space(8)

                                    Text {
                                        text: drawerRow.modelData.icon
                                        font.family: Style.font.family
                                        font.pixelSize: Style.font.icon
                                        color: drawerRow.current ? Color.accent : Color.foreground
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 0
                                        Text {
                                            Layout.fillWidth: true
                                            text: drawerRow.modelData.label.length > 0
                                                ? drawerRow.modelData.label : "Untitled"
                                            font.family: Style.font.family
                                            font.pixelSize: Style.font.body
                                            font.weight: drawerRow.current ? Font.Bold : Font.Normal
                                            color: drawerRow.current ? Color.accent : Color.foreground
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            text: Model.toArray(drawerRow.modelData.widgets).length + " · "
                                                  + drawerRow.modelData.section
                                                  + (drawerRow.modelData.drawerId ? "" : " · new")
                                            font.family: Style.font.family
                                            font.pixelSize: Style.font.caption
                                            color: Util.alpha(Color.foreground, 0.55)
                                        }
                                    }

                                    Text {
                                        text: "✕"
                                        font.family: Style.font.family
                                        font.pixelSize: Style.font.caption
                                        color: Util.alpha(Color.foreground, 0.5)

                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.margins: -Style.space(5)
                                            cursorShape: Qt.PointingHandCursor
                                            enabled: !root.busy
                                            onClicked: root.removeDrawer(drawerRow.modelData.key)
                                        }
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    anchors.rightMargin: Style.space(24)
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.selectDrawer(drawerRow.modelData.key)
                                }
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: root.loaded && root.staged.length === 0
                            text: "No drawers yet. Create one, or let Auto-arrange propose some."
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            color: Util.alpha(Color.foreground, 0.55)
                            wrapMode: Text.WordWrap
                        }
                    }
                }

                Button {
                    Layout.fillWidth: true
                    text: "+  New drawer"
                    bordered: true
                    enabled: !root.busy
                    onClicked: root.addDrawer()
                }

                Button {
                    Layout.fillWidth: true
                    text: "󰉋  Auto-arrange…"
                    bordered: true
                    onClicked: root.autoArrangeRequested()
                }
            }

            // --- Editor --------------------------------------------------
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Style.space(8)
                enabled: root.selectedEntry !== null
                opacity: enabled ? 1.0 : 0.4

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(8)

                    ColumnLayout {
                        spacing: Style.space(2)
                        Text {
                            text: "Icon"
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            color: Util.alpha(Color.foreground, 0.6)
                        }
                        RowLayout {
                            spacing: Style.space(4)

                            TextField {
                                id: iconField
                                implicitWidth: Style.space(60)
                                font.pixelSize: Style.font.icon
                                horizontalAlignment: Text.AlignHCenter
                                onTextChanged: {
                                    if (!root.selectedEntry || text === root.selectedEntry.icon) return
                                    root.updateSelected("icon", text)
                                }
                            }

                            Button {
                                text: "▾"
                                bordered: true
                                onClicked: iconPicker.show(root.selectedEntry ? root.selectedEntry.icon : "")
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(2)
                        Text {
                            text: "Label"
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            color: Util.alpha(Color.foreground, 0.6)
                        }
                        TextField {
                            id: labelField
                            Layout.fillWidth: true
                            placeholderText: "e.g. Media, Dev Tools, System…"
                            onTextChanged: {
                                if (!root.selectedEntry || text === root.selectedEntry.label) return
                                root.updateSelected("label", text)
                            }
                        }
                    }

                    ColumnLayout {
                        spacing: Style.space(2)
                        Text {
                            text: "Layout"
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            color: Util.alpha(Color.foreground, 0.6)
                        }
                        Button {
                            text: root.selectedEntry && root.selectedEntry.layout === "grid" ? "Grid" : "Row"
                            bordered: true
                            onClicked: {
                                if (!root.selectedEntry) return
                                root.updateSelected("layout",
                                    root.selectedEntry.layout === "grid" ? "row" : "grid")
                            }
                        }
                    }
                }

                Text {
                    text: "In this drawer (" + (root.selectedEntry ? Model.toArray(root.selectedEntry.widgets).length : 0) + ")"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.weight: Font.Bold
                    color: Color.foreground
                }

                Flickable {
                    Layout.fillWidth: true
                    implicitHeight: Style.space(34)
                    contentWidth: chipsRow.implicitWidth
                    contentHeight: height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: contentWidth > width

                    Row {
                        id: chipsRow
                        spacing: Style.space(6)

                        Repeater {
                            model: root.selectedEntry ? Model.toArray(root.selectedEntry.widgets) : []

                            delegate: BorderSurface {
                                id: chip
                                required property var modelData

                                readonly property string chipName: {
                                    var list = Model.toArray(root.allPlugins)
                                    for (var i = 0; i < list.length; i++)
                                        if (list[i].id === chip.modelData) return list[i].name
                                    return chip.modelData
                                }

                                implicitWidth: chipContent.implicitWidth + Style.space(9) + Style.space(9)
                                implicitHeight: Style.space(28)
                                radius: Style.cornerRadius
                                color: Util.alpha(Color.accent, 0.2)
                                borderSpec: Border.flat(Color.accent, 1)

                                Row {
                                    id: chipContent
                                    anchors.centerIn: parent
                                    spacing: Style.space(6)

                                    Text {
                                        text: chip.chipName
                                        font.family: Style.font.family
                                        font.pixelSize: Style.font.caption
                                        color: Color.foreground
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    Text {
                                        text: "✕"
                                        font.family: Style.font.family
                                        font.pixelSize: Style.font.caption
                                        font.weight: Font.Bold
                                        color: Color.accent
                                        anchors.verticalCenter: parent.verticalCenter

                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.margins: -Style.space(4)
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.toggleWidget(chip.modelData)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Text {
                        visible: !root.selectedEntry || Model.toArray(root.selectedEntry.widgets).length === 0
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.loaded ? "Empty — pick widgets below." : "Loading…"
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        color: Util.alpha(Color.foreground, 0.5)
                    }
                }

                TextField {
                    Layout.fillWidth: true
                    placeholderText: "Search available widgets…"
                    onTextChanged: root.searchQuery = text
                }

                Flickable {
                    id: catalogueScroll
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentWidth: width
                    contentHeight: catalogueGrid.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: contentHeight > height
                    QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

                    GridLayout {
                        id: catalogueGrid
                        width: catalogueScroll.width
                        columns: 2
                        rowSpacing: Style.space(6)
                        columnSpacing: Style.space(6)

                        Repeater {
                            model: root.filteredPlugins

                            delegate: BorderSurface {
                                id: card
                                required property var modelData

                                readonly property bool picked: root.isSelected(card.modelData.id)
                                readonly property string heldBy: root.holderOf(card.modelData.id)
                                readonly property bool blocked: heldBy !== ""

                                Layout.fillWidth: true
                                implicitHeight: Style.space(46)
                                radius: Style.cornerRadius
                                opacity: blocked ? 0.45 : 1.0
                                color: picked ? Util.alpha(Color.accent, 0.22) : Util.alpha(Color.foreground, 0.04)
                                borderSpec: picked ? Border.flat(Color.accent, 1.5) : Border.flat(Color.popups.border, 1)

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.margins: Style.space(8)
                                    spacing: Style.space(8)

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: Style.space(1)

                                        Text {
                                            Layout.fillWidth: true
                                            text: card.modelData.name
                                            font.family: Style.font.family
                                            font.pixelSize: Style.font.body
                                            font.weight: card.picked ? Font.Bold : Font.Normal
                                            color: card.picked ? Color.accent : Color.foreground
                                            elide: Text.ElideRight
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            text: card.blocked
                                                ? "in " + card.heldBy
                                                : (card.modelData.category || card.modelData.id)
                                            font.family: Style.font.family
                                            font.pixelSize: Style.font.caption
                                            color: Util.alpha(Color.foreground, 0.6)
                                            elide: Text.ElideRight
                                        }
                                    }

                                    Text {
                                        text: card.picked ? "✓" : (card.blocked ? "󰌾" : "+")
                                        font.family: Style.font.family
                                        font.pixelSize: Style.font.body
                                        font.weight: Font.Bold
                                        color: card.picked ? Color.accent : Util.alpha(Color.foreground, 0.4)
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: card.blocked ? Qt.ArrowCursor : Qt.PointingHandCursor
                                    enabled: !card.blocked
                                    onClicked: root.toggleWidget(card.modelData.id)
                                }
                            }
                        }
                    }
                }
            }
        }

        // --- Footer ------------------------------------------------------
        RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
                Layout.fillWidth: true
                text: root.errorText.length > 0 ? root.errorText
                    : (root.dirty ? "Unsaved changes" : root.statusText)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: root.errorText.length > 0 ? Color.urgent
                    : (root.dirty ? Color.accent : Util.alpha(Color.foreground, 0.65))
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
            }

            Button {
                text: "Discard"
                enabled: !root.busy && root.dirty
                opacity: enabled ? 1.0 : 0.5
                onClicked: root.revert()
            }

            Button {
                text: "Close"
                onClicked: root.closeRequested()
            }

            Button {
                text: root.busy ? "Working…" : (root.dirty ? "Save Changes •" : "Save Changes")
                bordered: true
                enabled: !root.busy && root.dirty
                opacity: enabled ? 1.0 : 0.5
                onClicked: root.save()
            }
        }
    }

    IconPicker {
        id: iconPicker
        anchors.fill: parent
        onPicked: function(glyph) {
            iconField.text = glyph
            root.updateSelected("icon", glyph)
        }
    }
}
