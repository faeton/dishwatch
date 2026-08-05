package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync"
	"time"

	"github.com/faeton/dishwatch/internal/dish"
	"github.com/faeton/dishwatch/internal/state"
)

// Helper mode: the engine behind the macOS app.
//
// `dishwatch json` spawns a process, dials the dish, downloads reflection
// descriptors and exits — 696 ms, every poll. That cost is process lifetime,
// not IPC, so the fix is to stop paying it: one long-lived child holding one
// connection, answering requests over stdin/stdout for as long as the app is
// running.
//
// Both review passes landed on this shape over linking the Go core in-process
// via cgo. The deciding argument was not performance but blast radius: a fault
// in a c-archive takes the menu bar down with it, while a helper that dies is
// a helper the app restarts. It also keeps one implementation of the energy,
// session and bank semantics — which are not "three small formulas" but a
// persistence authority, owning cursors, reboot epochs, ring-gap rules and
// outage segmentation.
//
// Protocol, deliberately boring:
//
//   - One JSON object per line, both directions. Requests carry an `id`;
//     responses echo it.
//   - stdout is protocol *only*. Anything human-readable goes to stderr, or it
//     corrupts the stream.
//   - A banner is emitted on start so the client can check `protocol` before
//     trusting anything.
//   - EOF on stdin means the app is gone: exit. That is what stops this from
//     becoming an orphan when the app crashes rather than quits.
//
// It is a supervised child, not a daemon: not installed, not detached, not
// registered with launchd.
const helperProtocol = 1

// helperRequest is one line from the app.
type helperRequest struct {
	ID int64  `json:"id"`
	Op string `json:"op"`
	// setAnchor only.
	Pct *float64 `json:"pct,omitempty"`
	Wh  *float64 `json:"wh,omitempty"`
}

// helperResponse is one line back. Exactly one of Data/Error is meaningful,
// keyed off OK — so a client that forgets to check OK gets a zero value rather
// than a plausible-looking dashboard.
type helperResponse struct {
	ID       int64      `json:"id"`
	Protocol int        `json:"protocol"`
	OK       bool       `json:"ok"`
	Data     *Dashboard `json:"data,omitempty"`
	Error    string     `json:"error,omitempty"`
	// Milliseconds spent serving this request, so the app can surface a slow
	// dish and we can measure warm-poll cost without an external harness.
	ElapsedMs int64 `json:"elapsedMs"`
}

type helperBanner struct {
	Protocol int    `json:"protocol"`
	Helper   string `json:"helper"`
	Version  string `json:"version"`
	Addr     string `json:"addr"`
	PID      int    `json:"pid"`
}

// helper owns the dish connection for the life of the process. Requests are
// served one at a time: the accumulators behind buildDashboard are a
// read-modify-write over shared files, and serialising here means the
// cross-process lock is never even contended by our own client.
type helper struct {
	mu   sync.Mutex
	addr string
	c    *dish.Client
	out  *json.Encoder
}

func runHelper(ctx context.Context) error {
	h := &helper{
		addr: envOr("STARLINK_DISH", "192.168.100.1:9200"),
		out:  json.NewEncoder(os.Stdout),
	}
	h.out.SetEscapeHTML(false)

	// Dial eagerly so the first poll is warm, but do not fail to start over it:
	// the app may well launch before the dish is reachable, and a helper that
	// refuses to run is worse than one reporting the dish as offline.
	if c, err := dialDish(ctx); err == nil {
		h.c = c
	} else {
		fmt.Fprintf(os.Stderr, "helper: initial dial failed (%v) — will retry per request\n", err)
	}
	defer h.close()

	if err := h.out.Encode(helperBanner{
		Protocol: helperProtocol,
		Helper:   "dishwatch",
		Version:  version,
		Addr:     h.addr,
		PID:      os.Getpid(),
	}); err != nil {
		return err
	}

	sc := bufio.NewScanner(os.Stdin)
	// Requests are tiny; the cap is only here so a wedged writer cannot make us
	// allocate without bound.
	sc.Buffer(make([]byte, 0, 4096), 1<<20)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var req helperRequest
		if err := json.Unmarshal(line, &req); err != nil {
			// Fail closed and keep the stream alive: a malformed line is a bug
			// in the client, not a reason to drop the connection it depends on.
			h.reply(helperResponse{Protocol: helperProtocol, Error: "malformed request: " + err.Error()})
			continue
		}
		if ctx.Err() != nil {
			return nil
		}
		h.serve(ctx, req)
	}
	if err := sc.Err(); err != nil && err != io.EOF {
		return err
	}
	// stdin closed — the app is gone.
	return nil
}

