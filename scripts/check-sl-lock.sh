#!/usr/bin/env bash
# Exercise the bash fallback's state lock on whatever platform we are on.
#
# This exists because the lock has now been broken once in each direction. The
# original used lockf(1) only, so every Linux run took no lock at all; the fix
# for that dispatched with `A && lockf || B && flock`, which — those operators
# having equal precedence and grouping left to right — parses as
# `((A && lockf) || B) && flock` and therefore ran flock on macOS too, right
# after lockf had already succeeded. flock does not exist there, so the
# condition failed and `sl dash` exited 1 on every single macOS run.
#
# Neither break was visible from the other platform, and neither was visible at
# all from the Go binary, which is what actually gets installed. Hence a test
# that asserts both halves: the lock is taken when free, and — the part that
# matters and that a "return 0 on anything unexpected" bug would silently lose —
# it is REFUSED when genuinely held.
set -uo pipefail

SL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sl"
[ -r "$SL" ] || { echo "cannot read $SL" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Pull in just the lock helpers, so this stays a unit test and never talks to a
# dish. `sed` by function name rather than line number: line numbers rot.
eval "$(awk '/^_sl_lock\(\) \{/,/^\}/' "$SL")"
eval "$(awk '/^_sl_unlock\(\)/' "$SL")"
declare -F _sl_lock >/dev/null || { echo "FAIL: could not extract _sl_lock from $SL" >&2; exit 1; }

# Which locker will _sl_lock choose here? The test needs the matching tool to
# create real contention below.
if command -v lockf >/dev/null 2>&1; then
  locker=lockf
elif command -v flock >/dev/null 2>&1; then
  locker=flock
else
  echo "SKIP: neither lockf nor flock on this host; _sl_lock runs unlocked by design"
  exit 0
fi
echo "locker: $locker"

fail=0

# 1. Uncontended: must acquire.
SL_LOCK="$tmp/free.lock"
if ( _sl_lock ) 2>/dev/null; then
  echo "ok   uncontended acquire"
else
  echo "FAIL uncontended acquire — the lock refused a free file" >&2
  fail=1
fi

# 2. Contended: must refuse, not proceed unlocked. Held for longer than the
#    10s timeout so the wait genuinely expires.
SL_LOCK="$tmp/busy.lock"
: > "$SL_LOCK"
case $locker in
  lockf) lockf -s "$SL_LOCK" sh -c 'sleep 14' & ;;
  flock) flock    "$SL_LOCK" sleep 14          & ;;
esac
holder=$!
sleep 1

start=$(date +%s)
if ( _sl_lock ) 2>/dev/null; then
  echo "FAIL contended acquire — took a lock another process holds" >&2
  fail=1
else
  waited=$(( $(date +%s) - start ))
  if [ "$waited" -lt 8 ]; then
    echo "FAIL contended refusal after only ${waited}s — it did not wait for the lock" >&2
    fail=1
  else
    echo "ok   contended refusal after ${waited}s"
  fi
fi

kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

exit $fail
