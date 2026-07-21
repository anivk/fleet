package tray

import (
	"os/exec"
	"runtime"

	"github.com/gen2brain/beeep"
)

// notifyAlert fires one native desktop notification for a session that has
// newly entered the alert state. It never panics and never blocks the
// caller meaningfully: beeep.Notify is best-effort, and the fallbacks below
// are fire-and-forget external commands whose errors are intentionally
// discarded — a missing notify backend must not crash the render loop.
func notifyAlert(s Session) {
	title := s.Short + " needs you"
	body := s.Summary
	if body == "" {
		body = "waiting for input"
	}
	if err := beeep.Notify(title, body, ""); err == nil {
		return
	}
	switch runtime.GOOS { // fallbacks
	case "darwin":
		script := "display notification " + q(body) + " with title " + q(title)
		_ = exec.Command("osascript", "-e", script).Run()
	default:
		_ = exec.Command("notify-send", title, body).Run()
	}
}

// q wraps s in double quotes for embedding as an AppleScript string
// literal, escaping embedded backslashes and double quotes so the literal
// cannot be broken out of. This is passed as a single -e argument to
// osascript (never shell-interpolated), so there is no shell injection
// risk; escapeQuotes closes the remaining AppleScript-level risk: a raw
// backslash immediately before a quote (e.g. summary containing `\"`)
// would otherwise combine with a naive "only escape quotes" approach to
// produce `\\"` in the output, which AppleScript reads as an escaped
// literal backslash followed by an unescaped, string-terminating quote —
// letting attacker-controlled text break out of the literal and inject
// arbitrary AppleScript. Escaping backslashes first (so `\` becomes `\\`
// and `"` becomes `\"`) keeps every emitted backslash paired with its
// escapee, so the string can never terminate early.
func q(s string) string { return "\"" + escapeQuotes(s) + "\"" }

func escapeQuotes(s string) string {
	out := make([]rune, 0, len(s))
	for _, r := range s {
		if r == '\\' || r == '"' {
			out = append(out, '\\')
		}
		out = append(out, r)
	}
	return string(out)
}
