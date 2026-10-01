import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import QtQuick
import QtQuick.Layouts
import "../../"
import JES.Helpers

WlrLayershell {
    id: btPopup
    layer: WlrLayer.Top
    namespace: "bluetooth"
    exclusiveZone: -1
    screen: Quickshell.screens.find(s => s.x === 0 && s.y === 0) ?? Quickshell.screens[0]

    anchors { top: barOnTop; bottom: !barOnTop; right: true }
    margins {
        top: barOnTop ? barHeight : 0
        bottom: !barOnTop ? barHeight : 0
    }

    property bool isOpen: false
    property bool scanning: false

    implicitWidth: popupBody.width + root.wtw
    implicitHeight: popupBody.height + root.wtw
    color: "transparent"
    mask: Region { item: popupBody }

    readonly property string btBin: root.localPath(Qt.resolvedUrl("../../scripts/bluetooth"))

    Item {
        id: popupBody
        width: 700
        height: 500
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

        Item {
            id: header
            height: fontSize + 4 + root.margins * 2
            width: parent.width - root.margins * 2
            anchors.horizontalCenter: parent.horizontalCenter

            Text {
                x: root.margins * 2
                anchors.verticalCenter: parent.verticalCenter
                text: "󰂯 Bluetooth" + (vars.bluetooth?.powered ? "" : "  (off)")
                color: col.accent
                font.family: fontFamily
                font.pixelSize: fontSize + 4
            }

            Row {
                id: hdrBtns
                anchors.right: closeBtn.left
                anchors.rightMargin: root.wtw
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4

                Rectangle {
                    id: pwrBtn
                    width: 70; height: 28 - root.margins * 2
                    radius: mainRad - root.margins - 2
                    property bool hovered: false
                    color: hovered ? col.accent : "transparent"
                    anchors.verticalCenter: parent.verticalCenter
                    Behavior on color { ColorAnimation { duration: 150 * root.animations } }
                    Text {
                        anchors.centerIn: parent
                        text: vars.bluetooth?.powered ? "power off" : "power on"
                        color: pwrBtn.hovered ? col.fontDark : col.font
                        font.family: fontFamily
                        font.pixelSize: fontSize - 4
                        Behavior on color { ColorAnimation { duration: 150 * root.animations } }
                    }
                    MouseArea {
                        id: pwrArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: pwrBtn.hovered = true
                        onExited: pwrBtn.hovered = false
                        onClicked: Quickshell.execDetached(["sh", "-c",
                            btPopup.btBin + " power " + (vars.bluetooth?.powered ? "off" : "on")])
                    }
                }

                Rectangle {
                    id: scanBtn
                    width: 70; height: 28 - root.margins * 2
                    radius: mainRad - root.margins - 2
                    anchors.verticalCenter: parent.verticalCenter
                    property bool hovered: false
                    color: hovered ? col.accent : "transparent"
                    opacity: btPopup.scanning ? 0.4 : 1
                    enabled: !btPopup.scanning
                    Behavior on color { ColorAnimation { duration: 150 * root.animations } }
                    Text {
                        anchors.centerIn: parent
                        text: btPopup.scanning ? "scan…" : "scan"
                        color: scanBtn.hovered ? col.fontDark : col.font
                        font.family: fontFamily
                        font.pixelSize: fontSize - 4
                        Behavior on color { ColorAnimation { duration: 150 * root.animations } }
                    }
                    MouseArea {
                        id: scanArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: scanBtn.hovered = true
                        onExited: scanBtn.hovered = false
                        onClicked: {
                            btPopup.scanning = true
                            Quickshell.execDetached(["sh", "-c",
                                btPopup.btBin + " scan 8"])
                            scanTimer.restart()
                        }
                    }
                }
                Timer {
                    id: scanTimer
                    interval: 8500
                    onTriggered: btPopup.scanning = false
                }
            }

            Item {
                id: closeBtn
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
                    onClicked: root.toggleBluetooth()
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
                contentHeight: contentCol.height
                clip: true

                Column {
                    id: contentCol
                    width: parent.width
                    spacing: root.spacing + 2

                    Repeater {
                        model: vars.bluetooth?.devices ?? []
                        delegate: Rectangle {
                            required property var modelData
                            width: parent.width
                            height: 56
                            radius: mainRad - root.margins
                            color: btArea.containsMouse ? col.backgroundAlt2 : col.backgroundAlt1
                            opacity: 0.95

                            MouseArea { id: btArea; anchors.fill: parent; hoverEnabled: true }

                            Column {
                                anchors.fill: parent
                                anchors.margins: 8
                                spacing: 2

                                Row {
                                    width: parent.width
                                    Text {
                                        width: parent.width - btns.width
                                        text: (modelData.connected ? "● " : "") + (modelData.name || modelData.mac)
                                              + (modelData.battery ? "  " + modelData.battery + "%" : "")
                                        color: modelData.connected ? col.accent : col.font
                                        elide: Text.ElideRight
                                        font.family: fontFamily
                                        font.pixelSize: fontSize - 1
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    Row {
                                        id: btns
                                        spacing: 4
                                        anchors.verticalCenter: parent.verticalCenter

                                        Repeater {
                                            model: {
                                                let cmds = []
                                                if (modelData.connected)
                                                    cmds.push({ t: "disconnect", c: "disconnect " + modelData.mac })
                                                else
                                                    cmds.push({ t: "connect", c: "connect " + modelData.mac })
                                                if (!modelData.paired)
                                                    cmds.push({ t: "pair", c: "pair " + modelData.mac })
                                                cmds.push({ t: modelData.trusted ? "untrust" : "trust",
                                                            c: (modelData.trusted ? "untrust " : "trust ") + modelData.mac })
                                                return cmds
                                            }
                                            delegate: Rectangle {
                                                id: devActBtn
                                                required property var modelData
                                                width: btnText.width + 14
                                                height: 26
                                                radius: mainRad - root.margins - 2
                                                property bool hovered: false
                                                color: hovered ? col.accent : "transparent"
                                                Behavior on color { ColorAnimation { duration: 150 * root.animations } }
                                                Text {
                                                    id: btnText
                                                    anchors.centerIn: parent
                                                    text: modelData.t
                                                    color: devActBtn.hovered ? col.fontDark : col.font
                                                    font.family: fontFamily
                                                    font.pixelSize: fontSize - 5
                                                    Behavior on color { ColorAnimation { duration: 150 * root.animations } }
                                                }
                                                MouseArea {
                                                    id: a
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    onEntered: devActBtn.hovered = true
                                                    onExited: devActBtn.hovered = false
                                                    onClicked: Quickshell.execDetached(["sh", "-c",
                                                        btPopup.btBin + " " + modelData.c])
                                                }
                                            }
                                        }
                                    }
                                }

                                Text {
                                    text: modelData.mac + (modelData.paired ? "  paired" : "") + (modelData.trusted ? "  trusted" : "")
                                    color: col.font
                                    opacity: 0.55
                                    font.family: fontFamily
                                    font.pixelSize: fontSize - 6
                                }
                            }
                        }
                    }

                    Text {
                        visible: (vars.bluetooth?.devices ?? []).length === 0
                        text: btPopup.scanning ? "Scanning…" : "No devices. Press scan."
                        color: col.font
                        opacity: 0.6
                        font.family: fontFamily
                        font.pixelSize: fontSize - 2
                    }
                }
            }
        }
    }
}
