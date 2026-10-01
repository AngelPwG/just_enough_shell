// jes-network — сетевой бекенд JES: nmcli → строгий JSON на stdout.
// Не зависит от nmtui (nmtui — тот же nmcli в TUI-обёртке).
//
//	jes-network status                     {"devices":[...], "wifi":[...]}
//	jes-network devices
//	jes-network wifi [ifname]              точки доступа (nmcli сам делает rescan)
//	jes-network connect <ssid> [password] [ifname]
//	jes-network disconnect <device>
//	jes-network connections
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
)

type Device struct {
	Device     string `json:"device"`
	Type       string `json:"type"`
	State      string `json:"state"`
	Connection string `json:"connection"`
}

type WifiAP struct {
	InUse    bool   `json:"in_use"`
	SSID     string `json:"ssid"`
	Signal   int    `json:"signal"`
	Security string `json:"security"`
	Channel  string `json:"channel"`
}

type ConnInfo struct {
	Name       string `json:"name"`
	Type       string `json:"type"`
	Device     string `json:"device"`
	Autoconnect bool  `json:"autoconnect"`
}

type Status struct {
	Devices     []Device   `json:"devices"`
	Wifi        []WifiAP   `json:"wifi"`
	Connections []ConnInfo `json:"connections"`
}

const esc = "\x00" // маркер для экранированных nmcli двоеточий

func splitTerse(line string) []string {
	line = strings.ReplaceAll(line, `\:` , esc)
	parts := strings.Split(line, ":")
	for i := range parts {
		parts[i] = strings.ReplaceAll(parts[i], esc, ":")
	}
	return parts
}

func nmcli(args ...string) (string, error) {
	out, err := exec.Command("nmcli", args...).CombinedOutput()
	return string(out), err
}

func emit(v interface{}) { json.NewEncoder(os.Stdout).Encode(v) }

func act(out string, err error) {
	if err != nil {
		fail(err, out)
	}
	emit(map[string]string{"status": "ok"})
}

func fail(err error, out string) {
	msg := strings.TrimSpace(out)
	if msg == "" && err != nil {
		msg = err.Error()
	}
	emit(map[string]string{"error": msg})
	os.Exit(1)
}

func devices() []Device {
	out, err := nmcli("-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device")
	if err != nil {
		fail(err, out)
	}
	var res []Device
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line == "" {
			continue
		}
		f := splitTerse(line)
		if len(f) < 4 {
			continue
		}
		res = append(res, Device{f[0], f[1], f[2], f[3]})
	}
	return res
}

func wifi(dev string) []WifiAP {
	args := []string{"-t", "-f", "ACTIVE,SSID,SIGNAL,SECURITY,CHAN", "device", "wifi", "list"}
	if dev != "" {
		args = append(args, "ifname", dev)
	}
	out, err := nmcli(args...)
	if err != nil {
		fail(err, out)
	}
	var res []WifiAP
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line == "" {
			continue
		}
		f := splitTerse(line)
		if len(f) < 5 {
			continue
		}
		sig, _ := strconv.Atoi(f[2])
		res = append(res, WifiAP{f[0] == "yes", f[1], sig, f[3], f[4]})
	}
	return res
}

func status() Status {
	devs := devices()
	wdev := ""
	for _, d := range devs {
		if d.Type == "wifi" {
			wdev = d.Device
			break
		}
	}
	return Status{Devices: devs, Wifi: wifi(wdev), Connections: connections()}
}

func connections() []ConnInfo {
	out, err := nmcli("-t", "-f", "NAME,TYPE,DEVICE,AUTOCONNECT", "connection", "show")
	if err != nil {
		fail(err, out)
	}
	var res []ConnInfo
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line == "" {
			continue
		}
		f := splitTerse(line)
		if len(f) < 4 {
			continue
		}
		res = append(res, ConnInfo{f[0], f[1], f[2], f[3] == "yes"})
	}
	return res
}


// listen: подписка на сигналы NetworkManager через D-Bus (system bus).
// Дедупликация + debounce 400 мс. Если dbus недоступен — редкий фолбэк-полл.
func listen() {
	em := &emitter{}
	em.emit(status())
	flush := debounce(400*time.Millisecond, func() { em.emit(status()) })

	conn, err := dbus.SystemBus()
	if err != nil {
		tick := time.NewTicker(5 * time.Second)
		for range tick.C {
			em.emit(status())
		}
		return
	}
	defer conn.Close()

	matches := []string{
		"type='signal',path='/org/freedesktop/NetworkManager',interface='org.freedesktop.NetworkManager'",
		"type='signal',interface='org.freedesktop.NetworkManager.Device'",
		"type='signal',interface='org.freedesktop.NetworkManager.AccessPoint'",
		"type='signal',interface='org.freedesktop.NetworkManager.Connection.Active'",
		"type='signal',interface='org.freedesktop.DBus.Properties',path_namespace='/org/freedesktop/NetworkManager'",
	}
	for _, m := range matches {
		call := conn.BusObject().Call("org.freedesktop.DBus.AddMatch", 0, m)
		if call.Err != nil {
			fail(call.Err, "")
		}
	}

	ch := make(chan *dbus.Signal, 64)
	conn.Signal(ch)
	for range ch {
		flush()
	}
}


// ── Подписка/дедупликация ─────────────────────────────────────────────

type emitter struct {
	mu   sync.Mutex
	last []byte
}

// emit печатает JSON, только если он отличается от предыдущего
func (e *emitter) emit(v interface{}) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	e.mu.Lock()
	if bytes.Equal(e.last, b) {
		e.mu.Unlock()
		return
	}
	e.last = b
	e.mu.Unlock()
	os.Stdout.Write(append(b, '\n'))
}

