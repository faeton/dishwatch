package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
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
//
// Protocol 2 changed no field shapes. It exists because the *meaning* of a
// data-less success was previously ambiguous enough that the client read one as
// a dead pipe — see helperResponse.Data — and because `warning` was added. A
// version bump is cheaper than discovering the disagreement in the field again.
//
// Protocol 3 adds `window` to a poll request. On the wire that is a compatible
// addition — a protocol-2 helper would ignore the field and answer happily — and
// that is exactly why it needs the bump. Ignoring it means returning 60 samples
// to a client that asked for 900 and will caption them "15 m", which is the
// fabricated-window version of every honesty bug this codebase has already
// fixed once. `seriesSeconds` makes the answer self-describing; the bump makes
// sure there is an answer to describe.
const helperProtocol = 3

// helperRequestTimeout bounds one request end to end, including withClient's
// redial. Without it a request inherits the process context, which has no
// deadline: dial (2 s) + fetch (4 s) + redial (2 s) + retry (4 s) already
// stacks past ten seconds, and a reflection stall used to have no bound at all.
// The app applies its own, shorter deadlines; this is the backstop for the case
// where the app is not there to enforce anything.
const helperRequestTimeout = 12 * time.Second

// helperMaxLine caps one request line. Anything larger is discarded and
// answered with an error rather than killing the stream.
const helperMaxLine = 1 << 20

// helperRequest is one line from the app.
type helperRequest struct {
	ID int64  `json:"id"`
	Op string `json:"op"`
	// setAnchor only.
	Pct *float64 `json:"pct,omitempty"`
	Wh  *float64 `json:"wh,omitempty"`
	// poll only: how many seconds of sparkline history to return, clamped to
	// 60–900 by clampSeriesWindow. Absent means the 60 s default.
	Window *int `json:"window,omitempty"`
}

