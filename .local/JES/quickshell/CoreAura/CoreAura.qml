import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import JES.Helpers

Scope {
    id: coreAura

    // Для отладки: true → coreaura --session ...
    property bool useSessionBus: false

    // Ручные оверрайды
    property bool errors:  false
    property bool cpu_gpu: false

    // Внутреннее состояние
    property string cpuState:   "normal"
    property string gpuState:   "normal"
    property int    flashCount: 3
    property bool   _initialFetched: false

    // ══════════════════════════════════════════════════════
    //  Окно 1: ошибки на Overlay
    // ══════════════════════════════════════════════════════
    PanelWindow {
        id: overlayWin
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "CoreAura"
        WlrLayershell.exclusiveZone: -1
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
            top: true; bottom: true; left: true; right: true
        }
        mask: Region {}
        color: "transparent"
        visible: true   // оверлей всегда существует, видимость слоя ниже

        Item {
            id: errorLayer
            anchors.fill: parent
            anchors.margins: root.wtw - 4
            visible: outerBorder.opacity > 0.001 || innerBorder.opacity > 0.001

            Rectangle {
                id: outerBorder
                anchors.fill: parent
                radius: root.mainRad + 4
                border.width: 4
                border.color: base.base09
                color: "transparent"
                opacity: 0
            }

            Rectangle {
                id: innerBorder
                anchors.fill: parent
                anchors.margins: 8
                radius: root.mainRad - 4
                border.width: 4
                border.color: base.base09
                color: "transparent"
                opacity: 0
            }
        }
    }

    // ══════════════════════════════════════════════════════
    //  Окно 2: ресурсы на Top (автоматически под fullscreen)
    // ══════════════════════════════════════════════════════
    PanelWindow {
        id: barsWin
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "CoreAuraBars"
        WlrLayershell.exclusiveZone: -1
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
            top: true; bottom: true; left: true; right: true
        }
        mask: Region {}
        color: "transparent"

        Item {
            id: resourceLayer
            anchors.fill: parent
            anchors.margins: root.wtw - 4

            Rectangle {
                id: cpuBar
                radius: root.mainRad + 4
                implicitWidth: 4
                implicitHeight: parent.height * 2 / 3
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                color: base.base10
                opacity: (coreAura.cpu_gpu || coreAura.cpuState === "overload") ? 1 : 0
                Behavior on opacity {
                    NumberAnimation { duration: 200; easing.type: Easing.InOutQuad }
                }
            }

            Rectangle {
                id: gpuBar
                radius: root.mainRad + 4
                implicitWidth: 4
                implicitHeight: parent.height * 2 / 3
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                color: base.base10
                opacity: (coreAura.cpu_gpu || coreAura.cpuState === "overload") ? 1 : 0
                Behavior on opacity {
                    NumberAnimation { duration: 200; easing.type: Easing.InOutQuad }
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════
    //  Анимации мигания (targets теперь через id окна)
    // ══════════════════════════════════════════════════════
    SequentialAnimation {
        id: flashOuterAnim
        loops: coreAura.flashCount
        NumberAnimation {
            target: outerBorder; property: "opacity"
            from: 0; to: 1; duration: 150; easing.type: Easing.OutQuad
        }
        NumberAnimation {
            target: outerBorder; property: "opacity"
            from: 1; to: 0; duration: 150; easing.type: Easing.InQuad
        }
    }
    
    SequentialAnimation {
        id: flashInnerAnim
        PauseAnimation { duration: 250 }
        SequentialAnimation {
            loops: coreAura.flashCount
            NumberAnimation {
                target: innerBorder; property: "opacity"
                from: 0; to: 1; duration: 150; easing.type: Easing.OutQuad
            }
            NumberAnimation {
                target: innerBorder; property: "opacity"
                from: 1; to: 0; duration: 150; easing.type: Easing.InQuad
            }
        }
    }
    
    function triggerFlash(count) {
        if (coreAura.errors) return
        flashOuterAnim.stop()
        flashInnerAnim.stop()
        outerBorder.opacity = 0
        innerBorder.opacity = 0
        coreAura.flashCount = Math.max(1, count)
        flashOuterAnim.start()
        flashInnerAnim.start()
    }
    
    onErrorsChanged: {
        if (errors) {
            flashOuterAnim.stop()
            flashInnerAnim.stop()
            outerBorder.opacity = 1
            innerBorder.opacity = 1
        } else {
            outerBorder.opacity = 0
            innerBorder.opacity = 0
        }
    }
        
    // ══════════════════════════════════════════════════════
    //  Подписка на CoreAura через JsonListen
    // ══════════════════════════════════════════════════════
    JsonListen {
        id: auraSub
        command: coreAura.useSessionBus
            ? localPath(Qt.resolvedUrl("./CoreAura -session subscribe"))
            : localPath(Qt.resolvedUrl("./CoreAura subscribe"))
        debug: false

        onDataChanged: {
            if (!data || !data.signal) return
            coreAura.handleEvent(data.signal, data.body)
        }
    }

    JsonListen {
        id: auraInitial
        command: coreAura.useSessionBus
            ? localPath(Qt.resolvedUrl("./CoreAura -session subscribe"))
            : localPath(Qt.resolvedUrl("./CoreAura subscribe"))
        debug: false

        onDataChanged: {
            if (!data || typeof data !== "object") return
            coreAura.cpuState = data.cpu || "normal"
            coreAura.gpuState = data.gpu || "normal"
            coreAura._initialFetched = true
            console.log("[CoreAura] initial cpu=" + data.cpu +
                        " (" + data.cpu_pct + "%) gpu=" + data.gpu +
                        " (" + data.gpu_pct + "%)")
        }
    }

    Timer {
        interval: 2000
        running: !coreAura._initialFetched
        repeat: true
        onTriggered: auraInitial.command = auraInitial.command
    }

    function handleEvent(name, body) {
        switch (name) {
        case "KernelError":
            triggerFlash(3)
            break
        case "ServiceStateChanged":
            if (body && body[1] === "failed")
                triggerFlash(2)
            break
        case "UICrashed":
            triggerFlash(2)
            break
        case "ResourceStatusChanged":
            var r = body[0]
            if (r && typeof r === "object") {
                coreAura.cpuState = r.cpu || "normal"
                coreAura.gpuState = r.gpu || "normal"
            }
            break
        }
    }
}
