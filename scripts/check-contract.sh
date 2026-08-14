#!/usr/bin/env bash
# Diff the Go Dashboard's JSON tags against the Swift decoder's CodingKeys.
#
# The golden fixture in app/Tests cannot catch this. It is a checked-in file, so
# a rename on the *Go* side leaves it untouched and the Swift test stays green —
# which is precisely the drift it was added to catch. A tag diff catches renames
# on the side that makes them.
#
# Run from anywhere; resolves paths relative to the repo root.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
go_src="$root/dashboard.go"
swift_src="$root/app/Sources/DishWatch/Model/DishData.swift"

# Keys the Go side emits but Swift deliberately does not decode.
# `sessDropAvg`: docs/macos-ui.md rules a mean loss figure out of the UI, so not
# decoding it means no view can reach for it by accident.
allow_go_only=( sessDropAvg )

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Go: every `json:"name"` tag inside the Dashboard struct.
awk '/^type Dashboard struct \{/{inside=1; next} inside && /^\}/{exit} inside' "$go_src" \
  | grep -o 'json:"[^",]*"' | sed 's/json:"//; s/"//' | sort -u > "$tmp/go.txt"

# Swift: the CodingKeys of DishData plus ObservedStats. Both `case a, b, c`
# lists and `case name = "wireName"` forms.
awk '/enum CodingKeys/{inside=1; next} inside && /^\s*\}/{inside=0} inside' "$swift_src" \
  | sed 's://.*::' \
  | grep -o 'case .*' \
  | sed 's/^case //' \
  | tr ',' '\n' \
  | sed 's/.*= *"\([^"]*\)".*/\1/; s/^ *//; s/ *$//' \
  | grep -v '^$' | sort -u > "$tmp/swift.txt"

for k in "${allow_go_only[@]}"; do echo "$k"; done | sort -u > "$tmp/allow.txt"

go_only="$(comm -23 "$tmp/go.txt" "$tmp/swift.txt" | comm -23 - "$tmp/allow.txt")"
swift_only="$(comm -13 "$tmp/go.txt" "$tmp/swift.txt")"

# The version constants have to agree too, or the strict decode fails at runtime
# on a build that compiled fine.
go_ver="$(grep -o 'DashboardSchemaVersion = [0-9]*' "$go_src" | grep -o '[0-9]*$' || true)"
swift_ver="$(grep -o 'expectedSchema = [0-9]*' "$swift_src" | grep -o '[0-9]*$' || true)"

fail=0
if [ -n "$go_only" ]; then
  echo "Go emits keys Swift never decodes:" >&2
  echo "$go_only" | sed 's/^/  /' >&2
  echo "  → add a CodingKey, or add it to allow_go_only with a reason." >&2
  fail=1
fi
if [ -n "$swift_only" ]; then
  echo "Swift decodes keys Go never emits:" >&2
  echo "$swift_only" | sed 's/^/  /' >&2
  fail=1
fi
if [ -z "$go_ver" ] || [ -z "$swift_ver" ]; then
  echo "could not read the schema version from both sides (go='$go_ver' swift='$swift_ver')" >&2
  fail=1
elif [ "$go_ver" != "$swift_ver" ]; then
  echo "schema version mismatch: dashboard.go=$go_ver DishData.swift=$swift_ver" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "contract ok — $(wc -l < "$tmp/go.txt" | tr -d ' ') keys, schema v$go_ver"