// helperResponse is one line back. Exactly one of Data/Error is meaningful,
// keyed off OK — so a client that forgets to check OK gets a zero value rather
// than a plausible-looking dashboard.
type helperResponse struct {
	ID       int64  `json:"id"`
	Protocol int    `json:"protocol"`
	OK       bool   `json:"ok"`
	Op       string `json:"op,omitempty"` // echoed, so a reply is self-describing
	// Data is present for `poll` and absent for every command op. That is not
	// an error condition: `reboot`, `setAnchor` and `ping` acknowledge with
	// ok=true and no payload. The app used to require Data on every ok reply,
	// so a *successful* reboot raised "ok with no data", which its retry logic
	// read as a dead pipe — killing a healthy helper and re-sending the reboot
	// to a fresh one. Commands are acknowledged, not answered.
	Data  *Dashboard `json:"data,omitempty"`
	Error string     `json:"error,omitempty"`
	// Warning is a non-fatal problem alongside a good result — the dish
	// answered but the accumulators could not be persisted, say. OK stays true.
	Warning string `json:"warning,omitempty"`
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
	// Restricted is true for the `apphelper` build — the one that ships inside
	// the bundle, without the shell-outs, arbitrary-RPC verb or third-party
	// geocoder. The app logs it so a packaging mistake that embeds the full CLI
	// is visible rather than silent.
	Restricted bool `json:"restricted"`
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

	defer h.close()

	// Announce *before* dialing, and dial in the background.
	//
	// This used to dial first. That is up to 2 s of connect plus 3 s of
	// reflection before the first byte of the banner — and the supervisor gives
	// the banner 2 s, because a child that has not identified itself in two
	// seconds is normally a broken child. So precisely when the dish is absent
	// or stalling, which is the case every one of these timeouts exists for, the
	// app killed a perfectly good helper for being slow to say hello, and
	// retried on a backoff forever. First launch with no dish is a core demo
	// path and it would have failed there.
	//
	// Nothing depends on the connection existing at announce time: withClient
	// dials on demand, and a request arriving mid-dial simply waits on h.mu.
	if err := h.out.Encode(helperBanner{
		Protocol:   helperProtocol,
		Helper:     "dishwatch",
		Version:    version,
		Addr:       h.addr,
		PID:        os.Getpid(),
		Restricted: helperOnlyBuild,
	}); err != nil {
		return err
	}

	// Warm the connection so the first poll is fast, holding the same mutex a
	// request would, so an early request queues behind it rather than racing it
	// into a second dial.
	go func() {
		h.mu.Lock()
		defer h.mu.Unlock()
		if h.c != nil {
			return
		}
		dialCtx, cancel := context.WithTimeout(ctx, helperRequestTimeout)
		defer cancel()
		if c, err := dialDish(dialCtx); err == nil {
			h.c = c
		} else {
			fmt.Fprintf(os.Stderr, "helper: initial dial failed (%v) — will retry per request\n", err)
		}
	}()

	// bufio.Reader rather than bufio.Scanner. A Scanner that meets a line over
	// its buffer returns false permanently and cannot be resynchronised, so the
	// cap meant to stop unbounded allocation was really a kill switch: one
	// oversized line ended the helper for good, with the reason going to a
	// stderr the app discards. A Reader lets us drop the offending line, say so,
	// and keep serving.
	rd := bufio.NewReaderSize(os.Stdin, 8192)
	for {
		line, err := readLimitedLine(rd, helperMaxLine)
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil // stdin closed — the app is gone
			}
			if errors.Is(err, errLineTooLong) {
				h.reply(helperResponse{Protocol: helperProtocol, Error: "request too long"})
				continue
			}
			return err
		}
		if len(line) == 0 {
			continue
		}
		var req helperRequest
		if uerr := json.Unmarshal(line, &req); uerr != nil {
			// Fail closed and keep the stream alive: a malformed line is a bug
			// in the client, not a reason to drop the connection it depends on.
			//
			// Echo whatever id survived the parse. Replying with id 0 made the
			// client's id-match guard fail, so a deliberate fail-soft here
			// became a full teardown there — the opposite of the intent.
			h.reply(helperResponse{ID: req.ID, Protocol: helperProtocol, Error: "malformed request: " + uerr.Error()})
			continue
		}
		if ctx.Err() != nil {
			return nil
		}
		h.serve(ctx, req)
	}
}

var errLineTooLong = errors.New("line exceeds limit")

// readLimitedLine reads one newline-terminated line, discarding and reporting
// anything longer than max instead of buffering it.
func readLimitedLine(rd *bufio.Reader, max int) ([]byte, error) {
	var buf []byte
	for {
		chunk, isPrefix, err := rd.ReadLine()
		if err != nil {
			return nil, err
		}
		if len(buf)+len(chunk) <= max {
			buf = append(buf, chunk...)
		} else {
			// Over the limit: keep draining to the newline so the next read
			// starts on a frame boundary, then report.
			for isPrefix {
				_, isPrefix, err = rd.ReadLine()
				if err != nil {
					return nil, err
				}
			}
			return nil, errLineTooLong
		}
		if !isPrefix {
			return buf, nil
		}
	}
}

