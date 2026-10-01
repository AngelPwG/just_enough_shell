// jes-bluetooth — bluetooth-бекенд JES: bluetoothctl → строгий JSON на stdout.
//
//	jes-bluetooth status          {"powered":bool, "name":..., "devices":[...]}
//	jes-bluetooth devices
//	jes-bluetooth connect|disconnect|pair|trust|untrust|remove <mac>
//	jes-bluetooth power <on|off>
//	jes-bluetooth scan [seconds]  синхронный скан (блокируется на N сек), в конце список устройств
//
// Примечание: pair без агента может не спросить пин-код — для простых
// устройств (наушники) обычно не нужен.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
)

type Device struct {
	MAC       string `json:"mac"`
	Name      string `json:"name"`
	Icon      string `json:"icon"`
	Connected bool   `json:"connected"`
	Paired    bool   `json:"paired"`
	Bonded    bool   `json:"bonded"`
	Trusted   bool   `json:"trusted"`
	Battery   int    `json:"battery,omitempty"`
}

type Status struct {
	Powered bool     `json:"powered"`
	Name    string   `json:"name,omitempty"`
	Devices []Device `json:"devices"`
}

var battRe = regexp.MustCompile(`\((\d+)\)`)

func btctl(args ...string) (string, error) {
	out, err := exec.Command("bluetoothctl", args...).CombinedOutput()
	return string(out), err
}

func emit(v interface{}) { json.NewEncoder(os.Stdout).Encode(v) }

func fail(err error, out string) {
	msg := strings.TrimSpace(out)
	if msg == "" && err != nil {
		msg = err.Error()
	}
	emit(map[string]string{"error": msg})
	os.Exit(1)
}

func act(out string, err error) {
	if err != nil {
		fail(err, out)
	}
	emit(map[string]string{"status": "ok"})
}

func parseInfo(out string) map[string]string {
	m := map[string]string{}
	for _, line := range strings.Split(out, "\n") {
		trimmed := strings.TrimSpace(line)
		idx := strings.Index(trimmed, ":")
		if idx <= 0 {
			continue
		}
		m[trimmed[:idx]] = strings.TrimSpace(trimmed[idx+1:])
	}
	return m
}

func devices() []Device {
	out, err := btctl("devices")
	if err != nil {
		fail(err, out)
	}
	var macs []string
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if !strings.HasPrefix(line, "Device ") {
			continue
		}
		f := strings.SplitN(line[7:], " ", 2)
		macs = append(macs, f[0])
	}
	res := make([]Device, 0, len(macs))
	for _, mac := range macs {
		info, _ := btctl("info", mac)
		m := parseInfo(info)
		d := Device{
			MAC:       mac,
			Name:      m["Name"],
			Icon:      m["Icon"],
			Connected: m["Connected"] == "yes",
			Paired:    m["Paired"] == "yes",
			Bonded:    m["Bonded"] == "yes",
			Trusted:   m["Trusted"] == "yes",
		}
		if mm := battRe.FindStringSubmatch(m["Battery Percentage"]); mm != nil {
			d.Battery, _ = strconv.Atoi(mm[1])
		}
		res = append(res, d)
	}
	return res
}

func status() Status {
	out, err := btctl("show")
	if err != nil {
		fail(err, out)
	}
	m := parseInfo(out)
	return Status{
		Powered: m["Powered"] == "yes",
		Name:    m["Name"],
		Devices: devices(),
	}
}


// listen: подписка на сигналы BlueZ через D-Bus (system bus):
// PropertiesChanged (Connected/Paired/Battery/...) и InterfacesAdded/Removed.
// Дедупликация + debounce 500 мс (при скане RSSI шлёт частые обновления).
// Если dbus недоступен — редкий фолбэк-полл.
func listen() {
	em := &emitter{}
	em.emit(status())
	flush := debounce(500*time.Millisecond, func() { em.emit(status()) })

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
		"type='signal',interface='org.freedesktop.DBus.Properties',path_namespace='/org/bluez'",
		"type='signal',interface='org.freedesktop.DBus.ObjectManager',path_namespace='/org/bluez'",
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
		fmt.Fprintln(os.Stderr, "usage: jes-bluetooth <status|devices|connect|disconnect|pair|trust|untrust|remove|power|scan> ...")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "status":
		emit(status())
	case "listen":
		listen()
	case "devices":
		emit(devices())
	case "connect", "disconnect", "pair", "trust", "untrust", "remove":
		if len(os.Args) < 3 {
			fail(fmt.Errorf("mac required"), "")
		}
		act(btctl(os.Args[1], os.Args[2]))
	case "power":
		if len(os.Args) < 3 || (os.Args[2] != "on" && os.Args[2] != "off") {
			fail(fmt.Errorf("usage: jes-bluetooth power <on|off>"), "")
		}
		act(btctl("power", os.Args[2]))
	case "scan":
		secs := "8"
		if len(os.Args) > 2 {
			secs = os.Args[2]
		}
		out, err := btctl("--timeout", secs, "scan", "on")
		if err != nil {
			fail(err, out)
		}
		emit(devices())
	default:
		fmt.Fprintln(os.Stderr, "jes-bluetooth: unknown command:", os.Args[1])
		os.Exit(2)
	}
}
