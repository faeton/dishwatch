#!/usr/bin/env bash
# Hold the bash and jq uptime ladders to the same golden file the Go one is
# held to.
#
# The rule is written three times — state.UptimeDur, `sl`'s _sl_uptime_dur, and
# the dwuptime/dwcompound pair inside `sl status`'s jq filter — because the Go
# CLI, the bash fallback and a jq program cannot share an implementation. Three
# copies of one rule drift, and this one drifts invisibly: the header and the
# status dump are different commands, so a reader comparing them has to run
# both and remember. `go test` cannot see either bash copy, which is exactly how
# `up %.1fh` survived in `sl` after the Go side had already moved on.
#
# Both ladders are extracted from `sl` as it ships rather than copied here — a
# check carrying its own copy of the thing under test is a fourth place to
# drift.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SL="$ROOT/sl"
GOLDEN="$ROOT/internal/state/testdata/uptime-ladder.txt"

[ -r "$SL" ]     || { echo "cannot read $SL" >&2; exit 1; }
# Before anything else: is `sl` still a script?
#
# Everything below reads the two ladders straight out of the file with sed and
# awk, which never parses `sl` as shell — so the ladder text can be perfectly
# correct, match Go on all 43 cases, and sit inside a file bash cannot run.
# That is not hypothetical: the jq ladder lives inside a single-quoted shell
# argument, and a lone apostrophe in one of its comments (`Go's`) ended the
# string and broke the whole script while this check still reported ok.
# Under every bash that might run it. `bash` resolves through PATH — Homebrew
# 5.x on this machine — while `sl` is `#!/usr/bin/env bash` and stock macOS
# still ships 3.2.57 at /bin/bash. Checking only the modern one enforces
# nothing about the interpreter most users actually have.
for sh in /bin/bash bash; do
  command -v "$sh" >/dev/null || continue
  "$sh" -n "$SL" || { echo "  $SL is not valid bash under $sh ($("$sh" -c 'echo $BASH_VERSION'))" >&2; exit 1; }
done
[ -r "$GOLDEN" ] || { echo "cannot read $GOLDEN" >&2; exit 1; }
command -v jq >/dev/null || { echo 'jq not installed — sl status needs it too' >&2; exit 1; }

# The bash ladder, sourced out of the script under test.
# Every function the ladder needs, named explicitly. When the ladder grew an
# `_sl_int` dependency this list was the thing that had to change, and until it
# did the check reported 41 bash mismatches — loud and wrong-looking, but not
# silent, which is the property that matters.
SH_FNS="_sl_int _sl_uptime_dur _sl_compound_dur"

ladder_sh=""
for fn in $SH_FNS; do
  # Exactly one definition. A second, indented one later in the file would
  # override it at runtime while this extractor — anchored at column zero —
  # went on validating the original and passing. That is the fail-open shape
  # this whole script exists to avoid, so it is an error, not a preference.
  # Both spellings. bash accepts `name()` AND `function name { ... }`, and the
  # second was a live bypass: appending `function _sl_uptime_dur { printf
  # BROKEN; }` after the validated copy left this count at 1, satisfied every
  # call-site grep, and made the real dash render BROKEN.
  n="$(grep -cE "^[[:space:]]*($fn[[:space:]]*\(\)|function[[:space:]]+$fn\b)" "$SL")"
  [ "$n" = 1 ] || { echo "expected exactly 1 definition of $fn in $SL, found $n" >&2; exit 1; }
  body="$(sed -n "/^$fn() {/,/^}/p" "$SL")"
  printf '%s\n' "$body" | grep -q "^$fn() {" \
    || { echo "could not extract $fn() from $SL" >&2; exit 1; }
  ladder_sh="$ladder_sh
$body"
done
eval "$ladder_sh"

# The jq ladder: from `def dwcompound` up to the first line of the filter proper.
ladder_jq="$(awk '/def dwcompound/{f=1} /\.dishGetStatus as \$s \|/{f=0} f' "$SL" | sed 's/^      //')"
case "$ladder_jq" in
  *def\ dwuptime*) ;;
  *) echo "could not extract the jq ladder from $SL" >&2; exit 1;;
