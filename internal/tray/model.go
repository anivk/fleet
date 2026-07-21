package tray

import "encoding/json"

type Session struct {
	Agent   string `json:"agent"`
	Short   string `json:"short"`
	Alive   bool   `json:"alive"`
	Status  string `json:"status"`
	Alert   bool   `json:"alert"`
	Since   int64  `json:"since"`
	Summary string `json:"summary"`
	Source  string `json:"source"`
	Tmux    string `json:"tmux"`
	RC      string `json:"rc"`
}

type Host struct {
	Short     string    `json:"-"`    // "local" or FLEET_HOSTS short name
	Name      string    `json:"host"` // owner-location / tailscale name
	Location  string    `json:"location"`
	Mode      string    `json:"mode"`
	Local     bool      `json:"-"`
	Reachable bool      `json:"-"`
	Stale     bool      `json:"-"`
	Sessions  []Session `json:"sessions"`
}

func DecodeHost(b []byte) (Host, error) {
	var h Host
	err := json.Unmarshal(b, &h)
	return h, err
}

// NewAlerts returns sessions that are alerting now but weren't (by agent+since) before.
func NewAlerts(prev, cur []Host) []Session {
	seen := map[string]int64{}
	had := map[string]bool{}
	for _, h := range prev {
		for _, s := range h.Sessions {
			if s.Alert {
				seen[s.Agent] = s.Since
				had[s.Agent] = true
			}
		}
	}
	var out []Session
	for _, h := range cur {
		for _, s := range h.Sessions {
			if s.Alert && (!had[s.Agent] || seen[s.Agent] != s.Since) {
				out = append(out, s)
			}
		}
	}
	return out
}
