import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import QtQuick
import QtQuick.Layouts
import "../../"
import JES.Helpers

WlrLayershell {
    id: audioPopup
    layer: WlrLayer.Top
    namespace: "audio"
    exclusiveZone: -1
    screen: Quickshell.screens.find(s => s.x === 0 && s.y === 0) ?? Quickshell.screens[0]

    anchors { top: barOnTop; bottom: !barOnTop; right: true }
    margins {
        top: barOnTop ? barHeight : 0
        bottom: !barOnTop ? barHeight : 0
    }

    property bool isOpen: false
    implicitWidth: popupBody.width + root.wtw
    implicitHeight: popupBody.height + root.wtw
    color: "transparent"
    mask: Region { item: popupBody }

    readonly property string audioBin: root.localPath(Qt.resolvedUrl("../../scripts/audio"))

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
                text: "󰗅 Audio"
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
                    onClicked: root.toggleAudio()
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

                    Text { text: "Output"; color: col.font; opacity: 0.6; font.family: fontFamily; font.pixelSize: fontSize - 4 }
                    Repeater { model: vars.audio?.sinks ?? []; delegate: deviceBlock }

                    Text { text: "Input"; color: col.font; opacity: 0.6; font.family: fontFamily; font.pixelSize: fontSize - 4 }
                    Repeater { model: vars.audio?.sources ?? []; delegate: deviceBlock }

                    Text { text: "Card profiles"; color: col.font; opacity: 0.6; font.family: fontFamily; font.pixelSize: fontSize - 4 }
                    Repeater {
                        model: vars.audio?.cards ?? []
                        delegate: Column {
                            required property var modelData
                            property var card: modelData
                            width: parent.width
                            spacing: 2

                            Text {
                                width: parent.width
                                text: modelData.name
                                color: col.font
                                opacity: 0.7
                                elide: Text.ElideRight
                                font.family: fontFamily
                                font.pixelSize: fontSize - 4
                            }

                            Repeater {
                                model: modelData.profiles
                                delegate: Rectangle {
                                    required property var modelData
                                    width: parent.width
                                    height: 30
                                    radius: mainRad - root.margins - 2
                                    color: profArea.containsMouse ? col.accent
                                          : (modelData.active ? col.backgroundAlt2 : col.backgroundAlt1)
                                    opacity: modelData.available ? 0.95 : 0.45

                                    Text {
                                        anchors.centerIn: parent
                                        width: parent.width - 16
                                        text: modelData.description + (modelData.active ? "  ●" : "")
                                        color: profArea.containsMouse ? col.fontDark : col.font
                                        elide: Text.ElideRight
                                        horizontalAlignment: Text.AlignHCenter
                                        font.family: fontFamily
                                        font.pixelSize: fontSize - 3
                                    }

                                    MouseArea {
                                        id: profArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        enabled: modelData.available
                                        onClicked: Quickshell.execDetached(["sh", "-c",
                                            audioPopup.audioBin + " set-profile " + quoteShell(card.name) + " " +
                                            quoteShell(modelData.name)])
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: deviceBlock

        Rectangle {
            required property var modelData
            width: parent.width
            height: 76
            radius: mainRad - root.margins
            color: devArea.containsMouse ? col.backgroundAlt2 : col.backgroundAlt1
            opacity: 0.95

            MouseArea {
                id: devArea
                anchors.fill: parent
                hoverEnabled: true
                onClicked: {
                    if (modelData.kind === "sink") {
                        Quickshell.execDetached(["sh", "-c", audioPopup.audioBin + " set-default " + quoteShell(modelData.name)])
                    }
                }
            }

            Column {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 6

                Row {
                    width: parent.width
                    spacing: 8

                    Text {
                        width: parent.width - muteBtn.width - 12
                        text: (modelData.description || modelData.name) + (modelData.default ? "  ●" : "")
                        color: modelData.default ? col.accent : col.font
                        elide: Text.ElideRight
                        font.family: fontFamily
                        font.pixelSize: fontSize
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Rectangle {
                        id: muteBtn
                        width: 28
                        height: 28
                        radius: mainRad - root.margins - 2
                        property bool hovered: false
                        color: hovered ? col.accent : "transparent"
                        anchors.verticalCenter: parent.verticalCenter
                        Behavior on color { ColorAnimation { duration: 150 * root.animations } }

                        Text {
                            anchors.centerIn: parent
                            text: modelData.muted ? "󰖁" : "󰖐"
                            color: muteBtn.hovered ? col.fontDark : col.font
                            font.family: fontFamily
                            font.pixelSize: 20
                            Behavior on color { ColorAnimation { duration: 150 * root.animations } }
                        }

                        MouseArea {
                            id: muteArea
                            anchors.fill: parent
                            hoverEnabled: true
                            onEntered: muteBtn.hovered = true
                            onExited: muteBtn.hovered = false
                            onClicked: Quickshell.execDetached(["sh", "-c",
                                audioPopup.audioBin + " toggle-mute " + quoteShell(modelData.name) + " " + modelData.kind])
                        }
                    }
                }

                Item {
                    id: volBar
                    width: parent.width
                    height: 16

                    property int dragVal: -1
                    readonly property int shown: dragVal >= 0 ? dragVal : modelData.volume

                    function setFromX(x) {
                        return Math.max(0, Math.min(100, Math.round((x / width) * 100)))
                    }

                    Rectangle {
                        anchors.fill: parent
                        radius: mainRad
                        color: "transparent"
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
                                
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.margins: 2
                            height: parent.height - 4
                            width: Math.max(0, Math.min(parent.width - percentText.width - root.spacing * 3 - 4,
                                (volBar.shown / 100) * (parent.width - percentText.width - root.spacing * 3 - 4)))
                            color: col.accent
                            radius: mainRad
                        }

                        Text {
                            id: percentText
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: parent.right
                            anchors.rightMargin: 6
                            text: volBar.shown + "%"
                            color: col.accent
                            font.family: "Mononoki Nerd Font Propo"
                            font.pixelSize: 10
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent
                            onPressed: mouse => volBar.dragVal = volBar.setFromX(mouse.x)
                            onPositionChanged: mouse => {
                                if (pressed) volBar.dragVal = volBar.setFromX(mouse.x)
                            }
                            onReleased: {
                                if (volBar.dragVal >= 0) {
                                    Quickshell.execDetached(["sh", "-c",
                                        audioPopup.audioBin + " set-volume " + quoteShell(modelData.name) + " " +
                                        volBar.dragVal + " " + modelData.kind])
                                }
                                dragReset.restart()
                            }
                        }
                    }

                    Timer {
                        id: dragReset
                        interval: 400
                        onTriggered: volBar.dragVal = -1
                    }
                }
            }
        }
    }

    function quoteShell(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }
}
