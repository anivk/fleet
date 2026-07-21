package tray

import (
	"os"
	"os/exec"
)

// fleetBin is the fleet command the tray shells out to for status/hosts/attach/key.
// The parent binary sets it to its own path so the tray drives the same fleet.
var fleetBin = envOr("FLEET_BIN", "fleet")

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

// Run starts the menubar tray, using bin as the fleet command (empty keeps the
// default). Blocks until the tray quits.
func Run(bin string) {
	if bin != "" {
		fleetBin = bin
	}
	runTray() // menu.go
}

// fetchLocal runs `fleet status --json` on this machine.
func fetchLocal() (Host, error) {
	out, err := exec.Command(fleetBin, "status", "--json").Output()
	if err != nil {
		return Host{}, err
	}
	h, err := DecodeHost(out)
	h.Short, h.Local, h.Reachable = "local", true, true
	return h, err
}
