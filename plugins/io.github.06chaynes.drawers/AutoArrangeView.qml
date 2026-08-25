import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Two-step Auto-Drawer flow: preferences, then a proposal you edit before
// adopting. Adoption only ever ADDS drawers — anything already tucked by hand
// is never re-proposed and never moved.
Item {
    id: root

    property string helperScript: ""

    signal closeRequested()
    signal adopted()

    // --- Preferences -----------------------------------------------------
    property var sections: ["left", "center", "right"]
    property int minGroupSize: 2
    property int maxDrawers: 4
    property var pinned: []

    // --- Analysis + staged edits -----------------------------------------
    property var analysis: null
    property var overrides: ({})
    property int step: 0
    property bool analyzing: false
    property bool adopting: false
    property string errorText: ""

    readonly property var proposal: analysis && analysis.proposal ? Model.toArray(analysis.proposal) : []
    readonly property var skipped: analysis && analysis.skipped ? Model.toArray(analysis.skipped) : []
    readonly property var onBar: analysis && analysis.onBar ? Model.toArray(analysis.onBar) : []

    readonly property var pluginNames: {
        var names = ({})
        var list = analysis && analysis.plugins ? Model.toArray(analysis.plugins) : []
        for (var i = 0; i < list.length; i++) names[list[i].id] = list[i].name
        return names
    }

    function displayName(id) { return pluginNames[id] ? pluginNames[id] : id }

    // --- Overrides -------------------------------------------------------
    // The Repeater's model is the untouched analysis, so editing never rebuilds
    // the delegates and never steals focus from a field mid-keystroke.
    function overrideFor(key) {
        var found = overrides[key]
        return found ? found : { include: true, label: null, icon: null, excluded: [] }
    }

    function setOverride(key, field, value) {
        var next = ({})
        for (var k in overrides) next[k] = overrides[k]
        var current = overrideFor(key)
        var copy = { include: current.include, label: current.label, icon: current.icon,
                     excluded: Model.toArray(current.excluded) }
        copy[field] = value
        next[key] = copy
        overrides = next
    }

    function groupIncluded(key) { return overrideFor(key).include !== false }
    function widgetExcluded(key, id) { return Model.toArray(overrideFor(key).excluded).indexOf(id) !== -1 }

    function toggleWidget(key, id) {
        var excluded = Model.toArray(overrideFor(key).excluded)
        var index = excluded.indexOf(id)
        if (index === -1) excluded.push(id)
        else excluded.splice(index, 1)
        setOverride(key, "excluded", excluded)
    }

    function groupLabel(group) {
        var over = overrideFor(group.key)
        return over.label !== null && over.label !== undefined ? over.label : String(group.label || "")
    }

    function groupIcon(group) {
        var over = overrideFor(group.key)
        return over.icon !== null && over.icon !== undefined ? over.icon : String(group.icon || "")
    }

    function includedWidgets(group) {
        var out = []
        var list = Model.toArray(group.widgets)
        for (var i = 0; i < list.length; i++) {
            if (!widgetExcluded(group.key, list[i].id)) out.push(list[i].id)
        }
        return out
    }

    function groupAdopted(group) {
        return groupIncluded(group.key) && includedWidgets(group).length > 0
    }

    readonly property int adoptDrawerCount: {
        var count = 0
        for (var i = 0; i < proposal.length; i++) if (groupAdopted(proposal[i])) count++
        return count
    }

    readonly property int adoptWidgetCount: {
        var count = 0
        for (var i = 0; i < proposal.length; i++) {
            if (groupAdopted(proposal[i])) count += includedWidgets(proposal[i]).length
        }
        return count
    }

    // --- Preference toggles ----------------------------------------------
    function sectionEnabled(name) { return Model.toArray(sections).indexOf(name) !== -1 }

    function toggleSection(name) {
        var next = Model.toArray(sections)
        var index = next.indexOf(name)
        if (index === -1) next.push(name)
        else next.splice(index, 1)
        sections = next
        scheduleAnalyze()
    }

    function isPinned(id) { return Model.toArray(pinned).indexOf(id) !== -1 }

    function togglePinned(id) {
        var next = Model.toArray(pinned)
        var index = next.indexOf(id)
        if (index === -1) next.push(id)
        else next.splice(index, 1)
        pinned = next
        scheduleAnalyze()
    }

    function scheduleAnalyze() {
        if (step !== 0) return
        analyzeDebounce.restart()
    }

    function runAnalyze() {
        errorText = ""
        // Cleared before the stop so the restart's own running -> false
        // transition does not read as a failed spawn.
        analyzing = false
        var prefs = {
            "sections": Model.toArray(sections),
            "minGroupSize": minGroupSize,
            "maxDrawers": maxDrawers,
            "pinned": Model.toArray(pinned)
        }
        analyzeProcess.running = false
        analyzeProcess.command = [helperScript, "analyze", "--prefs", JSON.stringify(prefs)]
        analyzing = true
        analyzeProcess.running = true
    }

    function goToProposal() {
        if (analyzing || proposal.length === 0) return
        // A debounce still pending would land on step 1 and wipe the edits the
        // user is about to make.
        analyzeDebounce.stop()
        step = 1
    }

    function adopt() {
        if (adopting || analyzing || adoptDrawerCount === 0) return
        errorText = ""
        adopting = true

        var drawers = []
        for (var i = 0; i < proposal.length; i++) {
            var group = proposal[i]
            if (!groupAdopted(group)) continue
            var label = String(groupLabel(group))
            drawers.push({
                "label": label,
                "icon": String(groupIcon(group)),
                "section": group.section,
                "layout": "row",
                "showLabel": label.length > 0,
                "widgets": includedWidgets(group)
            })
        }

        adoptProcess.running = false
        adoptProcess.command = [helperScript, "apply-auto", "--payload", JSON.stringify({ "drawers": drawers })]
        adoptProcess.running = true
    }

    Component.onCompleted: runAnalyze()

    // Re-analyze only when there is nothing to show — after an adopt, or a
    // failed first read. Anything already loaded is the user's working state.
    onVisibleChanged: if (visible && !analysis && !analyzing) runAnalyze()

    Timer {
        id: analyzeDebounce
        interval: 200
        repeat: false
        onTriggered: root.runAnalyze()
    }

    Process {
        id: analyzeProcess
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                // Restarting the process kills the in-flight run and delivers
                // an empty stream; that is a supersession, not a failure.
                if (!text || String(text).length === 0) return
                root.analyzing = false
                var result = null
                try { result = JSON.parse(text) } catch (e) { result = null }
                if (!result || !result.ok) {
                    root.errorText = result && result.error
                        ? String(result.error) : "Could not read the current bar layout."
                    return
                }
                root.analysis = result
                root.overrides = ({})
            }
        }
        stderr: StdioCollector { waitForEnd: true }
        onRunningChanged: {
            if (running || !root.analyzing) return
            root.analyzing = false
            if (root.errorText === "") root.errorText = "The drawer helper could not be started."
        }
    }

    Process {
        id: adoptProcess
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var result = null
                try { result = JSON.parse(text) } catch (e) { result = null }
                root.adopting = false
                if (result && result.ok) {
                    // The bar it was analyzing no longer exists. Drop the
                    // proposal so coming back here re-reads rather than
                    // offering to tuck widgets that are already tucked.
                    root.analysis = null
                    root.overrides = ({})
                    root.step = 0
                    root.adopted()
                } else {
                    root.errorText = result && result.error
                        ? String(result.error) : "Adopting the proposal failed — nothing was changed."
                }
            }
        }
        stderr: StdioCollector { waitForEnd: true }
        onRunningChanged: {
            if (running || !root.adopting) return
            root.adopting = false
            if (root.errorText === "") root.errorText = "The drawer helper could not be started."
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(14)
        spacing: Style.space(10)

        // --- Header ------------------------------------------------------
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            Text {
                text: root.step === 0 ? "Auto-Drawer" : "Proposed Drawers"
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
                font.weight: Font.Bold
                color: Color.foreground
            }

            Text {
                text: root.step === 0
                    ? (root.analyzing ? "Reading the bar…"
                                      : root.onBar.length + " widgets on your bar · " + root.proposal.length + " groups found")
                    : root.adoptDrawerCount + " drawers · " + root.adoptWidgetCount + " widgets tucked · "
                      + (root.onBar.length - root.adoptWidgetCount) + " stay on the bar"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: Util.alpha(Color.foreground, 0.6)
            }
        }

        // --- Preferences ------------------------------------------------
        Flickable {
            id: prefsScroll
            visible: root.step === 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: prefsColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

            ColumnLayout {
                id: prefsColumn
                width: prefsScroll.width
                spacing: Style.space(12)

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(4)
                    Text {
                        text: "Sections to reorganize"
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.weight: Font.Bold
                        color: Color.foreground
                    }
                    RowLayout {
                        spacing: Style.space(6)
                        Repeater {
                            model: ["left", "center", "right"]
                            delegate: Button {
                                required property var modelData
                                text: modelData
                                bordered: true
                                selected: root.sectionEnabled(modelData)
                                onClicked: root.toggleSection(modelData)
                            }
                        }
                        Item { Layout.fillWidth: true }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(16)

                    ColumnLayout {
                        spacing: Style.space(4)
                        Text {
                            text: "Minimum widgets per drawer"
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            font.weight: Font.Bold
                            color: Color.foreground
                        }
                        RowLayout {
                            spacing: Style.space(6)
                            Repeater {
                                model: [2, 3, 4, 5]
                                delegate: Button {
                                    required property var modelData
                                    text: String(modelData)
                                    bordered: true
                                    selected: root.minGroupSize === modelData
                                    onClicked: { root.minGroupSize = modelData; root.scheduleAnalyze() }
                                }
                            }
                        }
                    }

                    ColumnLayout {
                        spacing: Style.space(4)
                        Text {
                            text: "Maximum drawers"
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            font.weight: Font.Bold
                            color: Color.foreground
                        }
                        RowLayout {
                            spacing: Style.space(6)
                            Repeater {
                                model: [2, 3, 4, 6, 8]
                                delegate: Button {
                                    required property var modelData
                                    text: String(modelData)
                                    bordered: true
                                    selected: root.maxDrawers === modelData
                                    onClicked: { root.maxDrawers = modelData; root.scheduleAnalyze() }
                                }
                            }
                        }
                    }

                    Item { Layout.fillWidth: true }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(4)

                    Text {
                        text: "Always keep on the bar"
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.weight: Font.Bold
                        color: Color.foreground
                    }
                    Text {
                        Layout.fillWidth: true
                        text: "Tap a widget to keep it out of every drawer. The bar's center anchor is always kept."
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        color: Util.alpha(Color.foreground, 0.5)
                        wrapMode: Text.WordWrap
                    }

                    Flow {
                        Layout.fillWidth: true
                        spacing: Style.space(6)

                        Repeater {
                            model: root.onBar

                            delegate: BorderSurface {
                                id: pinChip
                                required property var modelData
                                readonly property bool pinnedNow: root.isPinned(pinChip.modelData.id)

                                implicitWidth: pinLabel.implicitWidth + Style.space(10) + Style.space(10)
                                implicitHeight: Style.space(26)
                                radius: Style.cornerRadius
                                color: pinnedNow ? Util.alpha(Color.accent, 0.22) : Util.alpha(Color.foreground, 0.05)
                                borderSpec: pinnedNow ? Border.flat(Color.accent, 1) : Border.flat(Color.popups.border, 1)

                                Text {
                                    id: pinLabel
                                    anchors.centerIn: parent
                                    text: (pinChip.pinnedNow ? "󰐃 " : "") + root.displayName(pinChip.modelData.id)
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                    color: pinChip.pinnedNow ? Color.accent : Util.alpha(Color.foreground, 0.8)
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.togglePinned(pinChip.modelData.id)
                                }
                            }
                        }
                    }
                }
            }
        }

        // --- Proposal ----------------------------------------------------
        Flickable {
            id: proposalScroll
            visible: root.step === 1
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: proposalColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

            ColumnLayout {
                id: proposalColumn
                width: proposalScroll.width
                spacing: Style.space(8)

                Repeater {
                    model: root.proposal

                    delegate: BorderSurface {
                        id: groupCard
                        required property var modelData
                        readonly property bool adopted: root.groupAdopted(groupCard.modelData)
                        readonly property bool included: root.groupIncluded(groupCard.modelData.key)

                        Layout.fillWidth: true
                        implicitHeight: groupBody.implicitHeight + Style.space(20)
                        radius: Style.cornerRadius
                        color: adopted ? Util.alpha(Color.accent, 0.10) : Util.alpha(Color.foreground, 0.03)
                        borderSpec: adopted ? Border.flat(Color.accent, 1) : Border.flat(Color.popups.border, 1)
                        opacity: adopted ? 1.0 : 0.55

                        ColumnLayout {
                            id: groupBody
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Style.space(10)
                            spacing: Style.space(6)

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Style.space(8)

                                TextField {
                                    id: groupIconField
                                    implicitWidth: Style.space(56)
                                    font.pixelSize: Style.font.icon
                                    horizontalAlignment: Text.AlignHCenter
                                    // Seeded, not bound: binding `text` to the
                                    // override this field writes is a loop.
                                    Component.onCompleted: text = root.groupIcon(groupCard.modelData)
                                    onTextChanged: root.setOverride(groupCard.modelData.key, "icon", text)

                                    Connections {
                                        target: iconPicker
                                        function onPicked(glyph) {
                                            if (iconPicker.forKey !== groupCard.modelData.key) return
                                            groupIconField.text = glyph
                                        }
                                    }
                                }

                                Button {
                                    text: "▾"
                                    bordered: true
                                    onClicked: {
                                        iconPicker.forKey = groupCard.modelData.key
                                        iconPicker.show(root.groupIcon(groupCard.modelData))
                                    }
                                }

                                TextField {
                                    Layout.fillWidth: true
                                    placeholderText: "Drawer name"
                                    Component.onCompleted: text = root.groupLabel(groupCard.modelData)
                                    onTextChanged: root.setOverride(groupCard.modelData.key, "label", text)
                                }

                                Text {
                                    text: groupCard.modelData.section
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                    color: Util.alpha(Color.foreground, 0.5)
                                }

                                Button {
                                    text: groupCard.included ? "Skip" : "Include"
                                    bordered: true
                                    onClicked: root.setOverride(groupCard.modelData.key, "include", !groupCard.included)
                                }
                            }

                            Flow {
                                Layout.fillWidth: true
                                spacing: Style.space(6)

                                Repeater {
                                    model: Model.toArray(groupCard.modelData.widgets)

                                    delegate: BorderSurface {
                                        id: memberChip
                                        required property var modelData
                                        readonly property bool dropped:
                                            root.widgetExcluded(groupCard.modelData.key, memberChip.modelData.id)

                                        implicitWidth: memberLabel.implicitWidth + Style.space(10) + Style.space(10)
                                        implicitHeight: Style.space(24)
                                        radius: Style.cornerRadius
                                        color: dropped ? "transparent" : Util.alpha(Color.foreground, 0.08)
                                        borderSpec: Border.flat(dropped ? Util.alpha(Color.foreground, 0.3) : Color.popups.border, 1)

                                        Text {
                                            id: memberLabel
                                            anchors.centerIn: parent
                                            text: memberChip.modelData.name + (memberChip.dropped ? "  ↩" : "  ✕")
                                            font.family: Style.font.family
                                            font.pixelSize: Style.font.caption
                                            color: memberChip.dropped ? Util.alpha(Color.foreground, 0.45) : Color.foreground
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.toggleWidget(groupCard.modelData.key, memberChip.modelData.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(4)
                    visible: root.skipped.length > 0
                    text: "Staying on the bar"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.weight: Font.Bold
                    color: Util.alpha(Color.foreground, 0.7)
                }

                Repeater {
                    model: root.skipped
                    delegate: Text {
                        required property var modelData
                        Layout.fillWidth: true
                        text: "· " + root.displayName(modelData.id) + " — " + modelData.reason
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        color: Util.alpha(Color.foreground, 0.5)
                        elide: Text.ElideRight
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
                visible: root.errorText.length > 0
                text: root.errorText
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: Color.urgent
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
            }

            Item { Layout.fillWidth: true; visible: root.errorText.length === 0 }

            Button {
                visible: root.step === 1
                text: "← Back"
                enabled: !root.adopting
                onClicked: root.step = 0
            }

            Button {
                text: "Cancel"
                enabled: !root.adopting
                onClicked: root.closeRequested()
            }

            Button {
                visible: root.step === 0
                text: "Review proposal →"
                bordered: true
                enabled: !root.analyzing && root.proposal.length > 0
                opacity: enabled ? 1.0 : 0.5
                onClicked: root.goToProposal()
            }

            Button {
                visible: root.step === 1
                text: root.adopting ? "Adopting…" : "Adopt " + root.adoptDrawerCount + " drawers"
                bordered: true
                enabled: !root.adopting && root.adoptDrawerCount > 0
                opacity: enabled ? 1.0 : 0.5
                onClicked: root.adopt()
            }
        }
    }

    IconPicker {
        id: iconPicker
        // Which proposal card asked, so only that card's field takes the glyph.
        property string forKey: ""
        anchors.fill: parent
    }
}
