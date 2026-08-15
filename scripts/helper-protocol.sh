#!/usr/bin/env bash
# Print the protocol version a built helper binary announces.
#
# Reads it from the *binary*, not from the source constant, because the thing
# worth catching is a stale `bin/dishwatch-helper`: `app/Makefile` copies that
# path without depending on it, so a protocol bump otherwise ships a bundle
# whose app hangs up on its own engine. Grepping helper.go would agree with the
# Swift side while the binary on disk disagreed with both — which is exactly the
# failure that got shipped once.
#
# Bounded on purpose, though not because of a bug anyone has seen. A review
# argued the helper cannot exit promptly — it announces itself, then warms up a
# dish connection in a goroutine holding the mutex its EOF shutdown also needs,
# so waiting for exit should cost up to the dial timeout. Measured, it does not:
# reading the banner inline returns in ~12 ms against an absent dish and against
# a blackholed address that swallows the SYN.
#
# The probe is bounded anyway, because that promptness is incidental rather than
# contractual — it depends on how the helper happens to sequence its dial
# against its shutdown, which is free to change without anyone thinking about
# this build step. A ceiling here costs one file and makes `make app`'s latency
# independent of that. The banner is the first thing on stdout, so read it and
# kill the child.
#
# `timeout(1)` is deliberately not used: it does not exist on macOS.
set -euo pipefail

helper="${1:?usage: helper-protocol.sh <path-to-helper-binary>}"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

"$helper" helper </dev/null >"$out" 2>/dev/null &
pid=$!

# ~2 s ceiling. The banner is written before any dish I/O, so this is generous.
for _ in $(seq 1 20); do
  [ -s "$out" ] && break
  sleep 0.1
done

kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true

head -1 "$out" | sed -n 's/.*"protocol":\([0-9]*\).*/\1/p'
