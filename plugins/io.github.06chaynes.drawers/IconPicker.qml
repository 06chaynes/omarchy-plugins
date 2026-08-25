import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Glyph palette for drawer icons. Overlays its parent rather than opening a
// popup window: the icon fields it serves sit inside Flickables and layouts
// that would clip or mis-place an inline dropdown.
//
// The palette is a convenience, not a constraint — the field behind it stays a
// plain text input, so any glyph the font has is still reachable by typing.
Item {
    id: root

    property bool open: false
    property string current: ""

    signal picked(string glyph)

    // Every glyph here was harvested from the shell and the installed plugins,
    // so each one is known to render in the bar font rather than falling back
    // to a placeholder box.
    readonly property var palette: [
        { g: "\u{F0388}", n: "Media",        k: "media music note" },
        { g: "\u{F075A}", n: "Music",        k: "music song audio" },
        { g: "\u{F02CB}", n: "Headphones",   k: "headphones audio" },
        { g: "\u{F057E}", n: "Volume",       k: "volume sound audio speaker" },
        { g: "\u{F036C}", n: "Microphone",   k: "microphone mic record" },
        { g: "\u{F0296}", n: "Games",        k: "games gamepad play fun" },
        { g: "\u{F0379}", n: "Display",      k: "display monitor screen" },
        { g: "\u{F00DF}", n: "Brightness",   k: "brightness light screen" },
        { g: "\u{F06E8}", n: "Lights",       k: "lights lamp bulb home" },
        { g: "\u{F02DC}", n: "Home",         k: "home house smart" },
        { g: "\u{F00AF}", n: "Bluetooth",    k: "bluetooth wireless" },
        { g: "\u{F05A9}", n: "Wi-Fi",        k: "wifi wireless network" },
        { g: "\u{F0928}", n: "Network",      k: "network wifi internet" },
        { g: "\u{F0493}", n: "Settings",     k: "settings cog gear system" },
        { g: "\u{F08BB}", n: "Hardware",     k: "hardware chip cpu" },
        { g: "\u{F035B}", n: "Memory",       k: "memory ram" },
        { g: "\u{F02CA}", n: "Disk",         k: "disk storage drive" },
        { g: "\u{F0425}", n: "Power",        k: "power shutdown battery" },
        { g: "\u{F033E}", n: "Lock",         k: "lock security private" },
        { g: "\u{F018D}", n: "Terminal",     k: "terminal console shell" },
        { g: "\u{F0169}", n: "Code",         k: "code development dev" },
        { g: "\u{F024B}", n: "Files",        k: "files folder" },
        { g: "\u{F0219}", n: "Documents",    k: "documents notes text file" },
        { g: "\u{F01DA}", n: "Downloads",    k: "downloads download" },
        { g: "\u{F0450}", n: "Sync",         k: "sync refresh repeat update" },
        { g: "\u{F06A9}", n: "AI",           k: "ai robot agent assistant" },
        { g: "\u{F02FC}", n: "Info",         k: "info information status" },
        { g: "\u{F0026}", n: "Alert",        k: "alert warning" },
        { g: "\u{F009B}", n: "Notifications",k: "notifications bell silence" },
        { g: "\u{F05E0}", n: "Check",        k: "check ok done status" },
        { g: "\u{F051F}", n: "Timer",        k: "timer clock time" },
        { g: "\u{F0176}", n: "Coffee",       k: "coffee break" },
        { g: "\u{F0BAF}", n: "Workspaces",   k: "workspaces desktops" },
        { g: "\u{F0570}", n: "Grid",         k: "grid layout tiles" },
        { g: "\u{F0339}", n: "Open",         k: "open link external" },
        { g: "\u{F02D5}", n: "Favourite",    k: "favourite heart star" }
    ]

    property string query: ""

    readonly property var shown: {
        var q = query.toLowerCase().trim()
        if (!q) return palette
        var out = []
        for (var i = 0; i < palette.length; i++) {
            var e = palette[i]
            if (e.n.toLowerCase().indexOf(q) !== -1 || e.k.indexOf(q) !== -1) out.push(e)
        }
        return out
    }

    function show(currentGlyph) {
        current = String(currentGlyph || "")
        query = ""
        searchField.text = ""
        open = true
        searchField.forceActiveFocus()
    }

    visible: open
    z: 20

    MouseArea {
        anchors.fill: parent
        onClicked: root.open = false
    }

    Rectangle {
        anchors.fill: parent
        color: Util.alpha(Color.background, 0.72)
    }

    BorderSurface {
        anchors.centerIn: parent
        width: Math.min(parent.width - Style.space(40), Style.space(420))
        height: Math.min(parent.height - Style.space(40), Style.space(360))
        radius: Style.cornerRadius
        color: Color.popups.background
        borderSpec: Border.flat(Color.popups.border, 1)

        // Swallow clicks so they do not reach the dismissal area behind.
        MouseArea { anchors.fill: parent }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Style.space(12)
            spacing: Style.space(8)

            RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)

                Text {
                    Layout.fillWidth: true
                    text: "Choose an icon"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.heading
                    font.weight: Font.Bold
                    color: Color.foreground
                }

                Button {
                    text: "✕"
                    onClicked: root.open = false
                }
            }

            TextField {
                id: searchField
                Layout.fillWidth: true
                placeholderText: "Search icons…"
                onTextChanged: root.query = text
                Keys.onEscapePressed: root.open = false
            }

            Flickable {
                id: paletteScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: width
                contentHeight: paletteFlow.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height
                QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

                Flow {
                    id: paletteFlow
                    width: paletteScroll.width
                    spacing: Style.space(6)

                    Repeater {
                        model: root.shown

                        delegate: BorderSurface {
                            id: swatch
                            required property var modelData
                            readonly property bool isCurrent: modelData.g === root.current

                            width: Style.space(44)
                            height: Style.space(44)
                            radius: Style.cornerRadius
                            color: isCurrent ? Util.alpha(Color.accent, 0.25)
                                : (hover.hovered ? Util.alpha(Color.foreground, 0.12)
                                                 : Util.alpha(Color.foreground, 0.04))
                            borderSpec: isCurrent ? Border.flat(Color.accent, 1)
                                                  : Border.flat(Color.popups.border, 1)

                            Text {
                                anchors.centerIn: parent
                                text: swatch.modelData.g
                                font.family: Style.font.family
                                font.pixelSize: Style.font.iconLarge
                                color: swatch.isCurrent ? Color.accent : Color.foreground
                            }

                            HoverHandler { id: hover }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.picked(swatch.modelData.g)
                                    root.open = false
                                }
                            }
                        }
                    }

                    Text {
                        visible: root.shown.length === 0
                        text: "No match. Close this and type any glyph straight into the field."
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        color: Util.alpha(Color.foreground, 0.6)
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                text: "Or type any Nerd Font glyph directly into the icon field."
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: Util.alpha(Color.foreground, 0.5)
                wrapMode: Text.WordWrap
            }
        }
    }
}