func (h *helper) serve(parent context.Context, req helperRequest) {
	start := time.Now()
	resp := helperResponse{ID: req.ID, Protocol: helperProtocol, Op: req.Op}

	// `ping` answers before taking the mutex, deliberately.
	//
	// Its job is to say whether this process is still reading its stdin, which
	// is true regardless of what the dish connection is doing. Taking the lock
	// made it wait on whatever holds it — including the warm-up dial, measured
	// at 2 s against an unroutable address, which is twice the deadline the app
	// gives a ping. The probe would have killed the helper for being alive.
	if req.Op == "ping" {
		resp.OK = true
		resp.ElapsedMs = time.Since(start).Milliseconds()
		h.reply(resp)
		return
	}

	h.mu.Lock()
	defer h.mu.Unlock()

	// A panic anywhere under buildDashboard or the integrators used to take the
	// process down mid-reply, losing the in-flight request and every subsequent
	// one until the app noticed EOF. There is no reason a bug in one request
	// should cost the connection: turn it into a failed request.
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "helper: panic serving %q: %v\n", req.Op, r)
			h.reply(helperResponse{
				ID: req.ID, Protocol: helperProtocol, Op: req.Op,
				Error:     fmt.Sprintf("internal error serving %q", req.Op),
				ElapsedMs: time.Since(start).Milliseconds(),
			})
		}
	}()

	// Every request is bounded. Inheriting the process context meant a stalled
	// dish — one that completes its TCP handshake and then stops answering
	// reflection — held this mutex forever, and with it every later request.
	ctx, cancel := context.WithTimeout(parent, helperRequestTimeout)
	defer cancel()

	switch req.Op {
	case "poll":
		window := defaultSeriesWindow
		if req.Window != nil {
			window = *req.Window
		}
		d, warn, err := h.poll(ctx, window)
		if err != nil {
			resp.Error = err.Error()
		} else {
			resp.OK = true
			resp.Data = &d
			resp.Warning = warn
		}
	case "reboot":
		// Same request the `reboot` subcommand sends; the helper is the only
		// writer, so it goes through the shared client rather than dialing.
		//
		// Deliberately not via withClient: that redials and retries on failure,
		// which is right for an idempotent read and wrong for this. A reboot the
		// dish acknowledges and then drops — the normal case, since it is on its
		// way down — looks like a transport error, and the retry sends a second
		// reboot to a dish already rebooting.
		if err := h.callOnce(ctx, []byte(`{"reboot":{}}`)); err != nil {
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
	default:
		resp.Error = "unknown op: " + req.Op
	}

	resp.ElapsedMs = time.Since(start).Milliseconds()
	h.reply(resp)
}

// poll returns the same Dashboard the `json` subcommand emits, so the app's
// decoder is unchanged and the two paths cannot describe the dish differently.
//
// The second return is a non-fatal warning: the dashboard is good but something
// alongside it was not, e.g. the accumulators could not be written.
func (h *helper) poll(ctx context.Context, window int) (Dashboard, string, error) {
	var d Dashboard
	var warn string
	err := h.withClient(ctx, func(c *dish.Client) error {
		s, hist, persistErr, err := fetchDashPersist(ctx, c)
		if err != nil {
			return err
		}
		if persistErr != nil {
			warn = "state not saved: " + persistErr.Error()
		}
		d = buildDashboard(s, hist, h.addr, window)
		return nil
	})
	if err == nil {
		return d, warn, nil
	}
	// An unreachable dish is a normal state for this app, not a protocol
	// failure — report it as data so the UI can show "offline" rather than an
	// error string it has to parse.
	//
	// Only genuine unreachability, though. This used to swallow *every* error
	// class, so a firmware update that renamed a field or withdrew the
	// reflection service produced "Offline" forever on a dish that was up and
	// answering pings — with the real error going to stderr, which the app
	// routes to /dev/null. Nothing could tell anyone what had broken. A decode
	// or reflection failure is a bug report, not a link state.
	if errors.Is(err, dish.ErrUnreachable) || errors.Is(err, context.DeadlineExceeded) {
		_ = state.MarkUnreachable(h.addr)
		return offlineDashboard(h.addr), warn, nil
	}
	return Dashboard{}, warn, err
}

// callOnce sends one request with no retry, for operations that must not be
// repeated. Dials if there is no connection, but never re-sends.
func (h *helper) callOnce(ctx context.Context, reqJSON []byte) error {
	if h.c == nil {
		c, err := dialDish(ctx)
		if err != nil {
			return err
		}
		h.c = c
	}
	_, err := h.c.Call(ctx, reqJSON)
	if err != nil {
		// The connection may well be gone; drop it so the next request dials
		// fresh. We just do not repeat *this* request.
		h.c.Close()
		h.c = nil
	}
	return err
}

// withClient runs fn against a live client, redialing once if the connection
// has gone away. The retry is what makes this survive the dish rebooting
// underneath us without the app having to restart the helper.
//
// Only for idempotent operations. See callOnce for the rest.
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
