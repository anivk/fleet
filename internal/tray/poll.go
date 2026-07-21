package tray

import (
	"context"
	"encoding/json"
	"os/exec"
	"sync"
	"time"
)

type hostRef struct {
	Short, Name string
	Local       bool
}

type Poller struct {
	mu         sync.Mutex
	cache      map[string]Host // by short name, last good
	sshTimeout time.Duration
	sshUser    string
}

func NewPoller(_ any) *Poller {
	return &Poller{cache: map[string]Host{}, sshTimeout: 8 * time.Second, sshUser: envOr("FLEET_SSH_USER", "")}
}

func (p *Poller) remember(h Host) { p.mu.Lock(); p.cache[h.Short] = h; p.mu.Unlock() }

// fallback returns the last-good host flagged stale, or an empty unreachable placeholder.
func (p *Poller) fallback(short, name string) Host {
	p.mu.Lock()
	defer p.mu.Unlock()
	if h, ok := p.cache[short]; ok {
		h.Stale = true
		h.Reachable = false
		return h
	}
	return Host{Short: short, Name: name, Reachable: false}
}

// hostList runs `fleet.sh hosts --json`.
func (p *Poller) hostList() []hostRef {
	out, err := exec.Command(fleetBin, "hosts", "--json").Output()
	if err != nil {
		return []hostRef{{Short: "local", Local: true}}
	}
	var raw []struct {
		Short, Host string
		Local       bool
	}
	_ = json.Unmarshal(out, &raw)
	refs := make([]hostRef, 0, len(raw))
	for _, r := range raw {
		refs = append(refs, hostRef{Short: r.Short, Name: r.Host, Local: r.Local})
	}
	return refs
}

func (p *Poller) fetchRemote(ctx context.Context, r hostRef) (Host, error) {
	target := r.Name
	if p.sshUser != "" {
		target = p.sshUser + "@" + r.Name
	}
	remote := `sh -lc 'command -v fleet >/dev/null 2>&1 && exec fleet status --json || exec "$(cat ~/.config/fleet/home 2>/dev/null || echo ~/.fleet)"/bin/fleet.sh status --json'`
	cmd := exec.CommandContext(ctx, "tailscale", "ssh", "-o", "ConnectTimeout=6", target, remote)
	out, err := cmd.Output()
	if err != nil {
		return Host{}, err
	}
	h, err := DecodeHost(out)
	h.Short, h.Name, h.Reachable = r.Short, r.Name, true
	return h, err
}

// PollAll fetches local + every remote concurrently, each bounded by sshTimeout.
func (p *Poller) PollAll(ctx context.Context) []Host {
	refs := p.hostList()
	results := make([]Host, len(refs))
	var wg sync.WaitGroup
	for i, r := range refs {
		wg.Add(1)
		go func(i int, r hostRef) {
			defer wg.Done()
			var h Host
			var err error
			if r.Local {
				h, err = fetchLocal()
			} else {
				c, cancel := context.WithTimeout(ctx, p.sshTimeout)
				defer cancel()
				h, err = p.fetchRemote(c, r)
			}
			if err != nil {
				results[i] = p.fallback(r.Short, r.Name)
				return
			}
			p.remember(h)
			results[i] = h
		}(i, r)
	}
	wg.Wait()
	return results
}
