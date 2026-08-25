import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Global control point for Drawers.
//
// This is a `panel`-kind entry point with `keepLoaded: true`, so the shell
// mounts it whether or not any drawer sits on the bar. That matters: the whole
// point of a global manager is being reachable when you have no drawers yet,
// and an IpcHandler living in the bar widget would not exist then.
//
// The bar widget owns a separate IPC target ("…drawers.bar") for opening and
// closing individual dropdowns; this one owns configuration.
Item {
    id: root

    property bool windowOpen: false
    property int view: 0            // 0 = drawers, 1 = auto-arrange
    property string focusDrawerId: ""

    readonly property string helperScript:
        Qt.resolvedUrl("drawer-config.py").toString().replace(/^file:\/\//, "")

    function openManager(drawerId) {
        focusDrawerId = String(drawerId || "")
        view = 0
        windowOpen = true
    }

    function openAutoArrange() {
        view = 1
        windowOpen = true
    }

    function closeWindow() { windowOpen = false }

    IpcHandler {
        target: "io.github.06chaynes.drawers"

        // Quickshell IPC has no optional arguments, so the no-argument form
        // the Omarchy menu calls and the preselecting form the bar pill calls
        // are separate verbs.
        function manage(): void { root.openManager("") }
        function edit(drawerId: string): void { root.openManager(drawerId) }
        function autoArrange(): void { root.openAutoArrange() }
        function close(): void { root.closeWindow() }

        function status(): string {
            return JSON.stringify({
                open: root.windowOpen,
                view: root.view === 0 ? "drawers" : "auto-arrange",
                helper: root.helperScript
            })
        }

        // Wire the Drawers entries into the Omarchy menu (Super+Space).
        function installMenu(): void { menuProcess.run("install-menu") }
        function uninstallMenu(): void { menuProcess.run("uninstall-menu") }
    }

    Process {
        id: menuProcess
        running: false
        function run(verb) {
            running = false
            command = [root.helperScript, verb]
            running = true
        }
    }

    Loader {
        active: root.windowOpen
        sourceComponent: Component {
            FloatingWindow {
                title: "Omarchy Drawers"
                color: Color.popups.background
                implicitWidth: Style.space(900)
                implicitHeight: Style.space(640)
                minimumSize: Qt.size(Style.space(680), Style.space(480))

                onClosed: root.closeWindow()

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0

                    // --- View switcher -----------------------------------
                    BorderSurface {
                        Layout.fillWidth: true
                        implicitHeight: Style.space(44)
                        color: Util.alpha(Color.foreground, 0.04)

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Style.space(14)
                            anchors.rightMargin: Style.space(14)
                            spacing: Style.space(6)

                            Text {
                                text: "󰉋"
                                font.family: Style.font.family
                                font.pixelSize: Style.font.icon
                                color: Color.accent
                            }

                            Button {
                                text: "Drawers"
                                bordered: true
                                selected: root.view === 0
                                onClicked: root.view = 0
                            }

                            Button {
                                text: "Auto-arrange"
                                bordered: true
                                selected: root.view === 1
                                onClicked: root.view = 1
                            }

                            Item { Layout.fillWidth: true }

                            Text {
                                text: "Changes apply after: omarchy restart shell"
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                color: Util.alpha(Color.foreground, 0.5)
                            }
                        }
                    }

                    // --- Views -------------------------------------------
                    // Both are kept alive so switching tabs does not discard
                    // a half-finished edit or replay the analysis.
                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        ManagerView {
                            anchors.fill: parent
                            visible: root.view === 0
                            helperScript: root.helperScript
                            focusDrawerId: root.focusDrawerId
                            onAutoArrangeRequested: root.view = 1
                            onCloseRequested: root.closeWindow()
                        }

                        AutoArrangeView {
                            anchors.fill: parent
                            visible: root.view === 1
                            helperScript: root.helperScript
                            onCloseRequested: root.closeWindow()
                            onAdopted: root.view = 0
                        }
                    }
                }
            }
        }
    }
}