func (h *helper) serve(ctx context.Context, req helperRequest) {
	start := time.Now()
	resp := helperResponse{ID: req.ID, Protocol: helperProtocol}

	h.mu.Lock()
	defer h.mu.Unlock()

	switch req.Op {
	case "poll":
		d, err := h.poll(ctx)
		if err != nil {
			resp.Error = err.Error()
		} else {
			resp.OK = true
			resp.Data = &d
		}
	case "reboot":
		// Same request the `reboot` subcommand sends; the helper is the only
		// writer, so it goes through the shared client rather than dialing.
		if err := h.withClient(ctx, func(c *dish.Client) error {
			_, err := c.Call(ctx, []byte(`{"reboot":{}}`))
			return err
		}); err != nil {
			resp.Error = err.Error()
		} else {
			resp.OK = true
		}
	case "setAnchor":
		if req.Pct == nil {
			resp.Error = "setAnchor requires pct"
			break
		}
		if _, err := setAnchor(*req.Pct, req.Wh); err != nil {
			resp.Error = err.Error()
		} else {
			resp.OK = true
		}
	case "ping":
		// Liveness without touching the dish — lets the app distinguish "helper
		// wedged" from "dish unreachable".
		resp.OK = true
	default:
		resp.Error = "unknown op: " + req.Op
	}

	resp.ElapsedMs = time.Since(start).Milliseconds()
	h.reply(resp)
}

// poll returns the same Dashboard the `json` subcommand emits, so the app's
// decoder is unchanged and the two paths cannot describe the dish differently.
func (h *helper) poll(ctx context.Context) (Dashboard, error) {
	var d Dashboard
	err := h.withClient(ctx, func(c *dish.Client) error {
		s, hist, err := fetchDash(ctx, c) // also integrates energy + saves state
		if err != nil {
			return err
		}
		loc, _ := c.GetLocation(ctx)
		d = buildDashboard(s, hist, loc, h.addr)
		return nil
	})
	if err != nil {
		// An unreachable dish is a normal state for this app, not a protocol
		// failure — report it as data so the UI can show "offline" rather than
		// an error string it has to parse.
		_ = state.MarkUnreachable(h.addr)
		return offlineDashboard(h.addr), nil
	}
	return d, nil
}

// withClient runs fn against a live client, redialing once if the connection
// has gone away. The retry is what makes this survive the dish rebooting
// underneath us without the app having to restart the helper.
func (h *helper) withClient(ctx context.Context, fn func(*dish.Client) error) error {
	if h.c == nil {
		c, err := dialDish(ctx)
		if err != nil {
			return err
		}
		h.c = c
	}
	err := fn(h.c)
	if err == nil {
		return nil
	}
	// Drop the connection and try once more with a fresh one. Reflection
	// descriptors live on the client, so this reacquires those too — which is
	// what a firmware update on the far end requires.
	fmt.Fprintf(os.Stderr, "helper: request failed (%v) — redialing\n", err)
	h.c.Close()
	h.c = nil
	c, derr := dialDish(ctx)
	if derr != nil {
		return derr
	}
	h.c = c
	return fn(h.c)
}

func (h *helper) reply(r helperResponse) {
	if err := h.out.Encode(r); err != nil {
		// stdout is gone; nothing left to talk to.
		fmt.Fprintf(os.Stderr, "helper: write failed: %v\n", err)
		os.Exit(1)
	}
}

func (h *helper) close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.c != nil {
		h.c.Close()
		h.c = nil
	}
}
