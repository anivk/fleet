package tray

import (
	"os/exec"
	"runtime"
	"strings"
)

// attachCommand returns the argv to attach to a session (local or over tailscale).
func attachCommand(h Host, s Session) []string {
	if h.Local {
		return []string{fleetBin, "attach", s.Short}
	}
	target := h.Name
	if u := envOr("FLEET_SSH_USER", ""); u != "" {
		target = u + "@" + h.Name
	}
	remote := `sh -c "\"$(cat ~/.config/fleet/home 2>/dev/null || echo /srv/claude/fleet)\"/bin/fleet.sh attach ` + s.Short + `"`
	return []string{"tailscale", "ssh", "-t", target, remote}
}

// keyCommand returns the argv to send a tmux key to a session (local or remote).
func keyCommand(h Host, s Session, key string) []string {
	if h.Local {
		return []string{fleetBin, "key", s.Short, key}
	}
	target := h.Name
	if u := envOr("FLEET_SSH_USER", ""); u != "" {
		target = u + "@" + h.Name
	}
	remote := `sh -c "\"$(cat ~/.config/fleet/home 2>/dev/null || echo /srv/claude/fleet)\"/bin/fleet.sh key ` + s.Short + ` ` + key + `"`
	return []string{"tailscale", "ssh", target, remote}
}

// approve sends Enter to a waiting agent — accepts Claude's default prompt option
// (usually "yes"). Runs without a terminal (fire-and-forget).
func approve(h Host, s Session) {
	argv := keyCommand(h, s, "Enter")
	_ = exec.Command(argv[0], argv[1:]...).Start()
}

// jump opens a terminal running the attach command.
func jump(h Host, s Session) {
	argv := attachCommand(h, s)
	line := shellJoin(argv)
	switch runtime.GOOS {
	case "darwin":
		script := `tell application "Terminal" to do script "` + escapeQuotes(line) + `"
tell application "Terminal" to activate`
		_ = exec.Command("osascript", "-e", script).Start()
	default:
		if cmd := linuxTerminal(line); cmd != nil {
			_ = cmd.Start()
		} else {
			notifyAlert(Session{Short: s.Short, Summary: "run: " + line})
		}
	}
}

// openBrowser opens claude.ai/code in the default browser.
func openBrowser() {
	url := "https://claude.ai/code"
	switch runtime.GOOS {
	case "darwin":
		_ = exec.Command("open", url).Start()
	default:
		_ = exec.Command("xdg-open", url).Start()
	}
}

// linuxTerminal picks the first available terminal emulator and builds the
// argv to run line in it. Terminal emulators differ in how they take a
// command: gnome-terminal wants "--", the rest use "-e".
func linuxTerminal(line string) *exec.Cmd {
	cands := []struct {
		bin  string
		args []string
	}{
		{"gnome-terminal", []string{"--", "sh", "-c", line + "; exec sh"}},
		{"konsole", []string{"-e", "sh", "-c", line + "; exec sh"}},
		{"x-terminal-emulator", []string{"-e", "sh", "-c", line + "; exec sh"}},
		{"xterm", []string{"-e", "sh", "-c", line + "; exec sh"}},
	}
	for _, c := range cands {
		if p, err := exec.LookPath(c.bin); err == nil {
			return exec.Command(p, c.args...)
		}
	}
	return nil
}

// shellJoin quotes each argv element for safe interpolation into a POSIX
// shell command line (single-quote escaping: close, escaped quote, reopen).
func shellJoin(argv []string) string {
	out := ""
	for i, a := range argv {
		if i > 0 {
			out += " "
		}
		out += "'" + strings.ReplaceAll(a, "'", `'\''`) + "'"
	}
	return out
}