// debounce возвращает триггер: fn выполнится через delay после события,
// но при непрерывном шторме сигналов — не реже раза в delay (таймер не откладывается бесконечно)
func debounce(delay time.Duration, fn func()) func() {
	var mu sync.Mutex
	var timer *time.Timer
	return func() {
		mu.Lock()
		defer mu.Unlock()
		if timer != nil {
			return // уже запланировано
		}
		timer = time.AfterFunc(delay, func() {
			fn()
			mu.Lock()
			timer = nil
			mu.Unlock()
		})
	}
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: jes-network <status|devices|wifi|connect|disconnect|connections|set-autoconnect|forget|up|conn|modify|hostname> ...")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "status":
		emit(status())
	case "listen":
		listen()
	case "devices":
		emit(devices())
	case "wifi":
		dev := ""
		if len(os.Args) > 2 {
			dev = os.Args[2]
		}
		emit(wifi(dev))
	case "connect":
		if len(os.Args) < 3 {
			fail(fmt.Errorf("ssid required"), "")
		}
		args := []string{"device", "wifi", "connect", os.Args[2]}
		if len(os.Args) > 3 && os.Args[3] != "" {
			args = append(args, "password", os.Args[3])
		}
		if len(os.Args) > 4 && os.Args[4] != "" {
			args = append(args, "ifname", os.Args[4])
		}
		out, err := nmcli(args...)
		if err != nil {
			emit(map[string]string{"status": "error", "detail": strings.TrimSpace(out)})
			os.Exit(1)
		}
		emit(map[string]string{"status": "ok"})
	case "disconnect":
		out, err := nmcli("device", "disconnect", os.Args[2])
		if err != nil {
			emit(map[string]string{"status": "error", "detail": strings.TrimSpace(out)})
			os.Exit(1)
		}
		emit(map[string]string{"status": "ok"})
	case "conn":
		if len(os.Args) < 3 {
			fail(fmt.Errorf("usage: jes-network conn <name>"), "")
		}
		out, err := nmcli("-t", "connection", "show", os.Args[2])
		if err != nil {
			emit(map[string]string{"error": strings.TrimSpace(out)})
			os.Exit(1)
		}
		m := map[string]string{}
		for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
			if line == "" {
				continue
			}
			parts := splitTerse(line)
			if len(parts) < 2 {
				continue
			}
			m[parts[0]] = strings.Join(parts[1:], ":")
		}
		emit(m)
	case "modify":
		// jes-network modify <name> <key1> <val1> [key2 val2 ...]
		// пустое значение = очистить поле. Активное соединение после modify
		// автоматически поднимается заново (применение конфигурации).
		if len(os.Args) < 6 || len(os.Args)%2 != 0 {
			fail(fmt.Errorf("usage: jes-network modify <name> <key> <value> [key value ...]"), "")
		}
		name := os.Args[2]
		args := []string{"connection", "modify", name}
		args = append(args, os.Args[3:]...)
		out, err := nmcli(args...)
		if err != nil {
			emit(map[string]string{"status": "error", "detail": strings.TrimSpace(out)})
			os.Exit(1)
		}
		// соединение активно? тогда применяем изменения через up
		act, _ := nmcli("-t", "-f", "NAME", "connection", "show", "--active")
		for _, line := range strings.Split(strings.TrimSpace(act), "\n") {
			if line == name {
				nmcli("connection", "up", "id", name)
				break
			}
		}
		emit(map[string]string{"status": "ok"})
	case "hostname":
		if len(os.Args) < 3 {
			out, err := nmcli("general", "hostname")
			if err != nil {
				fail(err, out)
			}
			fmt.Println(strings.TrimSpace(out))
			return
		}
		act(nmcli("general", "hostname", os.Args[2]))
	case "connections":
		emit(connections())
	case "set-autoconnect":
		if len(os.Args) < 4 {
			fail(fmt.Errorf("usage: jes-network set-autoconnect <name> <yes|no>"), "")
		}
		out, err := nmcli("connection", "modify", os.Args[2], "connection.autoconnect", os.Args[3])
		if err != nil {
			emit(map[string]string{"status": "error", "detail": strings.TrimSpace(out)})
			os.Exit(1)
		}
		emit(map[string]string{"status": "ok"})
	case "forget":
		if len(os.Args) < 3 {
			fail(fmt.Errorf("usage: jes-network forget <name>"), "")
		}
		out, err := nmcli("connection", "delete", os.Args[2])
		if err != nil {
			emit(map[string]string{"status": "error", "detail": strings.TrimSpace(out)})
			os.Exit(1)
		}
		emit(map[string]string{"status": "ok"})
	case "up":
		if len(os.Args) < 3 {
			fail(fmt.Errorf("usage: jes-network up <name>"), "")
		}
		out, err := nmcli("connection", "up", "id", os.Args[2])
		if err != nil {
			emit(map[string]string{"status": "error", "detail": strings.TrimSpace(out)})
			os.Exit(1)
		}
		emit(map[string]string{"status": "ok"})
	case "down":
		if len(os.Args) < 3 {
			fail(fmt.Errorf("usage: jes-network down <name>"), "")
		}
		out, err := nmcli("connection", "down", "id", os.Args[2])
		if err != nil {
			emit(map[string]string{"status": "error", "detail": strings.TrimSpace(out)})
			os.Exit(1)
		}
		emit(map[string]string{"status": "ok"})
	default:
		fmt.Fprintln(os.Stderr, "jes-network: unknown command:", os.Args[1])
		os.Exit(2)
	}
}
