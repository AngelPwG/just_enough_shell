package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

const (
	pipePath   = "/tmp/cava_eww.fifo"
	lockPath   = "/tmp/cava_eww.lock"
	pidPath    = "/tmp/cava_eww.pid"
	configPath = "/tmp/cava_eww_config"
	configContent = `[general]
bars = 20
framerate = 60
sleep_timer = 1
[input]
method = pulse
[output]
method = raw
raw_target = /tmp/cava_eww.fifo
data_format = ascii
ascii_max_range = 7
`
)

var blocks = []rune{'▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'}

const maxRestarts = 3

func cleanup(cmd *exec.Cmd) {
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
	syscall.Unlink(pipePath)
	os.Remove(configPath)
	os.Remove(pidPath)
}

func main() {
	// 1. Синглтон через flock: второй инстанс БЛОКИРУЕТСЯ здесь, пока
	//    старый жив. Убирает гонки двух обёрток на одном FIFO —
	//    раньше строки портились/терялись при пересечении инстансов.
	lockFile, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0644)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Failed to open lock file:", err)
		os.Exit(1)
	}
	defer lockFile.Close()
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX); err != nil {
		fmt.Fprintln(os.Stderr, "Failed to acquire lock:", err)
		os.Exit(1)
	}

	// 2. Убиваем ТОЛЬКО cava, запущенную предыдущим инстансом этой обёртки
	//    (pidfile), а не все cava в системе — pkill -x ломал чужие cava.
	if data, err := os.ReadFile(pidPath); err == nil {
		if pid := strings.TrimSpace(string(data)); pid != "" {
			_ = exec.Command("kill", pid).Run()
			// даём старому cava закрыть FIFO до пересоздания
			time.Sleep(150 * time.Millisecond)
		}
	}

	// 3. FIFO + конфиг
	syscall.Unlink(pipePath)
	if err := syscall.Mkfifo(pipePath, 0644); err != nil {
		fmt.Fprintln(os.Stderr, "Failed to create FIFO:", err)
		os.Exit(1)
	}
	if err := os.WriteFile(configPath, []byte(configContent), 0644); err != nil {
		fmt.Fprintln(os.Stderr, "Failed to create config:", err)
		os.Exit(1)
	}

	// 4. Запуск cava (с супервизором — рестарт до maxRestarts при падении)
	var cmd *exec.Cmd
	startCava := func() bool {
		cmd = exec.Command("cava", "-p", configPath)
		if err := cmd.Start(); err != nil {
			fmt.Fprintln(os.Stderr, "Failed to start cava:", err)
			return false
		}
		_ = os.WriteFile(pidPath, []byte(fmt.Sprint(cmd.Process.Pid)), 0644)
		return true
	}

	// Graceful shutdown: убить cava, прибрать за собой, exit 0
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigChan
		cleanup(cmd)
		os.Exit(0)
	}()

	if !startCava() {
		cleanup(nil)
		os.Exit(1)
	}

	pipe, err := os.Open(pipePath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Failed to open FIFO:", err)
		cleanup(cmd)
		os.Exit(1)
	}
	defer pipe.Close()

	lastOutput := ""
	var builder strings.Builder
	builder.Grow(64) // 20 рун по 3 байта + запас

	restarts := 0
	for {
		scanner := bufio.NewScanner(pipe)
		scanner.Buffer(make([]byte, 4096), 1024*1024)

		for scanner.Scan() {
			line := scanner.Text()
			builder.Reset()

			// Быстрая замена без регулярок
			for _, char := range line {
				if char >= '0' && char <= '7' {
					builder.WriteRune(blocks[char-'0'])
				}
				// Пропускаем ';' и другие символы
			}

			result := builder.String()

			// Выводим только при изменении
			if result != lastOutput {
				fmt.Println(result)
				lastOutput = result
			}
		}

		// cava умер (записывающая сторона закрылась) — рестартим,
		// FIFO и read-fd остаются валидными, новый cava откроет их заново
		if restarts >= maxRestarts {
			fmt.Fprintln(os.Stderr, "cava died permanently after", maxRestarts, "restarts")
			cleanup(cmd)
			os.Exit(3) // != 0 — StreamManager снаружи тоже порестартует обёртку
		}
		restarts++
		fmt.Fprintf(os.Stderr, "cava died, restart #%d\n", restarts)
		time.Sleep(300 * time.Millisecond)
		if !startCava() {
			cleanup(cmd)
			os.Exit(1)
		}
	}
}