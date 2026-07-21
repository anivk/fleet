package main

import "embed"

// The fleet runtime — the bash launcher, shell integration, tmux config, Claude
// hooks, the installer, and the box provisioner — embedded so the single binary
// carries everything it needs to run. Extracted to a cache dir at runtime.
//
//go:embed bin shell hooks bootstrap autostart tmux.conf install.sh
var scriptFS embed.FS
