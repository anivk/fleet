package tray

import (
	"context"
	"fmt"
	"sync"
	"time"

	"fyne.io/systray"
)

func runTray() { systray.Run(onReady, func() {}) }

func onReady() {
	systray.SetTemplateIcon(iconKoalaTemplate, iconKoalaRegular) // B&W koala; badge swaps in vermillion on alerts
	systray.SetTooltip("fleet")
	refresh := systray.AddMenuItem("Refresh now", "")
	systray.AddSeparator()
	quit := systray.AddMenuItem("Quit", "")

	p := NewPoller(nil)
	var prev []Host
	// items are rebuilt each tick by toggling visibility on a fixed pool.
	pool := newItemPool(64)

	render := func() {
		hosts := p.PollAll(context.Background())
		for _, s := range NewAlerts(prev, hosts) {
			notifyAlert(s) // Task 8
		}
		prev = hosts
		badge(hosts)
		pool.reset()
		for _, h := range hosts {
			pool.host(h)
			for _, s := range h.Sessions {
				pool.session(h, s) // click → jump (Task 9)
				if s.Alert && s.Alive {
					h, s := h, s // capture for the closure
					pool.action("        ⏎ approve "+s.Short, func() { approve(h, s) })
				}
			}
		}
		pool.hideRest()
	}

	render()
	ticker := time.NewTicker(5 * time.Second)
	go func() {
		for {
			select {
			case <-ticker.C:
				render()
			case <-refresh.ClickedCh:
				render()
			case <-quit.ClickedCh:
				systray.Quit()
				return
			}
		}
	}()
}

// badge drives the menubar icon: a vermillion koala when any session needs your
// attention (SetIcon keeps the color), and a clean black-and-white koala otherwise
// (SetTemplateIcon — macOS auto-inverts it for light/dark bars; Linux uses the
// regular white variant).
func badge(hosts []Host) {
	alerts := 0
	reach := false
	for _, h := range hosts {
		if h.Reachable || h.Local {
			reach = true
		}
		for _, s := range h.Sessions {
			if s.Alert {
				alerts++
			}
		}
	}
	if alerts > 0 {
		systray.SetIcon(iconKoalaAlert)
		verb := "need"
		if alerts == 1 {
			verb = "needs"
		}
		systray.SetTooltip(fmt.Sprintf("fleet — %d %s you", alerts, verb))
		return
	}
	systray.SetTemplateIcon(iconKoalaTemplate, iconKoalaRegular)
	if reach {
		systray.SetTooltip("fleet — all quiet")
	} else {
		systray.SetTooltip("fleet — no hosts reachable")
	}
}

type itemPool struct {
	items  []*systray.MenuItem
	target []func()
	mu     sync.Mutex
	n      int
}

func newItemPool(size int) *itemPool {
	p := &itemPool{}
	for i := 0; i < size; i++ {
		p.add()
	}
	return p
}

// add creates one menu item plus its process-lifetime click listener.
func (p *itemPool) add() *systray.MenuItem {
	it := systray.AddMenuItem("", "")
	it.Hide()
	idx := len(p.items)
	p.items = append(p.items, it)
	p.mu.Lock()
	p.target = append(p.target, nil)
	p.mu.Unlock()
	// One goroutine per slot for the process lifetime. Captures `it` (not p.items[idx])
	// so a later append that reallocates the slice header can't race this read.
	go func() {
		for range it.ClickedCh {
			if f := p.getTarget(idx); f != nil {
				f()
			}
		}
	}()
	return it
}

func (p *itemPool) getTarget(i int) func() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if i < len(p.target) {
		return p.target[i]
	}
	return nil
}

func (p *itemPool) setTarget(i int, f func()) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.target[i] = f
}

func (p *itemPool) reset() { p.n = 0 }

// next returns the next pooled item, growing the pool (with a bound listener) if exhausted.
func (p *itemPool) next() *systray.MenuItem {
	if p.n >= len(p.items) {
		p.add()
	}
	it := p.items[p.n]
	p.n++
	it.Show()
	return it
}

func (p *itemPool) host(h Host) {
	label := h.Short
	if h.Local {
		label = h.Name + "  (this machine)"
	}
	if !h.Reachable && !h.Local {
		label = h.Short + "  — unreachable"
	}
	it := p.next()
	it.SetTitle(label)
	it.Disable()
}

func (p *itemPool) session(h Host, s Session) {
	mark := "✓"
	if s.Alert {
		mark = "⚠"
	}
	if !s.Alive {
		mark = "✗"
	}
	it := p.next()
	it.SetTitle(fmt.Sprintf("   %s %-10s %-8s %s", mark, s.Short, s.Status, trunc(s.Summary, 48)))
	it.Enable()
	p.setTarget(p.n-1, func() { jump(h, s) })
}

// action adds a clickable pooled item (per-session actions like Approve).
func (p *itemPool) action(label string, fn func()) {
	it := p.next()
	it.SetTitle(label)
	it.Enable()
	p.setTarget(p.n-1, fn)
}

func (p *itemPool) hideRest() {
	for i := p.n; i < len(p.items); i++ {
		p.items[i].Hide()
	}
}

func trunc(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		return string(r[:n-1]) + "…"
	}
	return s
}
