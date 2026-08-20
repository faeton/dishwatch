#!/usr/bin/env bash
# Assert what `sl` RENDERS, by running the real script against fixtures.
#
# check-uptime-parity.sh validates the ladder FUNCTIONS and greps the call
# sites. Both reviewers independently showed that is not the same thing: you
# can leave every function word-perfect, satisfy every grep, and still change
# what the user sees — e.g. by assigning `up_str` a second time after the
# blessed line. Only running the program catches that.
#
# `sl` funnels every RPC through one function (`call()` → grpcurl), so a shim
# first in PATH is enough. No dish, no network, no hardware.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SL="$ROOT/sl"
BIN="$ROOT/tests/bin"
FIX="$ROOT/tests/fixtures"

[ -x "$BIN/grpcurl" ]        || { echo "  missing $BIN/grpcurl" >&2; exit 1; }
[ -r "$FIX/get_status.json" ] || { echo "  missing $FIX/get_status.json" >&2; exit 1; }

# The fixture pins uptimeS; the ladder turns it into this. Both stated here so
# a fixture edit that quietly changes the expectation is visible in the diff.
FIX_UPTIME_S="$(jq -r '.dishGetStatus.deviceState.uptimeS' "$FIX/get_status.json")"
WANT_UPTIME="1h5m"
[ "$FIX_UPTIME_S" = 3900 ] || {
  echo "  fixture uptimeS is $FIX_UPTIME_S, expected 3900 (renders as $WANT_UPTIME)" >&2; exit 1; }

fails=0
run_sl () {  # run_sl <outfile> <args...>
  local out="$1"; shift
  env -i PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
         HOME="$TMPH" LC_ALL=C TERM=dumb \
         "$SHELL_UNDER_TEST" "$SL" "$@" >"$out" 2>"$out.err"
}
strip_ansi () { LC_ALL=C sed 's/\x1b\[[0-9;]*m//g' "$1"; }

for SHELL_UNDER_TEST in /bin/bash bash; do
  command -v "$SHELL_UNDER_TEST" >/dev/null || continue
  ver="$("$SHELL_UNDER_TEST" -c 'echo $BASH_VERSION')"
  TMPH="$(mktemp -d)"

  # ---- sl status: runs to completion, so assert it exactly ----------------
  run_sl "$TMPH/status.out" status
  line="$(strip_ansi "$TMPH/status.out" | sed -n '2p')"
  want="Uptime:       $WANT_UPTIME  (${FIX_UPTIME_S}s, boots=1343)"
  if [ "$line" != "$want" ]; then
    echo "  [$ver] sl status rendered:" >&2
    echo "      got:  '$line'" >&2
    echo "      want: '$want'" >&2
    fails=$((fails + 1))
  fi

  # ---- sl dash: header only ----------------------------------------------
  #
  # Bounded rather than awaited: under an isolated HOME `sl dash` blocks after
  # the header (state lock), so this polls for the header and stops. It is the
  # header that carries the uptime and the header that the `up_str` attack
  # rewrites, so that is the line worth asserting; the panels below it are not
  # covered here and this check does not pretend otherwise.
  ( run_sl "$TMPH/dash.out" dash ) & pid=$!
  n=0
  while [ $n -lt 30 ]; do
    [ -s "$TMPH/dash.out" ] && strip_ansi "$TMPH/dash.out" | grep -q 'Starlink' && break
    sleep 0.2; n=$((n + 1))
  done
  kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null
  hdr="$(strip_ansi "$TMPH/dash.out" | grep -a 'Starlink' | head -1)"
  case "$hdr" in
    *"up $WANT_UPTIME · boots 1343"*) ;;
    "") echo "  [$ver] sl dash produced no header within 6s" >&2; fails=$((fails + 1));;
    *)  echo "  [$ver] sl dash header does not carry '$WANT_UPTIME':" >&2
        echo "      $hdr" >&2
        fails=$((fails + 1));;
  esac

  rm -rf "$TMPH"
done

[ "$fails" = 0 ] || { echo "  sl render: $fails mismatch(es)" >&2; exit 1; }
echo "  sl render ok — real sl status + dash header show $WANT_UPTIME from fixtures"
