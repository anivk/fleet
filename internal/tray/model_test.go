package tray

import "testing"

func TestDecodeHost(t *testing.T) {
	j := []byte(`{"host":"my-nyc","location":"nyc","mode":"server","session_running":true,
	  "sessions":[{"agent":"my-nyc-space-2","short":"space-2","alive":true,"status":"waiting",
	  "alert":true,"since":1721430000,"summary":"Proceed?","source":"hook","tmux":"fleet:2.1","rc":"my-nyc-space-2"}]}`)
	h, err := DecodeHost(j)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if h.Name != "my-nyc" || len(h.Sessions) != 1 {
		t.Fatalf("bad host: %+v", h)
	}
	if !h.Sessions[0].Alert || h.Sessions[0].Short != "space-2" {
		t.Fatalf("bad session: %+v", h.Sessions[0])
	}
}

func TestNewAlerts(t *testing.T) {
	s := func(alert bool, since int64) Session {
		return Session{Agent: "a", Short: "space-1", Alert: alert, Since: since}
	}
	prev := []Host{{Short: "nyc", Sessions: []Session{s(false, 1)}}}
	cur := []Host{{Short: "nyc", Sessions: []Session{s(true, 2)}}}
	if got := NewAlerts(prev, cur); len(got) != 1 {
		t.Fatalf("want 1 new alert, got %d", len(got))
	}
	// Same alert, same since ⇒ not new again:
	if got := NewAlerts(cur, cur); len(got) != 0 {
		t.Fatalf("want 0, got %d", len(got))
	}
}

func TestNewAlertsZeroSince(t *testing.T) {
	// First-time alert with Since:0 (fleet.sh emits this when it can't parse a timestamp)
	// must still fire, even though the seen map's zero-value default is also 0.
	prev := []Host{{Short: "nyc", Sessions: []Session{}}}
	cur := []Host{{Short: "nyc", Sessions: []Session{{Agent: "x", Short: "s", Alert: true, Since: 0}}}}
	if got := NewAlerts(prev, cur); len(got) != 1 {
		t.Fatalf("want 1 new alert for since==0, got %d", len(got))
	}
}
