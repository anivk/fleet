package tray

import "testing"

func TestCacheMarksStale(t *testing.T) {
	p := NewPoller(nil)
	good := Host{Short: "nyc", Name: "my-nyc", Reachable: true, Sessions: []Session{{Short: "space-1"}}}
	p.remember(good)
	// A failed poll for nyc should return the cached copy flagged Stale + not Reachable.
	got := p.fallback("nyc", "my-nyc")
	if got.Stale != true || got.Reachable != false {
		t.Fatalf("want stale+unreachable, got %+v", got)
	}
	if len(got.Sessions) != 1 {
		t.Fatalf("want cached sessions kept, got %d", len(got.Sessions))
	}
	// Never-seen host ⇒ empty unreachable placeholder.
	nf := p.fallback("sf", "my-sf")
	if nf.Reachable || len(nf.Sessions) != 0 {
		t.Fatalf("want empty unreachable, got %+v", nf)
	}
}
