package tray

import (
	"reflect"
	"strings"
	"testing"
)

func TestAttachCommandLocal(t *testing.T) {
	got := attachCommand(Host{Local: true}, Session{Short: "space-2"})
	want := []string{"fleet.sh", "attach", "space-2"}
	if !reflect.DeepEqual(cmdTail(got), want) {
		t.Fatalf("got %v", got)
	}
}

func TestAttachCommandRemote(t *testing.T) {
	got := attachCommand(Host{Short: "nyc", Name: "my-nyc"}, Session{Short: "space-2"})
	joined := strings.Join(got, " ")
	if !strings.Contains(joined, "tailscale") || !strings.Contains(joined, "my-nyc") || !strings.Contains(joined, "attach space-2") {
		t.Fatalf("remote attach wrong: %q", joined)
	}
}

func TestAttachCommandRemoteSSHUser(t *testing.T) {
	t.Setenv("FLEET_SSH_USER", "bob")
	got := attachCommand(Host{Short: "nyc", Name: "my-nyc"}, Session{Short: "space-2"})
	joined := strings.Join(got, " ")
	if !strings.Contains(joined, "bob@my-nyc") {
		t.Fatalf("remote attach missing ssh user: %q", joined)
	}
}

func cmdTail(c []string) []string { // drop the FLEET_BIN path, keep args
	if len(c) == 0 {
		return c
	}
	return append([]string{"fleet.sh"}, c[1:]...)
}
