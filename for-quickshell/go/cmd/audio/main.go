// jes-audio — аудио-бекенд JES: pactl → строгий JSON на stdout.
//
//	jes-audio status                     {"default_sink","default_source","sinks","sources","cards"}
//	jes-audio listen                     то же самое, но по каждому событию pactl subscribe (поток)
//	jes-audio sinks | sources | cards    отдельные секции
//	jes-audio set-default <sink>
//	jes-audio set-volume <name> <0..100> [sink|source]   (pamixer; по умолчанию sink)
//	jes-audio toggle-mute <name> [sink|source]           (pamixer)
//	jes-audio set-profile <card> <profile>
package main

import (
	"bufio"
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
)

func pactl(args ...string) (string, error) {
	out, err := exec.Command("pactl", args...).CombinedOutput()
	return string(out), err
}

// громкость/мьют — через pamixer (надёжнее pactl на pipewire)
func pamixer(args ...string) (string, error) {
	out, err := exec.Command("pamixer", args...).CombinedOutput()
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

type Device struct {
	ID          int    `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Driver      string `json:"driver"`
	State       string `json:"state"`
	Volume      int    `json:"volume"`
	Muted       bool   `json:"muted"`
	Default     bool   `json:"default"`
	Kind        string `json:"kind"` // "sink" | "source"
}

type Profile struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Available   bool   `json:"available"`
	Active      bool   `json:"active"`
}

type Card struct {
	ID            int       `json:"id"`
	Name          string    `json:"name"`
	Driver        string    `json:"driver"`
	ActiveProfile string    `json:"active_profile"`
	Profiles      []Profile `json:"profiles"`
}

type Status struct {
	DefaultSink   string   `json:"default_sink"`
	DefaultSource string   `json:"default_source"`
	Sinks         []Device `json:"sinks"`
	Sources       []Device `json:"sources"`
	Cards         []Card   `json:"cards"`
}

var volRe = regexp.MustCompile(`(\d+)%`)

// objects режет вывод "pactl list <kind>" на плоские карты "Ключ: значение"
// (вложенные блоки Properties/Ports/Formats пропускаются).
func objects(out, header string) []map[string]string {
	var res []map[string]string
	var cur map[string]string
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, header+" #") {
			if cur != nil {
				res = append(res, cur)
			}
			cur = map[string]string{"id": strings.TrimSpace(strings.TrimPrefix(line, header+" #"))}
			continue
		}
		if cur == nil || strings.HasPrefix(line, "\t\t") {
			continue
		}
		trimmed := strings.TrimSpace(line)
		idx := strings.Index(trimmed, ":")
		if idx <= 0 {
			continue
		}
		cur[trimmed[:idx]] = strings.TrimSpace(trimmed[idx+1:])
	}
	if cur != nil {
		res = append(res, cur)
	}
	return res
}

func parseDevices(kind, header string) []Device {
	out, err := pactl("list", kind+"s")
	if err != nil {
		fail(err, out)
	}
	var res []Device
	for _, m := range objects(out, header) {
		id, _ := strconv.Atoi(m["id"])
		vol := 0
		if mm := volRe.FindStringSubmatch(m["Volume"]); mm != nil {
			vol, _ = strconv.Atoi(mm[1])
		}
		res = append(res, Device{
			ID:          id,
			Name:        m["Name"],
			Description: m["Description"],
			Driver:      m["Driver"],
			State:       m["State"],
			Volume:      vol,
			Muted:       m["Mute"] == "yes",
			Kind:        kind,
		})
	}
	return res
}

func parseCards() []Card {
	out, err := pactl("list", "cards")
	if err != nil {
		fail(err, out)
	}
	var res []Card
	var cur *Card
	section := ""
	for _, line := range strings.Split(out, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "Card #") {
			if cur != nil {
				res = append(res, *cur)
			}
			id, _ := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(trimmed, "Card #")))
			cur = &Card{ID: id}
			section = ""
			continue
		}
		if cur == nil {
			continue
		}
		switch {
		case strings.HasPrefix(line, "\t\t"): // глубина 2 — только профили нас интересуют
			if section != "profiles" {
				continue
			}
			idx := strings.Index(trimmed, ": ")
			if idx <= 0 {
				continue
			}
			name := trimmed[:idx]
			rest := trimmed[idx+2:]
			desc := rest
			if j := strings.Index(rest, " ("); j > 0 {
				desc = rest[:j]
			}
			cur.Profiles = append(cur.Profiles, Profile{
				Name:        name,
				Description: strings.TrimSpace(desc),
				Available:   strings.Contains(rest, "available: yes"),
				Active:      name == cur.ActiveProfile,
			})
		case strings.HasPrefix(line, "\t"): // верхний уровень карты
			idx := strings.Index(trimmed, ":")
			if idx <= 0 {
				continue
			}
			key, val := trimmed[:idx], strings.TrimSpace(trimmed[idx+1:])
			switch key {
			case "Name":
				cur.Name = val
			case "Driver":
				cur.Driver = val
			case "Active Profile":
				cur.ActiveProfile = val
				for i := range cur.Profiles {
					cur.Profiles[i].Active = cur.Profiles[i].Name == val
				}
			case "Profiles":
				section = "profiles"
			default:
				section = ""
			}
		default:
			section = ""
		}
	}
	if cur != nil {
		res = append(res, *cur)
	}
	return res
}

func collect() Status {
	st := Status{
		Sinks:   parseDevices("sink", "Sink"),
		Sources: parseDevices("source", "Source"),
		Cards:   parseCards(),
	}
	st.DefaultSink, _ = pactl("get-default-sink")
	st.DefaultSink = strings.TrimSpace(st.DefaultSink)
	st.DefaultSource, _ = pactl("get-default-source")
	st.DefaultSource = strings.TrimSpace(st.DefaultSource)
	for i := range st.Sinks {
		st.Sinks[i].Default = st.Sinks[i].Name == st.DefaultSink
	}
	for i := range st.Sources {
		st.Sources[i].Default = st.Sources[i].Name == st.DefaultSource
	}
	return st
}

// listen: подписка на события pipewire/pulse (pactl subscribe).
// D-Bus org.PulseAudio.Core1 на PipeWire недоступен, поэтому так.
// Дедупликация + debounce 200 мс защищают от шторма событий при драге громкости.
func listen() {
	em := &emitter{}
	em.emit(collect())
	flush := debounce(200*time.Millisecond, func() { em.emit(collect()) })

	cmd := exec.Command("pactl", "subscribe")
	pipe, err := cmd.StdoutPipe()
	if err != nil {
		fail(err, "")
	}
	if err := cmd.Start(); err != nil {
		fail(err, "")
	}
	sc := bufio.NewScanner(pipe)
	for sc.Scan() {
		flush()
	}
	cmd.Wait()
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
		fmt.Fprintln(os.Stderr, "usage: jes-audio <status|listen|sinks|sources|cards|set-default|set-volume|toggle-mute|set-profile> ...")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "status":
		emit(collect())
	case "listen":
		listen()
	case "sinks":
		emit(parseDevices("sink", "Sink"))
	case "sources":
		emit(parseDevices("source", "Source"))
	case "cards":
		emit(parseCards())
	case "set-default":
		act(pactl("set-default-sink", os.Args[2]))
	case "set-volume":
		kind := "--sink"
		if len(os.Args) > 4 && os.Args[4] == "source" {
			kind = "--source"
		}
		act(pamixer(kind, os.Args[2], "--set-volume", os.Args[3]))
	case "toggle-mute":
		kind := "--sink"
		if len(os.Args) > 3 && os.Args[3] == "source" {
			kind = "--source"
		}
		act(pamixer(kind, os.Args[2], "--toggle-mute"))
	case "set-profile":
		act(pactl("set-card-profile", os.Args[2], os.Args[3]))
	default:
		fmt.Fprintln(os.Stderr, "jes-audio: unknown command:", os.Args[1])
		os.Exit(2)
	}
}
