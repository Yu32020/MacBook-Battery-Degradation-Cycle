#!/usr/bin/env bash
set -e -o pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

VER="Beta 0.1"
LOW="${LOW:-10}"
HIGH="${HIGH:-100}"
LOG="${LOG:-$HOME/battery_cycle_log.csv}"
BRIGHT_TARGET="${BRIGHT_TARGET:-1.0}"
USE_STRESS_NG="${USE_STRESS_NG:-1}"

need(){ command -v "$1" >/dev/null 2>&1; }
fail(){ echo "错误：$1" >&2; exit 1; }

need battery || fail "缺少 battery"
need brightness || fail "缺少 brightness"
need caffeinate || fail "缺少 caffeinate"
if [ "$USE_STRESS_NG" = "1" ]; then need stress-ng || fail "缺少 stress-ng"; fi

get_pct(){ pmset -g batt | grep -Eo '[0-9]+%' | tr -d % | head -n1; }
get_state(){ pmset -g batt | awk -F';' 'NR==2{gsub(/^ +| +$/,"",$2); print $2}'; }
get_cycles(){ system_profiler SPPowerDataType | awk -F': ' '/Cycle Count/{print $2; exit}'; }
get_health(){ ioreg -rn AppleSmartBattery 2>/dev/null | awk '/AppleRawMaxCapacity/{raw=$NF} /DesignCapacity/{des=$NF} END{if(raw&&des) printf "%.1f", raw/des*100}'; }

[ -f "$LOG" ] || echo "timestamp,battery_percent,state,cycle_count,health_percent,note" > "$LOG"
log(){ printf "%s,%s,%s,%s,%s,%s\n" "$(date '+%F %T')" "$(get_pct)" "$(get_state)" "$(get_cycles)" "$(get_health)" "$1" >> "$LOG"; }

LAST_OSD=0
force_brightness_max(){
  before="$(brightness -l 2>/dev/null | awk '/display 0: brightness/{print $NF; exit}')"
  brightness "$BRIGHT_TARGET" >/dev/null 2>&1 || true
  sleep 0.2
  after="$(brightness -l 2>/dev/null | awk '/display 0: brightness/{print $NF; exit}')"
  awk -v a="$after" 'BEGIN{exit (a>=0.95)?1:0}'
  if [ $? -ne 1 ]; then
    now="$(date +%s)"
    if [ $(( now - LAST_OSD )) -ge 60 ]; then
      for _ in {1..20}; do osascript -e 'tell application "System Events" to key code 144' >/dev/null 2>&1 || true; done
      LAST_OSD="$now"
    fi
  fi
  echo "BRIGHT ${before:-?}->${after:-?}"
}

ORIG_LPM="$(pmset -g | awk '/lowpowermode/{print $2; exit}')"
sudo pmset -a lowpowermode 0 >/dev/null 2>&1 || true
sudo pmset -b lessbright 0 >/dev/null 2>&1 || true

if need sudo; then sudo -v; (while true; do sleep 60; sudo -n true || exit; done ) & SUDO_KEEP=$!; fi
caffeinate -dimsu -w $$ & echo $! > /tmp/looper_caf.pid

start_load(){
  N="$(sysctl -n hw.logicalcpu)"
  if [ "$USE_STRESS_NG" = "1" ] && need stress-ng; then
    stress-ng --cpu 0 --cpu-method matrixprod --vm 1 --vm-bytes 60% --timeout 0 >/dev/null 2>&1 &
    echo $! > /tmp/looper_cpu.pid
  else
    for _ in $(seq 1 "$N"); do yes >/dev/null & done
    pgrep -f "^yes$" > /tmp/looper_cpu_yes.pids
  fi
}

cleanup(){
  echo
  echo "CLEANING"
  sudo battery maintain stop >/dev/null 2>&1 || true
  sudo battery charge "$HIGH" >/dev/null 2>&1 || true
  sudo battery charging on >/dev/null 2>&1 || true
  sudo battery adapter on >/dev/null 2>&1 || true
  [ -n "$ORIG_LPM" ] && sudo pmset -a lowpowermode "$ORIG_LPM" >/dev/null 2>&1 || true
  [ -f /tmp/looper_cpu.pid ] && kill "$(cat /tmp/looper_cpu.pid)" 2>/dev/null || true
  [ -f /tmp/looper_cpu_yes.pids ] && xargs kill 2>/dev/null < /tmp/looper_cpu_yes.pids || true
  [ -f /tmp/looper_caf.pid ] && kill "$(cat /tmp/looper_caf.pid)" 2>/dev/null || true
  [ -n "${SUDO_KEEP-}" ] && kill "$SUDO_KEEP" 2>/dev/null || true
  rm -f /tmp/looper_cpu.pid /tmp/looper_cpu_yes.pids /tmp/looper_caf.pid
  killall -q stress-ng yes caffeinate 2>/dev/null || true
  echo "STOPPED LOG:$LOG"
}
trap 'cleanup; exit 0' INT TERM HUP

echo "VERSION $VER"
echo "RUNNING"
force_brightness_max
( while :; do brightness "$BRIGHT_TARGET" >/dev/null 2>&1 || true; sleep 10; done ) &

start_load
round=0
echo "CYCLING LOW=$LOW HIGH=$HIGH"
while :; do
  round=$((round+1))
  echo "DISCHARGE->$LOW ROUND#$round"
  sudo battery maintain stop >/dev/null 2>&1 || true
  sudo battery adapter off >/dev/null 2>&1 || true
  sudo battery discharge "$LOW" >/dev/null 2>&1 || true
  while :; do log "discharging"; force_brightness_max >/dev/null 2>&1 || true; [ "$(get_pct)" -le "$LOW" ] && break; sleep 5; done
  log "reached_low"

  echo "CHARGE->$HIGH ROUND#$round"
  sudo battery adapter on >/dev/null 2>&1 || true
  sudo battery charge "$HIGH" >/dev/null 2>&1 || true
  while :; do log "charging"; force_brightness_max >/dev/null 2>&1 || true; [ "$(get_pct)" -ge "$HIGH" ] && break; sleep 5; done
  log "reached_high"
done