esac
# jq lets a later `def` shadow an earlier one, so a second definition anywhere
# in the filter would be what `sl status` actually runs while this script kept
# testing the first. Same fail-open as the bash side, same answer.
for d in dwuptime dwcompound; do
  n="$(grep -cE "def[[:space:]]+$d[[:space:]]*\(" "$SL")"
  [ "$n" = 1 ] || { echo "expected exactly 1 'def $d(' in $SL, found $n" >&2; exit 1; }
done

# ---- the call sites, not just the definitions ----------------------------
#
# Everything above validates the ladder FUNCTIONS. That is not the same as
# validating what `sl` renders, and the gap is not subtle: reverting the header
# back to `up_h=$(awk "BEGIN{printf \"%.1f\", $UPS/3600}")` leaves both
# definitions untouched and word-perfect, so every case below still passes
# while the dashboard prints `up 1.1h` again. A parity check that cannot see
# its own subject is decoration.
#
# Asserting the call sites textually rather than running `sl dash` is a
# deliberate trade: the real commands need a dish on 192.168.100.1, and a check
# that only works on a machine pointed at a dish would not run in CI, which is
# where drift actually gets caught.
grep -q '^  up_str=$(_sl_uptime_dur "$UPS")' "$SL" \
  || { echo "  the dash header no longer computes up_str via _sl_uptime_dur" >&2; exit 1; }
# The ladder must be the LAST thing to write up_str before the header prints
# it. An existence grep cannot see this: adding
#   up_str=$(awk "BEGIN{printf \"%.1f\", $UPS/3600}")h
# after the blessed line leaves that line intact, satisfies every other check
# here, and puts decimal hours back in the header.
#
# Counting assignments file-wide is the wrong rule — `dash()` legitimately
# reuses up_str for the energy line further down, AFTER the header is out.
# Ordering is the invariant, not multiplicity.
# The boundary sanitise, which is the actual fix for the injection — hardening
# the ladder alone left the payload executing in `dash()`'"'"'s other `(( ))`
# sites while the header rendered a tidy 0s. Deleting this line reopens that,
# and nothing else in this script would notice.
grep -q '^  UPS=$(_sl_int "$UPS")' "$SL" \
  || { echo "  UPS is no longer sanitised at the telemetry boundary — raw UPS reaches (( )) in dash()" >&2; exit 1; }

last_before_header="$(awk '
  /up %s · boots %s/ { print last; exit }
  /^[[:space:]]*up_str=/ { last = $0 }
' "$SL" | sed 's/^[[:space:]]*//')"
[ "$last_before_header" = 'up_str=$(_sl_uptime_dur "$UPS")' ] || {
  echo "  the last up_str= before the dash header is not the ladder:" >&2
  echo "    $last_before_header" >&2
  exit 1
}
grep -q 'up %s · boots %s' "$SL" \
  || { echo "  the dash header format string no longer takes a preformatted uptime" >&2; exit 1; }
grep -q 'Uptime:       \\(dwuptime($up))' "$SL" \
  || { echo "  \`sl status\` no longer renders its uptime through dwuptime" >&2; exit 1; }

# And nothing anywhere may go back to decimal hours. This is the shape the
# whole change existed to remove, so it is worth stating as a rule rather than
# trusting three greps to cover every future call site.
if grep -nE '%\.1f *h|/3600\*10\|floor' "$SL" | grep -iv 'energy\|joule\|wh\b' | grep -q .; then
  echo "  a decimal-hour uptime rendering is back in $SL:" >&2
  grep -nE '%\.1f *h|/3600\*10\|floor' "$SL" | grep -iv 'energy\|joule\|wh\b' | sed 's/^/    /' >&2
  exit 1
fi

fails=0
cases=0
while read -r sec want; do
  case "$sec" in ''|\#*) continue;; esac
  cases=$((cases + 1))

  got_sh="$(_sl_uptime_dur "$sec")"; rc_sh=$?
  if [ "$rc_sh" != 0 ]; then
    # `sl` runs under `set -e` and assigns this in a command substitution, so a
    # non-zero return is not cosmetic — it takes the dashboard down.
    echo "  bash: _sl_uptime_dur($sec) returned $rc_sh" >&2
    fails=$((fails + 1))
  fi
  if [ "$got_sh" != "$want" ]; then
    echo "  bash: _sl_uptime_dur($sec) = '$got_sh', want '$want'" >&2
    fails=$((fails + 1))
  fi

  got_jq="$(jq -rn "$ladder_jq dwuptime($sec)")"
  if [ "$got_jq" != "$want" ]; then
    echo "  jq:   dwuptime($sec) = '$got_jq', want '$want'" >&2
    fails=$((fails + 1))
  fi
done < "$GOLDEN"

# ---- inputs Go cannot express -------------------------------------------
#
# Everything above is a list of int64 seconds, so it exercises the ladder and
# only the ladder: every value in it is already a plain decimal integer, which
# is precisely the state the sanitiser exists to establish. Removing _sl_int
# entirely passes all 53 golden cases.
#
# These are the values that actually arrive. `uptimeS` is a JSON *string* from
# an unauthenticated plaintext service on the LAN, and bash evaluates a string
# operand of `(( ))` as a recursive arithmetic expression — so this table is
# the difference between "formats numbers correctly" and "cannot be made to run
# a command by whatever is answering on 192.168.100.1".
marker="$(mktemp -u "${TMPDIR:-/tmp}/uptime-parity-injection.XXXXXX")"
rm -f "$marker"
hostile_sh=0
while IFS='|' read -r raw want; do
  case "$raw" in \#*) continue;; esac
  cases=$((cases + 1)); hostile_sh=$((hostile_sh + 1))
  got="$(_sl_uptime_dur "$raw" 2>/dev/null)"
  if [ "$got" != "$want" ]; then
    echo "  bash: _sl_uptime_dur('$raw') = '$got', want '$want'" >&2
    fails=$((fails + 1))
  fi
done <<HOSTILE
010|10s
09|9s
0000|0s
007|7s
|0s
abc|0s
1 2|0s
3900; echo pwned|0s
1e6|0s
1.5|0s
-5|0s
-0|0s
+3900|1h5m
 3900|1h5m
0x10|0s
-9223372036854775808|0s
999999999999999999|32150205761y
1000000000000000000|32150205761y
9223372036854775806|296533308798y
9223372036854775807|296533308798y
9223372036854775808|296533308798y
99999999999999999999999999|296533308798y
000000000000000000000000000000000000000000001|0s
BASH_VERSINFO[\$(touch $marker)0]|0s
\$(touch $marker)|0s
a[\$(touch $marker)]|0s
HOSTILE

# The output being "0s" is necessary but not sufficient — a substitution can
# run and still leave the arithmetic evaluating to zero.
if [ -e "$marker" ]; then
  rm -f "$marker"
  echo "  bash: command substitution from telemetry EXECUTED — _sl_int is not holding" >&2
  fails=$((fails + 1))
fi

# jq has one number type, and it is a double. Go's int64 cannot hold 59.9, so
# no golden row can ask what happens to it — but `tonumber` on a hostile or
# merely odd `uptimeS` can produce exactly that.
hostile_jq=0
while IFS='|' read -r raw want; do
  case "$raw" in \#*) continue;; esac
  cases=$((cases + 1)); hostile_jq=$((hostile_jq + 1))
  got="$(jq -rn "$ladder_jq dwuptime($raw)" 2>/dev/null)"
  if [ "$got" != "$want" ]; then
    echo "  jq:   dwuptime($raw) = '$got', want '$want'" >&2
    fails=$((fails + 1))
  fi
done <<'HOSTILE_JQ'
59.9|59s
59.999999|59s
0.4|0s
-0.5|0s
3900.7|1h5m
3661.9|1h1m
HOSTILE_JQ

# Every table must actually have run. A single total was not enough: this
# script has no `set -e`, and when the two heredocs below failed to open
# (`cannot create temp file for here document`) BOTH hostile loops were skipped
# in silence while the 53 golden rows alone carried the total past the
# threshold — so it printed ok having tested none of the inputs it exists for.
golden_n=$((cases - hostile_sh - hostile_jq))
for pair in "golden:$golden_n:40" "hostile-bash:$hostile_sh:15" "hostile-jq:$hostile_jq:6"; do
  name="${pair%%:*}"; rest="${pair#*:}"; got_n="${rest%%:*}"; min_n="${rest#*:}"
  if [ "$got_n" -lt "$min_n" ]; then
    echo "  the $name table ran $got_n cases, expected at least $min_n — it was skipped, not passed" >&2
    exit 1
  fi
done

if [ "$fails" -gt 0 ]; then
  echo "  uptime ladder: $fails mismatch(es) across $cases cases" >&2
  exit 1
fi
echo "  uptime ladder ok — bash and jq match Go across $cases cases"
