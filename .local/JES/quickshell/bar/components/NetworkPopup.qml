import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import QtQuick
import QtQuick.Layouts
import "../../"
import JES.Helpers

WlrLayershell {
    id: networkPopup
    layer: WlrLayer.Top
    namespace: "network"
    exclusiveZone: -1
    screen: Quickshell.screens.find(s => s.x === 0 && s.y === 0) ?? Quickshell.screens[0]

    anchors { top: barOnTop; bottom: !barOnTop; right: true }
    margins {
        top: barOnTop ? barHeight : 0
        bottom: !barOnTop ? barHeight : 0
    }

    property bool isOpen: false
    property string section: "wifi"        // wifi | devices | connections
    property string selectedAp: ""         // ssid
    property string selectedDev: ""        // device iface
    property string selectedConn: ""       // connection name

    implicitWidth: popupBody.width + root.wtw
    implicitHeight: popupBody.height + root.wtw
    color: "transparent"
    mask: Region { item: popupBody }

    readonly property string netBin: root.localPath(Qt.resolvedUrl("../../scripts/network"))

    // выбранные элементы
    readonly property var ap:     (vars.network?.wifi ?? []).find(a => a.ssid === selectedAp) ?? null
    readonly property var dev:    (vars.network?.devices ?? []).find(d => d.device === selectedDev) ?? null
    readonly property var conn:   (vars.network?.connections ?? []).find(c => c.name === selectedConn) ?? null
    readonly property var apConn: (vars.network?.connections ?? []).find(c => c.name === selectedAp) ?? null
    readonly property string wifiDev: (vars.network?.devices ?? []).find(d => d.type === "wifi")?.device ?? ""

    function hasSecurity(a) { return a && a.security !== "--" && a.security !== "" }

    function selectSection(sec) {
        section = sec
        selectedAp = ""
        selectedDev = ""
        selectedConn = ""
    }

    Component {
        id: optButton

        Rectangle {
            id: optItem
            required property var modelData   // { t, c, danger? }
            width: parent.width
            height: visible ? 28 : 0
            radius: mainRad - root.margins - 2
            property bool hovered: false
            color: hovered ? (modelData.danger ? "#c0392b" : col.fontDark) : "transparent"
            Behavior on color { ColorAnimation { duration: 150 * root.animations } }

            Text {
                anchors.centerIn: parent
                text: modelData.t
                color: optItem.hovered ? (modelData.danger ? "#fff" : col.font) : col.fontDark
                font.family: fontFamily
                font.pixelSize: fontSize - 3
                Behavior on color { ColorAnimation { duration: 150 * root.animations } }
            }

            MouseArea {
                id: optArea
                anchors.fill: parent
                hoverEnabled: true
                onEntered: optItem.hovered = true
                onExited: optItem.hovered = false
                onClicked: Quickshell.execDetached(["sh", "-c", networkPopup.netBin + " " + modelData.c])
            }
        }
    }

    Item {
        id: popupBody
        width: 760
        height: 520
        clip: true
        y: isOpen
           ? (barOnTop ? root.wtw : parent.height - height - root.wtw)
           : (barOnTop ? -height : parent.height)
        Behavior on y { NumberAnimation { duration: 250 * root.animations; easing.type: Easing.OutCubic } }

        Rectangle {
            anchors.fill: parent
            anchors.rightMargin: isOpen ? 0 : mainRad
            radius: mainRad
            color: "transparent"
            Behavior on anchors.rightMargin { NumberAnimation { duration: 250 * root.animations } }

            Rectangle {
                anchors.fill: parent
                radius: parent.radius
                opacity: 0.85
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: col.background3 }
                    GradientStop { position: 0.05; color: col.background2 }
                    GradientStop { position: 0.3; color: col.background1 }
                    GradientStop { position: 0.7; color: col.background1 }
                    GradientStop { position: 0.95; color: col.background2 }
                    GradientStop { position: 1.0; color: col.background3 }
                }
            }
        }

        // ── Header ──
        Item {
            id: header
            height: fontSize + 4 + root.margins * 2
            width: parent.width - root.margins * 2
            anchors.horizontalCenter: parent.horizontalCenter

            Text {
                x: root.margins * 2
                anchors.verticalCenter: parent.verticalCenter
                text: "󰈀 Network"
                color: col.accent
                font.family: fontFamily
                font.pixelSize: fontSize + 4
            }

            Item {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: closeIcon.width + 12
                height: 26

                Rectangle {
                    id: closeBg
                    anchors.fill: parent
                    anchors.margins: 2
                    radius: mainRad - root.margins - 2
                    color: "transparent"
                    Behavior on color { ColorAnimation { duration: 200 } }
                }
                Text {
                    id: closeIcon
                    anchors.centerIn: parent
                    text: "󰅗"
                    color: col.font
                    font.family: fontFamily
                    font.pixelSize: fontSize
                    Behavior on color { ColorAnimation { duration: 200 } }
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: { closeBg.color = "#c0392b"; closeIcon.color = "#fff" }
                    onExited: { closeBg.color = "transparent"; closeIcon.color = col.font }
                    onClicked: root.toggleNetwork()
                }
            }
        }

        ClippingRectangle {
            anchors.top: header.bottom
            anchors.bottom: parent.bottom
            anchors.bottomMargin: root.margins
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - root.margins * 2
            radius: mainRad - root.margins
            color: "transparent"

            Flickable {
                anchors.fill: parent
                contentHeight: mainRow.height
                clip: true

                Row {
                    id: mainRow
                    width: parent.width
                    spacing: root.spacing + 6

                    // ══════════ LEFT: content ══════════
                    Column {
                        width: parent.width - parent.spacing - 230
                        spacing: root.spacing + 2

                        // ── Wi-Fi ──
                        Column {
                            width: parent.width
                            spacing: root.spacing + 2
                            visible: networkPopup.section === "wifi"

                            Text { text: "Wi-Fi Networks"; color: col.font; opacity: 0.6; font.family: fontFamily; font.pixelSize: fontSize - 4 }

                            Repeater {
                                model: vars.network?.wifi ?? []
                                delegate: Rectangle {
                                    required property var modelData
                                    width: parent.width
                                    height: 34
                                    radius: mainRad - root.margins - 2
                                    color: apArea.containsMouse ? col.accent
                                          : (networkPopup.selectedAp === modelData.ssid ? col.backgroundAlt2
                                          : (modelData.in_use ? col.backgroundAlt2 : col.backgroundAlt1))
                                    opacity: modelData.ssid === "" ? 0.4 : 0.95
                                    enabled: modelData.ssid !== ""

                                    MouseArea {
                                        id: apArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: networkPopup.selectedAp =
                                            (networkPopup.selectedAp === modelData.ssid) ? "" : modelData.ssid
                                    }

                                    Row {
                                        anchors.fill: parent
                                        anchors.margins: 8
                                        spacing: 8
                                        Text {
                                            text: (modelData.in_use ? "● " : "") + (modelData.ssid || "(hidden)")
                                            color: apArea.containsMouse ? col.fontDark : col.font
                                            elide: Text.ElideRight
                                            width: parent.width - 150
                                            font.family: fontFamily
                                            font.pixelSize: fontSize - 2
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                        Text {
                                            text: modelData.signal + "%" + (networkPopup.hasSecurity(modelData) ? "  󰌾" : "")
                                            color: apArea.containsMouse ? col.fontDark : col.font
                                            font.family: fontFamily
                                            font.pixelSize: fontSize - 4
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }
                                }
                            }
                        }

                        // ── Devices ──
                        Column {
                            width: parent.width
                            spacing: root.spacing + 2
                            visible: networkPopup.section === "devices"

                            Text { text: "Devices"; color: col.font; opacity: 0.6; font.family: fontFamily; font.pixelSize: fontSize - 4 }

                            Repeater {
                                model: vars.network?.devices ?? []
                                delegate: Rectangle {
                                    required property var modelData
                                    width: parent.width
                                    height: 40
                                    radius: mainRad - root.margins - 2
                                    color: devArea.containsMouse ? col.accent : col.backgroundAlt1
                                    opacity: modelData.device === "lo" ? 0.5 : 0.95

                                    MouseArea {
                                        id: devArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: networkPopup.selectedDev =
                                            (networkPopup.selectedDev === modelData.device) ? "" : modelData.device
                                    }

                                    Item {
                                        anchors.fill: parent
                                        anchors.margins: root.margins
                                        Text {
                                            id: icon
                                            anchors.left: parent.left
                                            text: modelData.type === "wifi" ? "󰖩" : modelData.type === "ethernet" ? "󰈀" : "󰓡"
                                            color: modelData.state === "connected" ? col.accent : col.font
                                            font.family: fontFamily
                                            font.pixelSize: fontSize - 1
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                        Text {
                                            id: model
                                            x: icon.width + root.spacing
                                            text: modelData.device + "   " + modelData.type
                                            color: devArea.containsMouse ? col.fontDark : col.font
                                            elide: Text.ElideRight
                                            font.family: fontFamily
                                            font.pixelSize: fontSize - 2
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                        Text {
                                            anchors.right: parent.right
                                            text: modelData.state
                                            color: modelData.state === "connected" ? col.accent : col.font
                                            font.family: fontFamily
                                            font.pixelSize: fontSize - 5
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }
                                }
                            }
                        }

                        // ── Connections ──
                        Column {
                            width: parent.width
                            spacing: root.spacing + 2
                            visible: networkPopup.section === "connections"

                            Text { text: "Saved Connections"; color: col.font; opacity: 0.6; font.family: fontFamily; font.pixelSize: fontSize - 4 }

                            Repeater {
                                model: vars.network?.connections ?? []
                                delegate: Rectangle {
                                    required property var modelData
                                    width: parent.width
                                    height: 32
                                    radius: mainRad - root.margins - 2
                                    color: connArea.containsMouse ? col.accent
                                          : (networkPopup.selectedConn === modelData.name ? col.backgroundAlt2 : col.backgroundAlt1)

                                    MouseArea {
                                        id: connArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: networkPopup.selectedConn =
                                            (networkPopup.selectedConn === modelData.name) ? "" : modelData.name
                                    }

                                    Row {
                                        anchors.fill: parent
                                        anchors.margins: 8
                                        spacing: 8
                                        Text {
                                            width: parent.width - 140
                                            text: modelData.name
                                            color: connArea.containsMouse ? col.fontDark : col.font
                                            elide: Text.ElideRight
                                            font.family: fontFamily
                                            font.pixelSize: fontSize - 2
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                        Text {
                                            text: modelData.type + (modelData.device !== "--" ? "  " + modelData.device : "")
                                            color: connArea.containsMouse ? col.fontDark : col.fontDark
                                            font.family: fontFamily
                                            font.pixelSize: fontSize - 5
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ══════════ RIGHT: Options & model switcher ══════════
                    Column {
                        width: 230
                        spacing: root.spacing + 2

                        // model switcher
                        Column {
                            width: parent.width
                            spacing: 2

                            Repeater {
                                model: [
                                    { id: "wifi",        t: "Wi-Fi" },
                                    { id: "devices",     t: "Devices" },
                                    { id: "connections", t: "Connections" }
                                ]
                                delegate: Rectangle {
                                    id: secItem
                                    required property var modelData
                                    width: parent.width
                                    height: 30
                                    radius: mainRad - root.margins - 2
                                    property bool hovered: false
                                    color: hovered ? col.accent
                                          : (networkPopup.section === modelData.id ? col.backgroundAlt2 : col.backgroundAlt1)
                                    Behavior on color { ColorAnimation { duration: 150 * root.animations } }

                                    Text {
                                        anchors.centerIn: parent
                                        text: modelData.t
                                        color: secItem.hovered ? col.fontDark : col.font
                                        font.family: fontFamily
                                        font.pixelSize: fontSize - 2
                                        Behavior on color { ColorAnimation { duration: 150 * root.animations } }
                                    }

                                    MouseArea {
                                        id: secArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onEntered: secItem.hovered = true
                                        onExited: secItem.hovered = false
                                        onClicked: networkPopup.selectSection(modelData.id)
                                    }
                                }
                            }
                        }

                        Rectangle { width: parent.width; height: 1; color: col.font; opacity: 0.15 }

                        Column {
                            width: parent.width
                            spacing: 3
                            visible: networkPopup.ap !== null || networkPopup.dev !== null || networkPopup.conn !== null

                            Text {
                                width: parent.width
                                text: networkPopup.ap ? "Options: " + networkPopup.ap.ssid
                                    : networkPopup.dev ? "Options: " + networkPopup.dev.device
                                    : "Options: " + (networkPopup.conn?.name ?? "")
                                color: col.accent
                                elide: Text.ElideRight
                                font.family: fontFamily
                                font.pixelSize: fontSize - 4
                            }

                            Rectangle {
                                visible: networkPopup.ap !== null && networkPopup.apConn === null && networkPopup.hasSecurity(networkPopup.ap)
                                width: parent.width
                                height: visible ? 28 : 0
                                radius: mainRad - root.margins - 2
                                color: col.background3
                                clip: true
                                TextInput {
                                    id: passInput
                                    anchors.fill: parent
                                    anchors.margins: 6
                                    color: col.font
                                    font.family: fontFamily
                                    font.pixelSize: fontSize - 3
                                    echoMode: TextInput.Password
                                    clip: true
                                }
                            }

                            // Wi-Fi AP
                            Repeater {
                                model: networkPopup.ap !== null ? [
                                    (!networkPopup.ap.in_use ? {
                                        t: networkPopup.apConn ? "Connect" : "Connect…",
                                        c: networkPopup.apConn
                                            ? "up " + quoteShell(networkPopup.ap.ssid)
                                            : "connect " + quoteShell(networkPopup.ap.ssid) +
                                              (networkPopup.hasSecurity(networkPopup.ap) ? " " + quoteShell(passInput.text) : "")
                                    } : null),
                                    (networkPopup.ap.in_use ? {
                                        t: "Disconnect",
                                        c: "disconnect " + networkPopup.wifiDev
                                    } : null),
                                    (networkPopup.apConn ? {
                                        t: "Autoconnect: " + (networkPopup.apConn.autoconnect ? "on" : "off"),
                                        c: "set-autoconnect " + quoteShell(networkPopup.ap.ssid) + " " +
                                           (networkPopup.apConn.autoconnect ? "no" : "yes")
                                    } : null),
                                    (networkPopup.apConn ? {
                                        t: "Forget", danger: true,
                                        c: "forget " + quoteShell(networkPopup.ap.ssid)
                                    } : null)
                                ].filter(o => o !== null) : []
                                delegate: optButton
                            }

                            // Device
                            Repeater {
                                model: networkPopup.dev !== null ? [
                                    (networkPopup.dev.state === "connected" && networkPopup.dev.device !== "lo" ? {
                                        t: "Disconnect",
                                        c: "disconnect " + networkPopup.dev.device
                                    } : null)
                                ].filter(o => o !== null) : []
                                delegate: optButton
                            }

                            // Connection
                            Repeater {
                                model: networkPopup.conn !== null ? [
                                    { t: "Activate", c: "up " + quoteShell(networkPopup.conn.name) },
                                    (networkPopup.conn.device !== "--" ? {
                                        t: "Deactivate", c: "down " + quoteShell(networkPopup.conn.name)
                                    } : null),
                                    {
                                        t: "Autoconnect: " + (networkPopup.conn.autoconnect ? "on" : "off"),
                                        c: "set-autoconnect " + quoteShell(networkPopup.conn.name) + " " +
                                           (networkPopup.conn.autoconnect ? "no" : "yes")
                                    },
                                    { t: "Delete", danger: true, c: "forget " + quoteShell(networkPopup.conn.name) }
                                ].filter(o => o !== null) : []
                                delegate: optButton
                            }
                        }

                        Text {
                            visible: networkPopup.ap === null && networkPopup.dev === null && networkPopup.conn === null
                            width: parent.width
                            wrapMode: Text.WordWrap
                            text: "Select an item on the left to see its options."
                            color: col.font
                            opacity: 0.5
                            font.family: fontFamily
                            font.pixelSize: fontSize - 5
                        }
                    }
                }
            }
        }
    }

    function quoteShell(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }
}
