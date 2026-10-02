pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick

// Единая точка запуска JsonListen-потоков.
// Ключ = нормализованная команда; на каждую уникальную команду — один Process,
// независимо от того, сколько JsonListen (в JES или в плагинах) её слушают.
QtObject {
    id: manager

    property var _streams: ({})

    function _normalize(cmd) {
        // Паритет со старым JsonListen: раскрываем ~ (первое вхождение)
        return cmd.trim().replace("~", Quickshell.env("HOME"))
    }

    readonly property int maxRestarts: 3

    // Вернуть entry-объект с сигналом line(var value). Не null только при непустой команде.
    function acquire(command) {
        if (!command) {
            console.warn("[StreamManager] acquire: пустая команда, поток не создан")
            return null
        }
        const key = _normalize(command)
        let e = _streams[key]
        if (!e) {
            e = streamComponent.createObject(manager, { key: key })
            _streams[key] = e
            console.log("[StreamManager] new stream:", key)
        }
        e.refs++
        return e
    }

    function release(command) {
        if (!command)
            return
        const key = _normalize(command)
        const e = _streams[key]
        if (!e)
            return
        e.refs--
        if (e.refs <= 0) {
            delete _streams[key]
            e.destroy()   // уничтожение Process убивает дочерний процесс
        }
    }

    // Через property — QtObject не принимает голых дочерних объектов
    property Component streamComponent: Component {
        QtObject {
            id: stream
            property string key: ""
            property int refs: 0
            property int restarts: 0
            signal line(var value)

            // Рестарт до maxRestarts с паузой 1с; потом — "пизда потоку"
            function _restart() {
                if (refs <= 0)
                    return // уже release'нут — не рестартуем
                if (restarts >= manager.maxRestarts) {
                    console.error("[StreamManager] Process dead permanently after",
                                  manager.maxRestarts, "restarts:", key)
                    return
                }
                restarts++
                console.warn("[StreamManager] restart #" + restarts + ":", key)
                restartTimer.start()
            }

            property Timer restartTimer: Timer {
                id: restartTimer
                interval: 1000
                onTriggered: {
                    stream.proc.running = false
                    stream.proc.running = true
                }
            }

            property Process proc: Process {
                command: ["bash", "-c", stream.key]
                running: true

                stdout: SplitParser {
                    onRead: rawData => {
                        let trimmed = rawData.trim()
                        if (!trimmed)
                            return

                        let value
                        if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
                            try {
                                value = JSON.parse(trimmed)
                            } catch (e) {
                                // Паритет со старым JsonListen: не-JSON → сырой текст
                                value = trimmed
                            }
                        } else {
                            value = trimmed
                        }
                        stream.line(value)
                    }
                }

                stderr: SplitParser {
                    onRead: errorData =>
                        console.error("[StreamManager] STDERR:", stream.key, "->", errorData)
                }

                onExited: (code, status) => {
                    if (stream.refs <= 0)
                        return // поток освобождён, это штатное уничтожение
                    if (code !== 0) {
                        console.error("[StreamManager] Process died! Code:", code, "Cmd:", stream.key)
                        stream._restart()
                    }
                }
            }
        }
    }
}
