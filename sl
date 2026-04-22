#!/usr/bin/env bash
# sl — tiny Starlink status CLI. Requires: grpcurl, jq.
# Usage: sl [status|dash|watch [s]|history|location|map|reboot|events [N]|raw '<json>']
set -euo pipefail
DISH="${STARLINK_DISH:-192.168.100.1:9200}"
SVC="SpaceX.API.Device.Device/Handle"
SL_CACHE="$HOME/.cache/sl"
SL_STATE="$SL_CACHE/state.json"
SL_EVENTS="$SL_CACHE/events.log"
SL_PB_ANCHOR="$SL_CACHE/pb.json"
# Power-bank model. Wh = dish-input energy per full 100% charge (calibrated
# via bank-% vs integrated Wh). Override with env vars.
SL_PB_WH="${SL_PB_WH:-}"
SL_PB_START_PCT="${SL_PB_START_PCT:-100}"
mkdir -p "$SL_CACHE"

for _bin in grpcurl jq; do
  if ! command -v "$_bin" >/dev/null 2>&1; then
    printf '\e[38;5;174mmissing dependency:\e[0m %s\n' "$_bin" >&2
    printf '  install with: brew install grpcurl jq\n' >&2
    exit 127
  fi
done
unset _bin

call() { grpcurl -plaintext -max-time 4 -d "$1" "$DISH" "$SVC"; }

