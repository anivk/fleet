package tray

import (
	"sync"
	"testing"
)

// TestItemPoolTargetConcurrent exercises getTarget/setTarget concurrently to
// cover the mutex-guarded target access under `go test -race`. It builds a
// bare itemPool (no systray items — systray.Run never runs headless) so it
// can run without a display.
func TestItemPoolTargetConcurrent(t *testing.T) {
	p := &itemPool{target: make([]func(), 4)}

	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		i := i
		wg.Add(2)
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				p.setTarget(i, func() {})
			}
		}()
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				_ = p.getTarget(i)
			}
		}()
	}
	wg.Wait()

	// out-of-range reads must not panic and must return nil.
	if f := p.getTarget(99); f != nil {
		t.Fatalf("expected nil for out-of-range index, got non-nil func")
	}
}
