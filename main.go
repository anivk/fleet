// Command fleet is the single-binary distribution: it carries the bash launcher,
// tray, and provisioner embedded, so one file per OS/arch is the whole tool.
//
//	fleet <cmd> …   runs the embedded launcher (start, status, remote, install, …)
//	fleet tray      runs the menubar app in-process (no separate binary/.app)
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"

	"github.com/anivk/fleet/internal/tray"
)

func main() {
	args := os.Args[1:]
	self, _ := os.Executable()

	// `fleet tray` / `fleet tray run` runs the menubar app in this process. Other
	// tray subcommands (start/stop/status) fall through to the bash launcher, which
	// manages the tray process by re-invoking `$FLEET_BIN tray run`.
	if len(args) >= 1 && args[0] == "tray" && (len(args) == 1 || args[1] == "run") {
		tray.Run(self)
		return
	}

	// Everything else: unpack the embedded runtime and hand off to the bash launcher.
	dir, err := extractScripts()
	if err != nil {
		fmt.Fprintln(os.Stderr, "fleet: could not unpack runtime:", err)
		os.Exit(1)
	}
	sh := filepath.Join(dir, "bin", "fleet.sh")
	bash, err := exec.LookPath("bash")
	if err != nil {
		fmt.Fprintln(os.Stderr, "fleet: bash not found — fleet needs bash and tmux installed")
		os.Exit(1)
	}
	env := append(os.Environ(),
		"FLEET_HOME="+dir, // the launcher self-locates here for shell/tmux/hooks
		"FLEET_BIN="+self, // so it (and the tray) re-invoke this same binary
		"FLEET_BUNDLED=1", // install.sh skips the shell-function wiring (the binary IS the command)
	)
	argv := append([]string{bash, sh}, args...)
	if err := syscall.Exec(bash, argv, env); err != nil {
		fmt.Fprintln(os.Stderr, "fleet:", err)
		os.Exit(1)
	}
}