# Humanize a duration in seconds as "1d 2h 3m 4s" (skip zero leading units).
_sl_humanize_dur() {
  local s=$1 d h m
  (( s < 0 )) && s=0
  d=$(( s / 86400 )); s=$(( s % 86400 ))
  h=$(( s / 3600 ));  s=$(( s % 3600 ))
  m=$(( s / 60 ));    s=$(( s % 60 ))
  local out=""
  (( d > 0 )) && out+="${d}d "
  (( h > 0 || ${#out} > 0 )) && out+="${h}h "
  (( m > 0 || ${#out} > 0 )) && out+="${m}m "
  out+="${s}s"
  printf '%s' "$out"
}

# Friendly unreachable message for commands that don't have their own handling.
_sl_die_unreachable() {
  printf '\e[38;5;174mdish unreachable\e[0m at %s\n' "$DISH" >&2
  printf '  · not on the Starlink network? check Wi-Fi / ethernet\n' >&2
  printf '  · dish rebooting or powered off?\n' >&2
  printf '  · try: ping 192.168.100.1\n' >&2
  if [[ -s "$SL_STATE" ]]; then
    local ts age
    ts=$(jq -r .ts "$SL_STATE" 2>/dev/null || echo 0)
    age=$(( $(date +%s) - ts ))
    printf '  · last seen %s ago — run \x1b[38;5;253msl dash\x1b[0m for frozen snapshot + events\n' "$(_sl_humanize_dur "$age")" >&2
  fi
  _sl_mark_unreachable 2>/dev/null || true
  exit 1
}
safe_call() { call "$1" 2>/dev/null || _sl_die_unreachable; }

# Event logger: "YYYY-MM-DD HH:MM:SS  TAG  message"
_sl_log() {
  local tag="$1"; shift
  printf '%s  %-10s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$tag" "$*" >> "$SL_EVENTS"
  # Keep last 2000 lines
  if [[ $(wc -l <"$SL_EVENTS" 2>/dev/null || echo 0) -gt 2000 ]]; then
    tail -n 1500 "$SL_EVENTS" > "$SL_EVENTS.tmp" && mv "$SL_EVENTS.tmp" "$SL_EVENTS"
  fi
}

# Compare current snapshot vs stored; log transitions; update store.
# Input JSON (on stdin): { ts, boots, uptimeS, state, disable, alerts, ready_all, ping, drop }
_sl_diff_and_log() {
  local cur="$1"
  local prev=""
  [[ -s "$SL_STATE" ]] && prev=$(cat "$SL_STATE")

  if [[ -z "$prev" ]]; then
    _sl_log "SESSION" "first snapshot — boots=$(echo "$cur"|jq -r .boots) uptime=$(echo "$cur"|jq -r .uptimeS)s"
  else
    local pb cb pu cu ps cs pd cd pa ca pr cr
    pb=$(echo "$prev"|jq -r .boots); cb=$(echo "$cur"|jq -r .boots)
    pu=$(echo "$prev"|jq -r .uptimeS); cu=$(echo "$cur"|jq -r .uptimeS)
    ps=$(echo "$prev"|jq -r .state); cs=$(echo "$cur"|jq -r .state)
    pd=$(echo "$prev"|jq -r .disable); cd=$(echo "$cur"|jq -r .disable)
    pa=$(echo "$prev"|jq -r .alerts); ca=$(echo "$cur"|jq -r .alerts)
    pr=$(echo "$prev"|jq -r .ready_all); cr=$(echo "$cur"|jq -r .ready_all)
    local pts cts
    pts=$(echo "$prev"|jq -r .ts); cts=$(echo "$cur"|jq -r .ts)
    local gap=$(( cts - pts ))

    # Dish rebooted if boots increased, OR uptime went backwards
    if [[ "$cb" != "$pb" ]]; then
      _sl_log "REBOOT" "dish rebooted (boots ${pb}→${cb})"
    elif (( cu < pu )); then
      _sl_log "REBOOT" "dish uptime reset (${pu}→${cu}s, same bootcount ${cb})"
    fi
    # Gap = we were away. Attribute cause.
    if (( gap > 30 )); then
      local ghuman; ghuman=$(_sl_humanize_dur "$gap")
      if [[ "$cb" != "$pb" ]]; then
        _sl_log "GAP"  "${ghuman} unseen — dish rebooted during gap"
      else
        _sl_log "GAP"  "${ghuman} unseen — dish stayed up (local/Wi-Fi side)"
      fi
    fi
    [[ "$cs" != "$ps" ]] && _sl_log "STATE"  "$ps → $cs"
    [[ "$cd" != "$pd" ]] && _sl_log "SERVICE" "$pd → $cd"
    [[ "$cr" != "$pr" ]] && _sl_log "READY"  "all-ready $pr → $cr"
    [[ "$ca" != "$pa" ]] && _sl_log "ALERTS" "$pa → $ca"
  fi
  printf '%s' "$cur" > "$SL_STATE"
}

_sl_mark_unreachable() {
  # Rate-limit: one UNREACH line per minute
  local last_ur last_ts now
  now=$(date +%s)
  last_ur=$(grep -E '  UNREACH    ' "$SL_EVENTS" 2>/dev/null | tail -1 || true)
  if [[ -n "$last_ur" ]]; then
    last_ts=$(date -j -f '%Y-%m-%d %H:%M:%S' "$(echo "$last_ur"|awk '{print $1" "$2}')" +%s 2>/dev/null || echo 0)
    (( now - last_ts < 60 )) && return 0
  fi
  _sl_log "UNREACH" "dish/api not answering ($DISH)"
}

# Reverse-geocode lat/lon → "Town, Region, Country". Cached per ~1km cell.
_sl_geocode() {
  local lat="$1" lon="$2"
  local key; key=$(awk "BEGIN{printf \"%.2f_%.2f\", $lat, $lon}")
  local f="$SL_CACHE/geo_${key}.txt"
  if [[ -s "$f" ]]; then cat "$f"; return; fi
  local r
  r=$(curl -sS --max-time 3 -A "sl-cli/1.0" \
    "https://nominatim.openstreetmap.org/reverse?lat=${lat}&lon=${lon}&zoom=12&format=json&accept-language=en" 2>/dev/null \
    | jq -r '[.address.city // .address.town // .address.village // .address.suburb // .address.county // empty, .address.state // empty, .address.country // empty] | map(select(. != "")) | join(", ")' 2>/dev/null)
  [[ -z "$r" ]] && r="unknown"
  printf '%s' "$r" > "$f"
  printf '%s' "$r"
}

# ---------- ANSI helpers ----------
# 256-color palette (soft pastel to match the mo look)
C_HDR=$'\e[38;5;146m'     # soft purple for headers
C_LBL=$'\e[38;5;250m'     # label grey
C_VAL=$'\e[38;5;253m'     # value light
C_DIM=$'\e[38;5;244m'     # dim
C_OK=$'\e[38;5;108m'      # muted green
C_WARN=$'\e[38;5;179m'    # amber
C_ERR=$'\e[38;5;174m'     # muted red
C_BAR_BG=$'\e[38;5;236m'  # bar track
R=$'\e[0m'

hr() { printf '%s' "$C_DIM"; printf '─%.0s' $(seq 1 "${1:-40}"); printf '%s' "$R"; }

# bar PCT WIDTH [color_override]  → prints fixed-width bar
bar() {
  local pct=${1%.*}; local w=${2:-14}; local ov=${3:-}
  [[ -z "$pct" || "$pct" =~ [^0-9-] ]] && pct=0
  (( pct > 100 )) && pct=100; (( pct < 0 )) && pct=0
  local f=$(( pct*w/100 ))
  (( pct > 0 && f == 0 )) && f=1          # tiny % still shows 1 block
  (( pct < 100 && f == w )) && f=$((w-1)) # never visually full unless exactly 100
  local e=$(( w-f ))
  local c="$C_OK"; (( pct >= 60 )) && c="$C_WARN"; (( pct >= 85 )) && c="$C_ERR"
  [[ -n "$ov" ]] && c="$ov"
  local full="" empty=""
  (( f > 0 )) && full=$(printf '█%.0s' $(seq 1 "$f"))
  (( e > 0 )) && empty=$(printf '░%.0s' $(seq 1 "$e"))
  printf '%s%s%s%s%s' "$c" "$full" "$C_BAR_BG" "$empty" "$R"
}

# join two column-lines into one row (left 42 cols, right rest)
row() { printf '%b%-42s%b   %b\n' "" "$1" "" "$2"; }

# ---------- dashboard ----------
dash() {
  local json
  if ! json=$(call '{"get_status":{}}' 2>/dev/null); then
    _sl_mark_unreachable
    _dash_unreachable
    return 0
  fi

  # eval shell vars from jq
  eval "$(echo "$json" | jq -r '
    .dishGetStatus as $s |
    ($s.obstructionStats // {}) as $o |
    ($s.alignmentStats // {}) as $al |
    ($s.gpsStats // {}) as $g |
    ($s.alerts // {}) as $a |
    ($s.readyStates // {}) as $r |
    @sh "HW=\($s.deviceInfo.hardwareVersion)",
    @sh "SW=\($s.deviceInfo.softwareVersion)",
    @sh "COUNTRY=\($s.deviceInfo.countryCode // "?")",
    @sh "BOOTS=\($s.deviceInfo.bootcount // 0)",
    @sh "UPS=\($s.deviceState.uptimeS // 0)",
    @sh "CLASS=\($s.classOfService // "?")",
    @sh "MOB=\($s.mobilityClass // "?")",
    @sh "SWUPD=\($s.softwareUpdateState // "?")",
    @sh "ETH=\($s.ethSpeedMbps // 0)",
    @sh "DOWN_BPS=\($s.downlinkThroughputBps // 0)",
    @sh "UP_BPS=\($s.uplinkThroughputBps // 0)",
    @sh "PING=\($s.popPingLatencyMs // 0)",
    @sh "DROP=\($s.popPingDropRate // 0)",
    @sh "SNR_OK=\($s.isSnrAboveNoiseFloor // false)",
    @sh "SNR_LOW=\($s.isSnrPersistentlyLow // false)",
    @sh "OBS_FRAC=\($o.fractionObstructed // 0)",
    @sh "OBS_VALID=\($o.validS // 0)",
    @sh "OBS_TIME=\($o.timeObstructed // 0)",
    @sh "PATCHES=\($o.patchesValid // 0)",
    @sh "AZ=\($s.boresightAzimuthDeg // 0)",
    @sh "EL=\($s.boresightElevationDeg // 0)",
    @sh "AZ_WANT=\($al.desiredBoresightAzimuthDeg // 0)",
    @sh "EL_WANT=\($al.desiredBoresightElevationDeg // 0)",
    @sh "TILT=\($al.tiltAngleDeg // 0)",
    @sh "ATT=\($al.attitudeEstimationState // "?")",
    @sh "GPS_OK=\($g.gpsValid // false)",
    @sh "SATS=\($g.gpsSats // 0)",
    @sh "DL_LIM=\($s.dlBandwidthRestrictedReason // "?")",
    @sh "UL_LIM=\($s.ulBandwidthRestrictedReason // "?")",
    @sh "DISABLE=\($s.disablementCode // "?")",
    @sh "READY_ALL=\(($r | to_entries | map(.value) | all))",
    @sh "READY_STR=\($r | to_entries | map(.key + "=" + (.value|tostring)) | join("  "))",
    @sh "ALERTS=\(($a | [to_entries[] | select(.value==true) | .key]) | if length==0 then "none" else join(", ") end)"
  ')"

  # derived values
  local down_mbps up_mbps ping drop_pct obs_pct time_obs_pct up_h
  down_mbps=$(awk "BEGIN{printf \"%.2f\", $DOWN_BPS/1e6}")
  up_mbps=$(awk "BEGIN{printf \"%.2f\", $UP_BPS/1e6}")
  ping=$(awk "BEGIN{printf \"%.1f\", $PING}")
  drop_pct=$(awk "BEGIN{printf \"%.1f\", $DROP*100}")
  obs_pct=$(awk "BEGIN{printf \"%.2f\", $OBS_FRAC*100}")
  time_obs_pct=$(awk "BEGIN{printf \"%.2f\", $OBS_TIME*100}")
  up_h=$(awk "BEGIN{printf \"%.1f\", $UPS/3600}")
  # % of a nominal 200 Mbps for throughput bars (just visual)
  local dn_pct up_pct
  dn_pct=$(awk "BEGIN{printf \"%d\", ($DOWN_BPS/2e8)*100}")
  up_pct=$(awk "BEGIN{printf \"%d\", ($UP_BPS/4e7)*100}")
  # ping: lower is better — scale 0-200ms inverted
  local ping_pct; ping_pct=$(awk "BEGIN{p=$PING; if(p>100)p=100; printf \"%d\", (p/100)*100}")
  local obs_pct_i; obs_pct_i=${obs_pct%.*}

  # status dot
  local dot dot_color
  if [[ "$READY_ALL" == "true" && "$DISABLE" == "OKAY" ]]; then dot="●"; dot_color=$C_OK; STATE="CONNECTED"
  elif [[ "$DISABLE" != "OKAY" ]]; then dot="●"; dot_color=$C_ERR; STATE="DISABLED"
  else dot="●"; dot_color=$C_WARN; STATE="NOT READY"; fi

  local alerts_color=$C_OK; [[ "$ALERTS" != "none" ]] && alerts_color=$C_ERR

  # ---------- power + energy since boot ----------
  # One get_history call serves PW_NOW, the energy accumulator, and the
  # sparklines below. powerIn[i] is watts at sample i (1 Hz ring, ~60 samples).
  # .current is a monotonic write cursor; we dedupe by last-seen cursor so each
  # watch tick integrates only the samples it hasn't seen.
  local HIST_JSON="" CUR_IDX=0 HIST_LEN=0 PW_NOW=""
  HIST_JSON=$(call '{"get_history":{}}' 2>/dev/null || true)
  if [[ -n "$HIST_JSON" ]] && echo "$HIST_JSON" | jq -e '.dishGetHistory.powerIn' >/dev/null 2>&1; then
    eval "$(echo "$HIST_JSON" | jq -r '
      .dishGetHistory as $h |
      @sh "CUR_IDX=\($h.current | tonumber)",
      @sh "HIST_LEN=\($h.powerIn | length)"')"
    if (( HIST_LEN > 0 && CUR_IDX > 0 )); then
      PW_NOW=$(echo "$HIST_JSON" | jq -r --argjson cur "$CUR_IDX" --argjson len "$HIST_LEN" '
        .dishGetHistory.powerIn as $p |
        $p[((($cur - 1) % $len) + $len) % $len] // empty')
    fi
  fi

  local NOW_TS; NOW_TS=$(date +%s)
  local PREV_BOOTS="" PREV_UPS="" PREV_ENERGY=0 PREV_LAST_CUR="" PREV_OBS_TS="" PREV_OBS_UP=""
  if [[ -s "$SL_STATE" ]]; then
    eval "$(jq -r '
      @sh "PREV_BOOTS=\(.boots // "")",
      @sh "PREV_UPS=\(.uptimeS // "")",
      @sh "PREV_ENERGY=\(.energyWh // 0)",
      @sh "PREV_LAST_CUR=\(.lastCurrent // "")",
      @sh "PREV_OBS_TS=\(.obsStartTs // "")",
      @sh "PREV_OBS_UP=\(.obsStartUptime // "")"' "$SL_STATE" 2>/dev/null || true)"
  fi

  local ENERGY_WH="$PREV_ENERGY" LAST_CUR="$PREV_LAST_CUR"
  local OBS_START_TS="$PREV_OBS_TS" OBS_START_UP="$PREV_OBS_UP"
  local reboot=0
  if [[ -z "$PREV_BOOTS" ]]; then reboot=1
  elif [[ "$BOOTS" != "$PREV_BOOTS" ]]; then reboot=1
  elif [[ -n "$PREV_UPS" ]] && (( UPS < PREV_UPS )); then reboot=1
  fi

  if (( HIST_LEN > 0 )); then
    if (( reboot == 1 )); then
      # Bootstrap from ring: consume last min(uptime, HIST_LEN) samples.
      local nb=$UPS
      (( nb > HIST_LEN )) && nb=$HIST_LEN
      (( nb > CUR_IDX )) && nb=$CUR_IDX
      local boot_j=0
      if (( nb > 0 )); then
        boot_j=$(echo "$HIST_JSON" | jq -r --argjson cur "$CUR_IDX" --argjson len "$HIST_LEN" --argjson n "$nb" '
          .dishGetHistory.powerIn as $p |
          [ range($cur - $n; $cur) | $p[((. % $len) + $len) % $len] | select(type=="number") ] | add // 0')
      fi
      ENERGY_WH=$(awk "BEGIN{printf \"%.4f\", ($boot_j)/3600}")
      OBS_START_TS=$(( NOW_TS - nb ))
      OBS_START_UP=$(( UPS - nb )); (( OBS_START_UP < 0 )) && OBS_START_UP=0
      LAST_CUR=$CUR_IDX
    elif [[ -n "$LAST_CUR" ]]; then
      local delta=$(( CUR_IDX - LAST_CUR ))
      if (( delta > 0 && delta <= HIST_LEN )); then
        local add_j=0
        add_j=$(echo "$HIST_JSON" | jq -r --argjson cur "$CUR_IDX" --argjson len "$HIST_LEN" --argjson d "$delta" '
          .dishGetHistory.powerIn as $p |
          [ range($cur - $d; $cur) | $p[((. % $len) + $len) % $len] | select(type=="number") ] | add // 0')
        ENERGY_WH=$(awk "BEGIN{printf \"%.4f\", $ENERGY_WH + ($add_j)/3600}")
        LAST_CUR=$CUR_IDX
      elif (( delta > HIST_LEN )); then
        # Gap longer than the ring — lost samples; keep accumulator, skip ahead.
        LAST_CUR=$CUR_IDX
      fi
    else
      LAST_CUR=$CUR_IDX
      [[ -z "$OBS_START_TS" ]] && OBS_START_TS=$NOW_TS
      [[ -z "$OBS_START_UP" ]] && OBS_START_UP=$UPS
    fi
  fi
  [[ -z "$ENERGY_WH" ]] && ENERGY_WH=0
  [[ -z "$OBS_START_TS" ]] && OBS_START_TS=$NOW_TS
  [[ -z "$OBS_START_UP" ]] && OBS_START_UP=$UPS
  [[ -z "$LAST_CUR" ]] && LAST_CUR=0

  # Snapshot + log transitions
  local snap; snap=$(jq -cn \
    --argjson ts "$NOW_TS" --argjson boots "$BOOTS" --argjson uptimeS "$UPS" \
    --arg state "$STATE" --arg disable "$DISABLE" --arg alerts "$ALERTS" \
    --arg ready_all "$READY_ALL" --argjson ping "$PING" --argjson drop "$DROP" \
    --argjson energyWh "$ENERGY_WH" --argjson lastCurrent "$LAST_CUR" \
    --argjson obsStartTs "$OBS_START_TS" --argjson obsStartUptime "$OBS_START_UP" \
    '{ts:$ts, boots:($boots|tonumber), uptimeS:($uptimeS|tonumber), state:$state, disable:$disable, alerts:$alerts, ready_all:$ready_all, ping:$ping, drop:$drop, energyWh:$energyWh, lastCurrent:$lastCurrent, obsStartTs:$obsStartTs, obsStartUptime:$obsStartUptime}')
  _sl_diff_and_log "$snap" || true

  # ---------- header ----------
  # In watch mode the outer loop positions the cursor; dash() just emits plain
  # content. Standalone invocation clears once.
  [[ "${SL_WATCH:-}" == "1" ]] || printf '\e[H\e[J'
  printf "\n"
  # two-line header: state + identity / hardware + software
  printf "  %sStarlink%s  %s%s %s%s  %s%s · %s · %s%s  %sup %sh · boots %s%s\n" \
    "$C_HDR" "$R" "$dot_color" "$dot" "$C_VAL" "$STATE" \
    "$C_DIM" "$CLASS" "$MOB" "$COUNTRY" "$R" \
    "$C_DIM" "$up_h" "$BOOTS" "$R"
  printf "  %s%s · fw %s%s\n\n" "$C_DIM" "$HW" "$SW" "$R"

  # ---------- two-column sections ----------
  # compose lines then print side-by-side
  local -a L R_
  L+=("${C_HDR}● Connection$(printf ' ')$(hr 28)${R}")
  R_+=("${C_HDR}↕ Throughput$(printf ' ')$(hr 28)${R}")

  L+=("${C_LBL}State   ${R} ${C_VAL}${STATE}${R}")
  R_+=("${C_LBL}Down    ${R} $(bar $dn_pct 14)  ${C_VAL}${down_mbps} Mbps${R}")

  local ready_short="✓ all"; [[ "$READY_ALL" != "true" ]] && ready_short="${C_ERR}not ready${R}"
  L+=("${C_LBL}Ready   ${R} ${C_OK}${ready_short}${R}  ${C_DIM}scp l1l2 xphy aap rf${R}")
  R_+=("${C_LBL}Up      ${R} $(bar $up_pct 14)  ${C_VAL}${up_mbps} Mbps${R}")

  # Big live ping readout (updates every refresh cycle from get_status)
  local ping_col=$C_OK
  awk "BEGIN{exit !($PING >= 60)}" && ping_col=$C_WARN
  awk "BEGIN{exit !($PING >= 120)}" && ping_col=$C_ERR
  L+=("${C_LBL}Ping    ${R} ${ping_col}${ping} ms${R}  ${C_DIM}drop ${drop_pct}%${R}")
  R_+=("${C_LBL}Ping    ${R} $(bar $ping_pct 14)  ${C_DIM}vs 100ms target${R}")

  L+=("${C_LBL}Alerts  ${R} ${alerts_color}${ALERTS}${R}")
  R_+=("${C_LBL}Limits  ${R} ${C_VAL}dl=${DL_LIM}  ul=${UL_LIM}${R}")

  L+=("")
  R_+=("")

  L+=("${C_HDR}◆ Signal$(printf ' ')$(hr 32)${R}")
  R_+=("${C_HDR}◎ Aim$(printf ' ')$(hr 35)${R}")

  # Dish firmware no longer exposes dB SNR. Synthesize a 0–100 Signal score
  # from the metrics the dish DOES expose: ping, drop rate, obstruction.
  # score = 100 * ping_score * (1 - drop) * (1 - obstruction)   (all clamped)
  local SIG_SCORE
  SIG_SCORE=$(awk "BEGIN{
    p=$PING; d=$DROP; o=$OBS_FRAC;
    ps = (150-p)/150; if(ps<0)ps=0; if(ps>1)ps=1;
    ds = 1-d; if(ds<0)ds=0;
    os = 1-o; if(os<0)os=0;
    s = 100*ps*ds*os;
    if(s<0)s=0; if(s>100)s=100;
    printf \"%.0f\", s
  }")
  [[ "$SNR_OK" != "true" || "$SNR_LOW" == "true" ]] && SIG_SCORE=$(awk "BEGIN{s=$SIG_SCORE*0.5; printf \"%.0f\",s}")
  local sig_col=$C_ERR
  (( SIG_SCORE >= 50 )) && sig_col=$C_WARN
  (( SIG_SCORE >= 75 )) && sig_col=$C_OK
  local flag_str="noise ✓"; [[ "$SNR_LOW" == "true" ]] && flag_str="low ✗"
  [[ "$SNR_OK" != "true" ]] && flag_str="weak ✗"
  L+=("${C_LBL}Signal  ${R} $(bar $SIG_SCORE 14 "$sig_col")  ${sig_col}${SIG_SCORE}/100${R}  ${C_DIM}${flag_str}${R}")
  R_+=("${C_LBL}Azim    ${R} ${C_VAL}$(awk "BEGIN{printf \"%.1f\",$AZ}")°${R}  ${C_DIM}want $(awk "BEGIN{printf \"%.0f\",$AZ_WANT}")°${R}")

  L+=("${C_LBL}Obstr   ${R} $(bar $obs_pct_i 14)  ${C_VAL}${obs_pct}%${R}")
  R_+=("${C_LBL}Elev    ${R} ${C_VAL}$(awk "BEGIN{printf \"%.1f\",$EL}")°${R}  ${C_DIM}want $(awk "BEGIN{printf \"%.0f\",$EL_WANT}")°${R}")

  L+=("${C_LBL}Valid   ${R} ${C_VAL}${OBS_VALID}s${R}  ${C_DIM}patches ${PATCHES}${R}")
  R_+=("${C_LBL}Tilt    ${R} ${C_VAL}$(awk "BEGIN{printf \"%.1f\",$TILT}")°${R}")

  L+=("${C_LBL}Blocked ${R} ${C_VAL}${time_obs_pct}%${R} ${C_DIM}of valid time${R}")
  R_+=("${C_LBL}Attitude${R} ${C_VAL}${ATT}${R}")

  L+=("")
  R_+=("")

  L+=("${C_HDR}⌖ Location$(printf ' ')$(hr 30)${R}")
  R_+=("${C_HDR}⎈ Link$(printf ' ')$(hr 34)${R}")

  # Try to fetch GPS coords (requires user to enable in Starlink app)
  local loc_json lat lon alt place
  loc_json=$(call '{"get_location":{}}' 2>/dev/null || true)
  if echo "$loc_json" | jq -e '.getLocation.lla.lat' >/dev/null 2>&1; then
    lat=$(echo "$loc_json" | jq -r '.getLocation.lla.lat')
    lon=$(echo "$loc_json" | jq -r '.getLocation.lla.lon')
    alt=$(echo "$loc_json" | jq -r '.getLocation.lla.alt // 0')
    place=$(_sl_geocode "$lat" "$lon")
    L+=("${C_LBL}Place   ${R} ${C_VAL}${place}${R}")
    L+=("${C_LBL}Coords  ${R} ${C_VAL}$(awk "BEGIN{printf \"%.4f, %.4f\", $lat, $lon}")${R}  ${C_DIM}alt $(awk "BEGIN{printf \"%.0f\", $alt}")m${R}")
  else
    L+=("${C_LBL}Country ${R} ${C_VAL}${COUNTRY}${R}")
  fi
  local gps_col=$C_OK; [[ "$GPS_OK" != "true" ]] && gps_col=$C_ERR
  L+=("${C_LBL}GPS     ${R} ${gps_col}$([[ $GPS_OK == true ]] && echo ✓ || echo ✗) lock${R}  ${C_DIM}${SATS} sats${R}")

  # Translate SpaceX's disablementCode into a human label
  local svc_str svc_col=$C_OK
  case "$DISABLE" in
    OKAY)                   svc_str="active ✓" ;;
    NO_ACTIVE_ACCOUNT)      svc_str="no account";          svc_col=$C_ERR ;;
    SUSPENDED)              svc_str="suspended (billing)"; svc_col=$C_ERR ;;
    OUT_OF_SERVICE_AREA)    svc_str="outside plan area";   svc_col=$C_ERR ;;
    OUT_OF_REGION)          svc_str="wrong region";        svc_col=$C_ERR ;;
    DISABLED_BY_COMMAND)    svc_str="disabled by SpaceX";  svc_col=$C_ERR ;;
    UNKNOWN_USER_TERMINAL)  svc_str="unrecognized dish";   svc_col=$C_ERR ;;
    INVALID_HARDWARE_VERSION) svc_str="firmware invalid";  svc_col=$C_ERR ;;
    *)                      svc_str="$DISABLE";            svc_col=$C_WARN ;;
  esac
  # Current power draw (Mini exposes it only via get_history.powerIn ring).
  # PW_NOW was extracted from HIST_JSON earlier alongside the energy accumulator.
  local pw_col=$C_OK
  if [[ -n "$PW_NOW" ]]; then
    awk "BEGIN{exit !($PW_NOW >= 25)}" && pw_col=$C_WARN
    awk "BEGIN{exit !($PW_NOW >= 40)}" && pw_col=$C_ERR
    R_+=("${C_LBL}Power   ${R} ${pw_col}$(awk "BEGIN{printf \"%.1f\",$PW_NOW}") W${R}")
  fi
  R_+=("${C_LBL}Ethernet${R} ${C_VAL}${ETH} Mbps${R}")
  R_+=("${C_LBL}Service ${R} ${svc_col}${svc_str}${R}")
  R_+=("${C_LBL}Firmware${R} ${C_VAL}update ${SWUPD}${R}")

  # render
  local n=${#L[@]}
  for ((i=0; i<n; i++)); do
    local lraw lpad
    lraw=$(printf '%s' "${L[i]}" | sed $'s/\033\\[[0-9;]*m//g')
    lpad=$(( 52 - ${#lraw} ))
    (( lpad < 0 )) && lpad=0
    printf '%s%*s%s\n' "${L[i]}" "$lpad" "" "${R_[i]}"
  done

  # ---------- history sparklines (last 60s) ----------
  local hist="$HIST_JSON"
  [[ -z "$hist" ]] && hist='{}'
  if [[ -n "$hist" ]] && echo "$hist" | jq -e '.dishGetHistory' >/dev/null 2>&1; then
    # jq emits: 4 lines, each space-separated numbers (last 60 samples, oldest→newest)
    local data; data=$(echo "$hist" | jq -r '
      .dishGetHistory as $h |
      ($h.current | tonumber) as $cur |
      ($h.popPingLatencyMs | length) as $len |
      (if $cur > $len then $cur - 60 else ([$cur - 60, 0] | max) end) as $start |
      ($cur - 1) as $end |
      # unroll the ring: fetch indices $start..$end modulo $len, oldest→newest
      def unroll(arr): [range($start; $end + 1) | arr[. % $len]];
      (unroll($h.popPingLatencyMs)    | map(tostring) | join(" ")),
      (unroll($h.popPingDropRate)     | map(tostring) | join(" ")),
      (unroll($h.downlinkThroughputBps) | map(tostring) | join(" ")),
      (unroll($h.uplinkThroughputBps)   | map(tostring) | join(" ")),
      ((if ($h.powerIn // null) then unroll($h.powerIn) else [] end) | map(tostring) | join(" "))
    ')
    local pings drops dn up pw
    pings=$(echo "$data" | sed -n '1p')
    drops=$(echo "$data" | sed -n '2p')
    dn=$(echo    "$data" | sed -n '3p')
    pw=$(echo    "$data" | sed -n '5p')
    up=$(echo    "$data" | sed -n '4p')

    # compute means/max for annotations
    local ping_avg ping_max ping_p95 drop_pct_avg dn_max_mbps up_max_mbps dn_avg_mbps up_avg_mbps
    read ping_avg ping_max ping_p95 <<<"$(echo "$pings" | awk '{
      n=0; s=0; m=0;
      for(i=1;i<=NF;i++){ if($i+0>0){ a[n]=$i+0; n++; s+=$i; if($i+0>m)m=$i+0 } }
      if(n==0){ printf "0 0 0"; exit }
      for(i=0;i<n;i++) for(j=i+1;j<n;j++) if(a[i]>a[j]){ t=a[i]; a[i]=a[j]; a[j]=t }
      idx=int(n*0.95); if(idx>=n)idx=n-1;
      printf "%.1f %.1f %.1f", s/n, m, a[idx]
    }')"
    drop_pct_avg=$(echo "$drops" | awk '{s=0; for(i=1;i<=NF;i++)s+=$i; printf "%.1f", (s/NF)*100}')
    read dn_avg_mbps dn_max_mbps <<<"$(echo "$dn" | awk '{s=0;m=0; for(i=1;i<=NF;i++){s+=$i; if($i>m)m=$i} printf "%.2f %.2f", s/NF/1e6, m/1e6}')"
    read up_avg_mbps up_max_mbps <<<"$(echo "$up" | awk '{s=0;m=0; for(i=1;i<=NF;i++){s+=$i; if($i>m)m=$i} printf "%.2f %.2f", s/NF/1e6, m/1e6}')"

    # sparkline rendering
    local SC=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
    spark() {
      # $1=values, $2=fixed max (0/empty = min-max auto-range)
      awk -v umax="${2:-0}" -v vals="$1" 'BEGIN{
        chars[0]="▁";chars[1]="▂";chars[2]="▃";chars[3]="▄";chars[4]="▅";chars[5]="▆";chars[6]="▇";chars[7]="█";
        n=split(vals,a," ");
        mn=1e18; mx=-1e18;
        for(i=1;i<=n;i++){v=a[i]+0; if(v<mn)mn=v; if(v>mx)mx=v}
        if(umax+0>0){mn=0; mx=umax+0}
        rng=mx-mn; if(rng<=0)rng=1;
        for(i=1;i<=n;i++){
          v=a[i]+0; idx=int((v-mn)/rng*7); if(idx<0)idx=0; if(idx>7)idx=7;
          printf "%s", chars[idx];
        }
      }'
    }

    printf '\n%s⏱ Last 60s %s%s\n' "$C_HDR" "$(hr 66)" "$R"
    printf '  %sPing  %s%s%s  %savg %s ms · max %s ms · p95 %s ms · drop %s%%%s\n' \
      "$C_LBL" "$C_OK" "$(spark "$pings" 0)" "$R" "$C_DIM" "$ping_avg" "$ping_max" "$ping_p95" "$drop_pct_avg" "$R"
    local drop_max; drop_max=$(echo "$drops" | awk '{m=0; for(i=1;i<=NF;i++){if($i+0>m)m=$i+0} printf "%.1f", m*100}')
    printf '  %sDrop  %s%s%s  %sper-second loss · peak %s%%%s\n' \
      "$C_LBL" "$C_ERR" "$(spark "$drops" 0)" "$R" "$C_DIM" "$drop_max" "$R"
    printf '  %sDown  %s%s%s  %savg %s Mbps  max %s Mbps%s\n' \
      "$C_LBL" "$C_OK" "$(spark "$dn" "")" "$R" "$C_DIM" "$dn_avg_mbps" "$dn_max_mbps" "$R"
    printf '  %sUp    %s%s%s  %savg %s Mbps  max %s Mbps%s\n' \
      "$C_LBL" "$C_OK" "$(spark "$up" "")" "$R" "$C_DIM" "$up_avg_mbps" "$up_max_mbps" "$R"
    if [[ -n "$pw" ]]; then
      local pw_now pw_avg pw_max
      read pw_now pw_avg pw_max <<<"$(echo "$pw" | awk '{
        s=0;m=0;n=0;last=0;
        for(i=1;i<=NF;i++){v=$i+0; if(v>0){s+=v; n++; if(v>m)m=v; last=v}}
        if(n==0){printf "0 0 0"; exit}
        printf "%.1f %.1f %.1f", last, s/n, m
      }')"
      printf '  %sPower %s%s%s  %snow %s W  avg %s W  max %s W%s\n' \
        "$C_LBL" "$C_WARN" "$(spark "$pw" "")" "$R" "$C_DIM" "$pw_now" "$pw_avg" "$pw_max" "$R"
    fi
    # ---------- energy since boot (integrated from powerIn) ----------
    if awk "BEGIN{exit !(${ENERGY_WH:-0} > 0)}"; then
      local obs_dur=$(( NOW_TS - OBS_START_TS ))
      (( obs_dur < 1 )) && obs_dur=1
      local energy_fmt avg_w_obs est_wh
      energy_fmt=$(awk "BEGIN{printf \"%.2f\", $ENERGY_WH}")
      avg_w_obs=$(awk "BEGIN{printf \"%.1f\", $ENERGY_WH*3600/$obs_dur}")
      est_wh=$(awk "BEGIN{printf \"%.1f\", $ENERGY_WH*$UPS/$obs_dur}")
      local fmt_dur
      fmt_dur() { awk -v s="$1" 'BEGIN{h=int(s/3600); m=int((s%3600)/60); sec=int(s%60);
        if(h>0) printf "%dh%02dm",h,m; else if(m>0) printf "%dm%02ds",m,sec; else printf "%ds",sec}'; }
      local obs_str up_str
      obs_str=$(fmt_dur "$obs_dur")
      up_str=$(fmt_dur "$UPS")
      if (( obs_dur * 100 >= UPS * 95 )); then
        printf '  %sEnergy%s %s%s Wh%s  %ssince boot (%s) · avg %s W%s\n' \
          "$C_LBL" "$R" "$C_VAL" "$energy_fmt" "$R" "$C_DIM" "$up_str" "$avg_w_obs" "$R"
      else
        printf '  %sEnergy%s %s%s Wh%s  %sobs %s @ %s W · est %s Wh over %s%s\n' \
          "$C_LBL" "$R" "$C_VAL" "$energy_fmt" "$R" "$C_DIM" "$obs_str" "$avg_w_obs" "$est_wh" "$up_str" "$R"
      fi

      # ---------- power-bank depletion estimate ----------
      # Opt-in: shown when `sl pb <pct> [wh]` set an anchor with wh, OR when
      # SL_PB_WH env var is set (>0). Anchor depletion is counted directly
      # from integrated Wh since anchor — no extrapolation. If the anchor's
      # bootcount doesn't match the current boot, it's stale.
      local anchor_pct="" anchor_energy="" anchor_ts="" anchor_boots="" anchor_wh="" anchor_source=""
      if [[ -s "$SL_PB_ANCHOR" ]]; then
        eval "$(jq -r '
          @sh "anchor_pct=\(.pct // "")",
          @sh "anchor_energy=\(.energyWh // "")",
          @sh "anchor_ts=\(.ts // "")",
          @sh "anchor_boots=\(.boots // "")",
          @sh "anchor_wh=\(.wh // "")"' "$SL_PB_ANCHOR" 2>/dev/null || true)"
      fi
      # Effective bank Wh: anchor wins, else env var.
      local pb_cap="${anchor_wh:-$SL_PB_WH}"
      if [[ -n "$pb_cap" ]] && awk "BEGIN{exit !($pb_cap+0 > 0)}"; then
      local pb_pct_left pb_used_wh pb_start_pct
      if [[ -n "$anchor_boots" && "$anchor_boots" == "$BOOTS" && -n "$anchor_energy" && -n "$anchor_pct" ]]; then
        pb_used_wh=$(awk "BEGIN{d=$ENERGY_WH-$anchor_energy; if(d<0)d=0; printf \"%.2f\", d}")
        pb_pct_left=$(awk "BEGIN{printf \"%.1f\", $anchor_pct - $pb_used_wh*100/$pb_cap}")
        pb_start_pct="$anchor_pct"
        local anchor_age=$(( NOW_TS - anchor_ts ))
        anchor_source=$(printf 'anchor %s%% set %s ago' "$anchor_pct" "$(fmt_dur "$anchor_age")")
      else
        pb_used_wh=$(awk "BEGIN{printf \"%.2f\", $ENERGY_WH*$UPS/$obs_dur}")
        pb_pct_left=$(awk "BEGIN{printf \"%.1f\", $SL_PB_START_PCT - $pb_used_wh*100/$pb_cap}")
        pb_start_pct="$SL_PB_START_PCT"
        anchor_source=$(printf 'assuming %s%% at boot · set via: sl pb <current%%> [bank_wh]' "$SL_PB_START_PCT")
      fi
      local pb_wh_left sec_left
      pb_wh_left=$(awk "BEGIN{v=$pb_cap*$pb_pct_left/100; if(v<0)v=0; printf \"%.1f\", v}")
      sec_left=$(awk "BEGIN{w=$avg_w_obs+0; if(w<=0){print 0; exit}
        s=$pb_wh_left*3600/w; if(s<0)s=0; printf \"%.0f\", s}")
      local left_str; left_str=$(fmt_dur "$sec_left")
      local pb_col=$C_OK
      awk "BEGIN{exit !($pb_pct_left < 50)}" && pb_col=$C_WARN
      awk "BEGIN{exit !($pb_pct_left < 20)}" && pb_col=$C_ERR
      local pb_bar_pct=${pb_pct_left%.*}
      (( pb_bar_pct < 0 )) && pb_bar_pct=0
      (( pb_bar_pct > 100 )) && pb_bar_pct=100
      printf '  %sBank  %s %s  %s%s%%%s left · %s Wh · %sdies in %s%s\n' \
        "$C_LBL" "$R" "$(bar $pb_bar_pct 14 "$pb_col")" \
        "$pb_col" "$pb_pct_left" "$R" "$pb_wh_left" \
        "$C_VAL" "$left_str" "$R"
      printf '        %s%s · bank=%s Wh%s\n' "$C_DIM" "$anchor_source" "$pb_cap" "$R"
      fi
    fi
  fi

  # ---------- recent events ----------
  if [[ -s "$SL_EVENTS" ]]; then
    local last3; last3=$(tail -n 3 "$SL_EVENTS")
    if [[ -n "$last3" ]]; then
      printf '\n%s⚑ Events %s%s\n' "$C_HDR" "$(hr 68)" "$R"
      while IFS= read -r line; do
        printf '  %s%s%s\n' "$C_DIM" "$line" "$R"
      done <<< "$last3"
    fi
  fi

  printf '\n%s  %s · %s  press q to quit · events: sl events%s\n' "$C_DIM" "$DISH" "$(date '+%H:%M:%S')" "$R"
}

_dash_unreachable() {
  [[ "${SL_WATCH:-}" == "1" ]] || printf '\e[H\e[J'
  printf '\n'
  printf "  %sStarlink%s  %s● UNREACHABLE%s  %s%s%s\n" \
    "$C_HDR" "$R" "$C_ERR" "$R" "$C_DIM" "$DISH" "$R"
  printf "  %sapi did not answer in 4s — could be local Wi-Fi, ethernet, or the dish rebooting%s\n\n" "$C_DIM" "$R"

  if [[ -s "$SL_STATE" ]]; then
    local ts boots ups state dis ping
    ts=$(jq -r .ts "$SL_STATE"); boots=$(jq -r .boots "$SL_STATE")
    ups=$(jq -r .uptimeS "$SL_STATE"); state=$(jq -r .state "$SL_STATE")
    dis=$(jq -r .disable "$SL_STATE"); ping=$(jq -r .ping "$SL_STATE")
    local age=$(( $(date +%s) - ts ))
    printf '  %sLast seen%s   %s%ss ago%s  %sstate=%s  disable=%s  ping=%.1fms  boots=%s  up=%ss%s\n' \
      "$C_LBL" "$R" "$C_VAL" "$age" "$R" "$C_DIM" "$state" "$dis" "$ping" "$boots" "$ups" "$R"
  else
    printf '  %sno prior snapshot in %s%s\n' "$C_DIM" "$SL_STATE" "$R"
  fi

  if [[ -s "$SL_EVENTS" ]]; then
    printf '\n  %sRecent events (last 10):%s\n' "$C_HDR" "$R"
    tail -n 10 "$SL_EVENTS" | while IFS= read -r l; do
      printf '  %s%s%s\n' "$C_DIM" "$l" "$R"
    done
  fi
  printf '\n%s  %s · %s  press q to quit%s\n' "$C_DIM" "$DISH" "$(date '+%H:%M:%S')" "$R"
}

speedtest_run() {
  printf '%sStarlink speed test (Mac-side — dish-side API requires auth we can'"'"'t do from shell)%s\n\n' "$C_HDR" "$R"

  # LAN: RTT from Mac to dish (local link quality)
  printf '%s[1/2] LAN RTT to dish (192.168.100.1)%s\n' "$C_HDR" "$R"
  local lan_out lan_avg lan_loss
  lan_out=$(ping -c 10 -q -i 0.2 -W 1000 192.168.100.1 2>&1 || true)
  lan_avg=$(echo "$lan_out" | awk -F'/' '/min\/avg/ {print $5; exit}')
  lan_loss=$(echo "$lan_out" | awk '/packet loss/ {for(i=1;i<=NF;i++)if($i ~ /%$/){print $i; exit}}')
  printf '      %savg %s ms · loss %s%s\n\n' "$C_VAL" "${lan_avg:-?}" "${lan_loss:-?}" "$R"

  # Internet: macOS networkQuality measures down/up throughput + responsiveness
  printf '%s[2/2] Internet speed (via dish → PoP → Apple test servers)%s\n' "$C_HDR" "$R"
  if command -v networkQuality >/dev/null 2>&1; then
    networkQuality -v 2>&1 | awk '
      /^Uplink/   {printf "      \033[38;5;108mUp   \033[38;5;253m%s\033[0m\n", substr($0, index($0,$2))}
      /^Downlink/ {printf "      \033[38;5;108mDown \033[38;5;253m%s\033[0m\n", substr($0, index($0,$2))}
      /responsiveness/ {printf "      \033[38;5;244m%s\033[0m\n", $0}
    '
  else
    printf '      %snetworkQuality not available (macOS 12+ required)%s\n' "$C_DIM" "$R"
  fi
  printf '\n%sNote: dish↔PoP speedtest needs auth and isn'"'"'t reachable from unauthenticated CLI.%s\n' "$C_DIM" "$R"
}

watch_dash() {
  local every="${1:-2}"
  # Globals so the EXIT trap can see them after the function returns
  SL_OLD_STTY=$(stty -g 2>/dev/null || echo "")
  SL_WATCH_PID=""
  SL_WATCH_TMP=""
  _sl_stop_watch_job() {
    [[ -z "${SL_WATCH_PID:-}" ]] && return 0
    local child_pids=""
    child_pids=$(pgrep -P "$SL_WATCH_PID" 2>/dev/null || true)
    [[ -n "$child_pids" ]] && kill $child_pids 2>/dev/null || true
    kill "$SL_WATCH_PID" 2>/dev/null || true
    wait "$SL_WATCH_PID" 2>/dev/null || true
    SL_WATCH_PID=""
  }
  _sl_restore() {
    _sl_stop_watch_job
    [[ -n "${SL_WATCH_TMP:-}" ]] && rm -f "$SL_WATCH_TMP" 2>/dev/null || true
    [[ -n "${SL_OLD_STTY:-}" ]] && stty "$SL_OLD_STTY" 2>/dev/null
    printf '\e[?25h\e[?1049l'
  }
  trap '_sl_restore; exit 0' INT TERM EXIT
  # Alt screen + hide cursor + raw input (no echo, non-blocking read)
  printf '\e[?1049h\e[?25l'
  stty -icanon -echo min 0 time 0 2>/dev/null || true
  export SL_WATCH=1
  local phases=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local pi=0
  local spinner_fps=5
  while :; do
    SL_WATCH_TMP=$(mktemp "$SL_CACHE/watch.XXXXXX")
    ( dash > "$SL_WATCH_TMP" ) &
    SL_WATCH_PID=$!

    # Keep the wait indicator alive while dash gathers fresh data from the dish.
    local key=""
    while kill -0 "$SL_WATCH_PID" 2>/dev/null; do
      local glyph="${phases[pi]}"
      pi=$(( (pi + 1) % ${#phases[@]} ))
      printf '\r\e[K  %s%s  refreshing from dishy...  q=quit%s' \
        "$C_WARN" "$glyph" "$R"
      if IFS= read -rsn1 -t 0.2 key 2>/dev/null; then
        case "$key" in
          q|Q)
            _sl_stop_watch_job
            break 2
            ;;
        esac
      fi
    done

    wait "$SL_WATCH_PID" || true
    SL_WATCH_PID=""

    local out; out=$(cat "$SL_WATCH_TMP")
    rm -f "$SL_WATCH_TMP"
    SL_WATCH_TMP=""
    printf '\e[H'
    printf '%s\n' "$out" | awk '{printf "%s\033[K\n", $0}'
    printf '\e[J'
    # Cursor now sits on the empty line right below the dash. Draw the spinner
    # there, then redraw it in place while counting down to the next refresh.
    local remaining=$every key=""
    while (( remaining > 0 )); do
      local tick
      for (( tick=0; tick<spinner_fps && remaining>0; tick++ )); do
        local glyph="${phases[pi]}"
        pi=$(( (pi + 1) % ${#phases[@]} ))
        printf '\r\e[K  %s%s  next refresh in %ss · r=now  q=quit%s' \
          "$C_DIM" "$glyph" "$remaining" "$R"
        if IFS= read -rsn1 -t 0.2 key 2>/dev/null; then
          case "$key" in
            q|Q) break 3 ;;
            r|R|' ') break 2 ;;
          esac
        fi
      done
      remaining=$((remaining-1))
    done
  done
}

cmd="${1:-status}"
case "$cmd" in
  dash|d)    dash ;;
  watch|w)   watch_dash "${2:-3}" ;;
  events|ev) tail -n "${2:-40}" "$SL_EVENTS" 2>/dev/null || echo "no events yet ($SL_EVENTS)" ;;
  speed|speedtest) speedtest_run ;;
  status)
    safe_call '{"get_status":{}}' | jq -r '
      .dishGetStatus as $s |
      ($s.deviceState.uptimeS | tonumber) as $up |
      ($s.obstructionStats // {}) as $o |
      ($s.alerts // {}) as $a |
      ($s.readyStates // {}) as $r |
      ($s.gpsStats // {}) as $g |
      ($s.alignmentStats // {}) as $al |
      [
        "State:        \($s.state // (if ($r | to_entries | map(.value) | all) then "CONNECTED" else "NOT READY" end))",
        "Uptime:       \(($up/3600*10|floor)/10) h  (\($up)s, boots=\($s.deviceInfo.bootcount // "?"))",
        "Hardware:     \($s.deviceInfo.hardwareVersion)   class=\($s.classOfService // "?")   mobility=\($s.mobilityClass // "?")   country=\($s.deviceInfo.countryCode // "?")",
        "Software:     \($s.deviceInfo.softwareVersion)   swupdate=\($s.softwareUpdateState // "?")",
        "Throughput:   down \((($s.downlinkThroughputBps // 0)/1e6*100|round)/100) Mbps   up \((($s.uplinkThroughputBps // 0)/1e6*100|round)/100) Mbps",
        "Ping (pop):   \((($s.popPingLatencyMs // 0)*10|round)/10) ms   drop=\((($s.popPingDropRate // 0)*1000|round)/10)%",
        "SNR:          aboveNoise=\($s.isSnrAboveNoiseFloor // false)   persistentlyLow=\($s.isSnrPersistentlyLow // false)",
        "Obstruction:  \((($o.fractionObstructed // 0)*10000|round)/100)%   validS=\($o.validS // 0)   timeObstructed=\((($o.timeObstructed // 0)*10000|round)/100)%   patches=\($o.patchesValid // 0)",
        "Aim:          az=\((($s.boresightAzimuthDeg // 0)*10|round)/10) deg   el=\((($s.boresightElevationDeg // 0)*10|round)/10) deg   tilt=\((($al.tiltAngleDeg // 0)*10|round)/10) deg   attitude=\($al.attitudeEstimationState // "?")",
        "GPS:          valid=\($g.gpsValid // false)   sats=\($g.gpsSats // 0)",
        "Ethernet:     \($s.ethSpeedMbps // 0) Mbps",
        "Ready:        \([$r | to_entries[] | "\(.key)=\(.value)"] | join(" "))",
        "Bandwidth:    dl=\($s.dlBandwidthRestrictedReason // "?")   ul=\($s.ulBandwidthRestrictedReason // "?")   disablement=\($s.disablementCode // "?")",
        "Alerts:       \((([$a | to_entries[] | select(.value==true) | .key]) | if length==0 then "none" else join(", ") end))"
      ] | .[]'
    ;;
  history)
    safe_call '{"get_history":{}}' | jq '.dishGetHistory | {
      samples: (.popPingLatencyMs | length),
      popPingLatencyMsMean: ([.popPingLatencyMs[]? | select(.>0)] | if length>0 then add/length else 0 end),
      popPingDropRateMean:  ([.popPingDropRate[]?] | if length>0 then add/length else 0 end),
      downlinkMbpsMean: ([.downlinkThroughputBps[]?] | if length>0 then add/length/1e6 else 0 end),
      uplinkMbpsMean:   ([.uplinkThroughputBps[]?]   | if length>0 then add/length/1e6 else 0 end)
    }'
    ;;
  location) safe_call '{"get_location":{}}' ;;
  map)      safe_call '{"dish_get_obstruction_map":{}}' | jq '.dishGetObstructionMap | {numRows, numCols, snrCells: (.snr|length)}' ;;
  reboot)   safe_call '{"reboot":{}}' ;;
  raw)      safe_call "${2:-{\"get_status\":{}\}}" | jq . ;;
  pb)
    pct="${2:-}"
    wh="${3:-}"
    _pb_help() {
      cat <<'EOF' >&2
usage:
  sl pb                      show current anchor
  sl pb <pct> [wh]           anchor bank % now (and optional full-charge Wh)
  sl pb -                    clear the anchor (alias: reset, clear, off)
EOF
    }
    if [[ -z "$pct" ]]; then
      if [[ -s "$SL_PB_ANCHOR" ]]; then
        jq -r --argjson now "$(date +%s)" '
          def fmt(s): (s|tonumber) as $s
            | if $s>=3600 then "\($s/3600|floor)h\(($s%3600)/60|floor)m"
              elif $s>=60 then "\($s/60|floor)m\($s%60|floor)s"
              else "\($s)s" end;
          "anchor: \(.pct)% · bank=\(.wh // "—") Wh · set \(fmt($now - .ts)) ago (at dish uptime \(.uptime)s, boots=\(.boots), energyWh=\(.energyWh))"
        ' "$SL_PB_ANCHOR"
      else
        echo "no anchor set."
        _pb_help
      fi
      exit 0
    fi
    case "$pct" in
      -|reset|clear|off)
        if [[ -s "$SL_PB_ANCHOR" ]]; then
          rm -f "$SL_PB_ANCHOR"
          echo "anchor cleared."
        else
          echo "no anchor to clear."
        fi
        exit 0
        ;;
      -h|--help|help)
        _pb_help; exit 0 ;;
    esac
    if ! [[ "$pct" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      _pb_help; exit 2
    fi
    if [[ -n "$wh" ]] && ! [[ "$wh" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      _pb_help; exit 2
    fi
    # Refresh state (computes ENERGY_WH) by running a dash pass silently.
    dash >/dev/null 2>&1 || true
    if [[ ! -s "$SL_STATE" ]]; then
      echo "no state yet — is the dish reachable?" >&2; exit 1
    fi
    # Preserve prior wh if not given this time.
    prev_wh=""
    [[ -s "$SL_PB_ANCHOR" ]] && prev_wh=$(jq -r '.wh // empty' "$SL_PB_ANCHOR" 2>/dev/null || true)
    [[ -z "$wh" ]] && wh="$prev_wh"
    if [[ -n "$wh" ]]; then
      jq -c --argjson pct "$pct" --argjson wh "$wh" --argjson ts "$(date +%s)" \
        '{pct:$pct, wh:$wh, energyWh:(.energyWh // 0), uptime:(.uptimeS // 0), boots:(.boots // 0), ts:$ts}' \
        "$SL_STATE" > "$SL_PB_ANCHOR"
    else
      jq -c --argjson pct "$pct" --argjson ts "$(date +%s)" \
        '{pct:$pct, energyWh:(.energyWh // 0), uptime:(.uptimeS // 0), boots:(.boots // 0), ts:$ts}' \
        "$SL_STATE" > "$SL_PB_ANCHOR"
    fi
    jq -r '"anchored: \(.pct)% · bank=\(.wh // "—") Wh (uptime \(.uptime)s, energyWh=\(.energyWh), boots=\(.boots))"' "$SL_PB_ANCHOR"
    ;;
  *) echo "usage: sl [status|dash|d|watch|w [sec]|events|ev [N]|speed|history|location|map|reboot|pb [pct [wh] | -]|raw '<json>']" >&2; exit 1 ;;
esac
