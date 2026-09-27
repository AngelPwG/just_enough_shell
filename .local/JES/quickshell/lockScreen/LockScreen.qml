import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pam
import QtQuick

Scope {
    id: lockscreen

    // ── Public state ──────────────────────────────────────────────────
    property alias locked: sessionLock.locked
    property string password: ""
    property bool authenticating: false
    property bool authFailed: false
    property int failedAttempts: 0

    property string lastInput: ""

    property int opacityStep: 3

    function nextOpacity() {
        var next = Math.floor(Math.random() * 3)
        if (next >= opacityStep)
            next += 1
        opacityStep = next
        return 0.58 + next * 0.14
    }

    property int failTimeout: 2000

    readonly property ShellScreen primaryScreen:
        Quickshell.screens.find(s => s.x === 0 && s.y === 0) ?? Quickshell.screens[0]

    signal unlocked()

    // ── Public API ────────────────────────────────────────────────────
    function lock() {
        sessionLock.locked = true
    }

    function unlock() {
        sessionLock.locked = false
    }

    function submitPassword() {
        if (authenticating || password.length === 0)
            return
        authenticating = true
        pam.start()
    }

    function clearPassword() {
        password = ""
    }

    // ── PAM ───────────────────────────────────────────────────────────
    PamContext {
        id: pam
        configDirectory: "/etc/pam.d"
        config: "login"

        onPamMessage: {
            if (pam.responseRequired)
                pam.respond(lockscreen.password)
        }

        onCompleted: result => {
            lockscreen.authenticating = false
            if (result === PamResult.Success) {
                lockscreen.unlock()
            } else {
                lockscreen.password = ""
                lockscreen.failedAttempts += 1
                lockscreen.authFailed = true
                failResetTimer.restart()
            }
        }
    }

    Timer {
        id: failResetTimer
        interval: lockscreen.failTimeout
        repeat: false
        onTriggered: lockscreen.authFailed = false
    }

    // ── Session lock ──────────────────────────────────────────────────
    WlSessionLock {
        id: sessionLock

        WlSessionLockSurface {
            id: lockSurface

            Rectangle {
                anchors.fill: parent
                color: "#000000"

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.BlankCursor
                    onClicked: input.forceActiveFocus()
                }

                Item {
                    id: primaryContent
                    anchors.fill: parent
                    visible: lockSurface.screen === lockscreen.primaryScreen

                    // ── Clock ──
                    SystemClock {
                        id: clock
                        precision: SystemClock.Seconds
                    }

                    Text {
                        id: clockText
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: -40
                        renderType: Text.NativeRendering
                        width: parent.width / 3
                        fontSizeMode: Text.Fit
                        minimumPixelSize: 24
                        horizontalAlignment: Text.AlignHCenter
                        text: Qt.formatDateTime(clock.date, "HH:mm:ss")
                        font.family: fontFamily
                        font.pixelSize: 300
                        color: col.font
                    }

                    // ── Bar under the clock ──
                    Rectangle {
                        id: bar
                        anchors.horizontalCenter: clockText.horizontalCenter
                        anchors.top: clockText.bottom
                        anchors.topMargin: 10
                        width: (clockText.width / 2) * (lockscreen.authFailed ? 1.15 : 1.0)
                        height: 8
                        radius: 4
                        transformOrigin: Item.Center

                        property real fillOpacity: 1.0

                        opacity: lockscreen.authFailed ? 1
                               : lockscreen.password !== "" ? bar.fillOpacity
                               : 0
                        Behavior on opacity { NumberAnimation { duration: 200 * root.animations } }

                        color: lockscreen.authFailed ? base.base10 : col.accent
                        Behavior on color { ColorAnimation { duration: 400 * root.animations } }
                        Behavior on width { NumberAnimation { duration: 150 * root.animations } }
                    }

                    // ── Failure message ──
                    Text {
                        anchors.top: bar.bottom
                        anchors.topMargin: 12
                        anchors.horizontalCenter: bar.horizontalCenter
                        visible: lockscreen.authFailed
                        opacity: lockscreen.authFailed ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 200 * root.animations } }
                        text: "Authentication failed (" + lockscreen.failedAttempts + ")"
                        font.family: fontFamily
                        font.pixelSize: 13
                        font.italic: true
                        color: col.accent
                    }

                }

                // ── Invisible full-screen password input ──
                TextInput {
                    id: input
                    anchors.fill: parent
                    focus: true
                    opacity: 0
                    echoMode: TextInput.Password
                    inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
                    enabled: !lockscreen.authenticating

                    text: lockscreen.password
                    onTextChanged: {
                        if (text !== lockscreen.password)
                            lockscreen.password = text

                        if (lockscreen.password === lockscreen.lastInput)
                            return

                        // сброс ошибки только при реальном вводе (не при программной очистке)
                        if (lockscreen.authFailed && lockscreen.password !== "") {
                            lockscreen.authFailed = false
                            failResetTimer.stop()
                        }

                        bar.fillOpacity = lockscreen.nextOpacity()
                        lockscreen.lastInput = lockscreen.password
                    }
                    onAccepted: lockscreen.submitPassword()
                    Keys.onEscapePressed: lockscreen.clearPassword()
                }
            }
        }
    }

    Connections {
        target: sessionLock
        function onLockedChanged() {
            if (!sessionLock.locked) {
                lockscreen.password = ""
                lockscreen.authFailed = false
                lockscreen.authenticating = false
                lockscreen.unlocked()
            }
        }
    }
}
