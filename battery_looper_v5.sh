#!/bin/bash
# Compatible with macOS's bundled Bash 3.2. Sourcing defines functions only.

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

usage() {
  cat <<'HELP'
Battery Cycle 0.3.0 — controlled, finite battery cycling
Usage: ./battery_looper_v5.sh [--dry-run | --run] [--help]

No arguments: print the plan without reading or changing hardware.
--run: perform the configured cycles on an Apple Silicon MacBook.

Environment variables:
  LOW=20 HIGH=80       Charge thresholds (10 <= LOW < HIGH <= 100)
  MAX_CYCLES=1        Number of complete cycles (1..1000)
  POLL_SECONDS=15     Sampling interval (1..300)
  PHASE_TIMEOUT=21600 Maximum seconds per phase (60..86400)
  STALL_TIMEOUT=1800  Stop if charge does not progress (60..86400)
  LOG=./battery_cycle_log.csv
  USE_STRESS_NG=0     Optional CPU load during discharge only (0 or 1)
  BRIGHT_TARGET=      Optional display 0 brightness (0..1); empty preserves it

Ctrl+C stops the run and attempts to enable adapter/charging and restore
brightness. Existing Battery maintenance is stopped, not restored. Read README.
HELP
}

# Reject octal, expressions, and oversized integers before shell arithmetic.
integer_in_range() {
  local value="$1" minimum="$2" maximum="$3"
  [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] && [ "${#value}" -le 8 ] &&
    [ "$value" -ge "$minimum" ] && [ "$value" -le "$maximum" ]
}
valid_brightness() { [[ "$1" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; }

configure() {
  LOW="${LOW-20}" HIGH="${HIGH-80}" MAX_CYCLES="${MAX_CYCLES-1}"
  POLL_SECONDS="${POLL_SECONDS-15}" PHASE_TIMEOUT="${PHASE_TIMEOUT-21600}"
  STALL_TIMEOUT="${STALL_TIMEOUT-1800}" LOG="${LOG-./battery_cycle_log.csv}"
  USE_STRESS_NG="${USE_STRESS_NG-0}" BRIGHT_TARGET="${BRIGHT_TARGET-}"
  integer_in_range "$LOW" 10 99 || fail 'LOW must be an integer from 10 to 99.'
  integer_in_range "$HIGH" 11 100 || fail 'HIGH must be an integer from 11 to 100.'
  [ "$LOW" -lt "$HIGH" ] || fail 'LOW must be less than HIGH.'
  integer_in_range "$MAX_CYCLES" 1 1000 || fail 'MAX_CYCLES must be 1..1000.'
  integer_in_range "$POLL_SECONDS" 1 300 || fail 'POLL_SECONDS must be 1..300.'
  integer_in_range "$PHASE_TIMEOUT" 60 86400 || fail 'PHASE_TIMEOUT must be 60..86400.'
  integer_in_range "$STALL_TIMEOUT" 60 86400 || fail 'STALL_TIMEOUT must be 60..86400.'
  [ "$POLL_SECONDS" -lt "$PHASE_TIMEOUT" ] && [ "$POLL_SECONDS" -lt "$STALL_TIMEOUT" ] ||
    fail 'POLL_SECONDS must be shorter than both timeouts.'
  [[ "$USE_STRESS_NG" = 0 || "$USE_STRESS_NG" = 1 ]] || fail 'USE_STRESS_NG must be 0 or 1.'
  [[ -z "$BRIGHT_TARGET" ]] || valid_brightness "$BRIGHT_TARGET" || fail 'BRIGHT_TARGET must be 0..1.'
  [[ -n "$LOG" && "$LOG" != *$'\n'* && "$LOG" != *$'\r'* ]] || fail 'LOG must be a nonempty single-line path.'
}

initialize() {
  BATTERY_TOUCHED=0 BRIGHTNESS_TOUCHED=0 LOCK_HELD=0
  ACTIVE_PID='' LOAD_PID='' CAF_PID='' SLEEP_PID='' ORIGINAL_BRIGHTNESS=''
  LOCK_DIR="/tmp/battery-cycle-${UID}.lock"
  CSV_HEADER='timestamp,battery_percent,state,cycle_count,health_percent,note'
  COMMAND_TIMEOUT=30
  STATE_GRACE_SECONDS=60
}

# Stop only a child launched by this run and its current descendants. Pausing
# the parent prevents it from creating more children while they are collected.
stop_owned() {
  local pid="$1" start=$SECONDS child children status=0
  [[ -n "$pid" ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill -STOP "$pid" 2>/dev/null || true
    if ! children=$(ps -axo pid=,ppid= | awk -v parent="$pid" '$2 == parent {print $1}'); then
      warn "Could not inspect children of process $pid; process cleanup may be incomplete."
      status=1
    fi
    for child in $children; do stop_owned "$child" || status=1; done
    kill -TERM "$pid" 2>/dev/null || true
    kill -CONT "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
      if [ $((SECONDS - start)) -ge 3 ]; then
        kill -KILL "$pid" 2>/dev/null || true
        break
      fi
      sleep 0.1
    done
  fi
  wait "$pid" 2>/dev/null || true
  return "$status"
}

# Background + wait lets Bash handle signals during an external command.
# Timeout bounds an unresponsive dependency, including authentication prompts.
run_bounded() {
  local start=$SECONDS status=0
  "$@" </dev/null &
  ACTIVE_PID=$!
  while kill -0 "$ACTIVE_PID" 2>/dev/null; do
    if [ $((SECONDS - start)) -ge "$COMMAND_TIMEOUT" ]; then
      warn "Command timed out: $1"
      stop_owned "$ACTIVE_PID" || true
      ACTIVE_PID=''
      return 124
    fi
    sleep 0.1
  done
  wait "$ACTIVE_PID" || status=$?
  ACTIVE_PID=''
  return "$status"
}

# Do not put run_bounded in command substitution: the parent must retain its
# active PID so the EXIT trap can terminate it before recovering hardware.
capture_command() {
  run_bounded "$@" > "$LOCK_DIR/command.out" || return $?
  COMMAND_OUTPUT=$(cat "$LOCK_DIR/command.out")
}
battery_command() { run_bounded "$BATTERY_BIN" "$@"; }
brightness_command() { run_bounded "$BRIGHTNESS_BIN" "$@"; }

cleanup() {
  local status="$1" recovery_failed=0
  set +e
  trap - EXIT
  trap '' INT TERM HUP
  stop_owned "$ACTIVE_PID" || recovery_failed=1
  ACTIVE_PID=''
  stop_owned "$SLEEP_PID" || recovery_failed=1
  stop_owned "$LOAD_PID" || recovery_failed=1
  stop_owned "$CAF_PID" || recovery_failed=1
  if [ "$BATTERY_TOUCHED" = 1 ]; then
    printf '\nRestoring adapter power and charging...\n'
    battery_command adapter on || recovery_failed=1
    battery_command charging on || recovery_failed=1
  fi
  if [ "$BRIGHTNESS_TOUCHED" = 1 ]; then
    brightness_command -d 0 "$ORIGINAL_BRIGHTNESS" || recovery_failed=1
  fi
  if [ "$LOCK_HELD" = 1 ]; then
    rm -f "$LOCK_DIR/pid" "$LOCK_DIR/command.out" || recovery_failed=1
    rmdir "$LOCK_DIR" || recovery_failed=1
  fi
  if [ "$recovery_failed" = 1 ]; then
    warn 'Recovery was incomplete. Check battery status; run battery adapter on and battery charging on manually.'
    [ "$status" -ne 0 ] || status=1
  fi
  exit "$status"
}

require_command() { command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"; }

preflight() {
  [ "$(uname -s)" = Darwin ] || fail '--run requires macOS.'
  [ "$(uname -m)" = arm64 ] || fail 'Battery CLI requires native Apple Silicon; use an arm64 terminal.'
  [ "$EUID" -ne 0 ] || fail 'Run as your normal user, without sudo.'
  local name
  for name in battery pmset ioreg caffeinate ps awk date; do require_command "$name"; done
  BATTERY_BIN=$(command -v battery)
  if [ "$USE_STRESS_NG" = 1 ]; then require_command stress-ng; fi
  if [[ -n "$BRIGHT_TARGET" ]]; then
    require_command brightness
    BRIGHTNESS_BIN=$(command -v brightness)
  fi
  # The atomic lock is per user and independent of the selected log path.
  mkdir -m 700 "$LOCK_DIR" 2>/dev/null ||
    fail "Run lock exists: $LOCK_DIR. Check its PID before manually removing a stale lock."
  LOCK_HELD=1
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  if [[ -L "$LOG" || ( -e "$LOG" && ! -f "$LOG" ) ]]; then fail 'LOG must be a regular file, not a symlink.'; fi
  if [ -s "$LOG" ]; then
    local header
    IFS= read -r header < "$LOG" || fail 'Cannot read log header.'
    [ "$header" = "$CSV_HEADER" ] || fail 'Existing LOG has an incompatible CSV header.'
  else
    printf '%s\n' "$CSV_HEADER" > "$LOG" || fail 'Cannot create LOG; check its parent directory.'
  fi
  [ -w "$LOG" ] || fail 'LOG is not writable.'
  read_sample
  [[ "$POWER_SOURCE" = 'AC Power' ]] || fail 'Connect the power adapter before starting.'
  if [[ -n "$BRIGHT_TARGET" ]]; then
    capture_command "$BRIGHTNESS_BIN" -l || fail 'Cannot read display brightness.'
    ORIGINAL_BRIGHTNESS=$(printf '%s\n' "$COMMAND_OUTPUT" | awk '/^display 0: brightness / {print $NF}')
    valid_brightness "$ORIGINAL_BRIGHTNESS" || fail 'Cannot reliably save display 0 brightness.'
  fi
}

parse_pmset() {
  # Require exactly one internal battery; ignore UPS/peripheral battery lines.
  awk '
    /^Now drawing from / { source=$0; sub(/^Now drawing from /,"",source); gsub(/\047/,"",source) }
    /InternalBattery/ {
      count++
      if (!match($0, /[0-9]+%;/)) { invalid=1; next }
      pct=substr($0,RSTART,RLENGTH-2)
      if (pct !~ /^(0|[1-9][0-9]*)$/ || pct+0 > 100) { invalid=1; next }
      state=substr($0,RSTART+RLENGTH); sub(/;.*/,"",state); gsub(/^[ \t]+|[ \t]+$/, "", state)
      if (state != "charging" && state != "discharging" && state != "charged" && state != "AC attached" && state != "not charging" && state != "finishing charge") invalid=1
    }
    END {
      if (invalid || count != 1 || pct == "" || state == "" || (source != "AC Power" && source != "Battery Power")) exit 1
      printf "%s|%s|%s\n",pct,state,source
    }'
}

parse_ioreg() {
  # Exact scalar keys avoid matching nested dictionaries or similar key names.
  awk '
    $1 == "\"CycleCount\"" && $2 == "=" && $3 ~ /^[0-9]+$/ {cycles=$3}
    $1 == "\"AppleRawMaxCapacity\"" && $2 == "=" && $3 ~ /^[0-9]+$/ {raw=$3}
    $1 == "\"DesignCapacity\"" && $2 == "=" && $3 ~ /^[0-9]+$/ {design=$3}
    END {
      health=""
      if (raw+0 > 0 && design+0 > 0) health=sprintf("%.1f",raw/design*100)
      printf "%s|%s\n",cycles,health
    }'
}

read_sample() {
  local parsed optional
  capture_command pmset -g batt || fail 'Cannot read battery percentage.'
  parsed=$(printf '%s\n' "$COMMAND_OUTPUT" | parse_pmset) || fail 'Missing, ambiguous, or invalid internal battery reading.'
  IFS='|' read -r PCT STATE POWER_SOURCE <<< "$parsed"
  # Optional telemetry is left blank when unavailable; health is a raw capacity
  # ratio, not the Battery Health figure displayed by macOS.
  CYCLES='' HEALTH=''
  if capture_command ioreg -rn AppleSmartBattery 2>/dev/null; then
    optional=$(printf '%s\n' "$COMMAND_OUTPUT" | parse_ioreg)
    IFS='|' read -r CYCLES HEALTH <<< "$optional"
  fi
}

log_sample() {
  printf '%s,%s,%s,%s,%s,%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$PCT" "$STATE" "$CYCLES" "$HEALTH" "$1" >> "$LOG" ||
    fail 'Writing LOG failed; ending the cycle.'
  printf '%-11s %3s%%  %-16s %s\n' "$1" "$PCT" "$STATE" "$(date '+%H:%M:%S')"
}

start_load() {
  if [ "$USE_STRESS_NG" = 1 ]; then
    # A bounded CPU worker replaces all-core CPU + 60% RAM stress.
    stress-ng --cpu 1 --cpu-load 50 --timeout "$PHASE_TIMEOUT" >/dev/null 2>&1 &
    LOAD_PID=$!
  fi
}

pause_poll() {
  sleep "${1:-$POLL_SECONDS}" &
  SLEEP_PID=$!
  wait "$SLEEP_PID"
  SLEEP_PID=''
}

phase_matches() {
  if [ "$1" = discharging ]; then
    [ "$STATE" = discharging ]
  else
    [[ "$POWER_SOURCE" = 'AC Power' ]] &&
      [[ "$STATE" = charging || "$STATE" = charged || "$STATE" = 'finishing charge' ]]
  fi
}

run_phase() {
  local phase="$1" started=$SECONDS progressed=$SECONDS best next_poll remaining
  read_sample
  best=$PCT
  if [[ "$phase" = discharging && "$PCT" -le "$LOW" ]]; then log_sample reached_low; return; fi
  if [[ "$phase" = charging && "$PCT" -ge "$HIGH" ]]; then log_sample reached_high; return; fi
  BATTERY_TOUCHED=1
  if [ "$phase" = discharging ]; then
    battery_command charging off || fail 'Could not disable charging.'
    battery_command adapter off || fail 'Could not disable the adapter.'
    start_load
  else
    battery_command adapter on || fail 'Could not enable the adapter.'
    battery_command charging on || fail 'Could not enable charging.'
  fi
  while :; do
    read_sample
    # Check the observed state before declaring any requested phase or target
    # successful. Transition samples remain identifiable in the CSV.
    if phase_matches "$phase"; then
      log_sample "$phase"
    else
      log_sample "transition_$phase"
      if [ $((SECONDS - started)) -ge "$STATE_GRACE_SECONDS" ] ||
         [[ "$phase" = discharging && "$PCT" -le "$LOW" ]] ||
         [[ "$phase" = charging && "$PCT" -ge "$HIGH" ]]; then
        fail "Observed battery state does not match $phase ($STATE, $POWER_SOURCE)."
      fi
    fi
    if [ "$phase" = discharging ]; then
      if [ "$PCT" -le "$LOW" ]; then break; fi
      if [ "$PCT" -lt "$best" ]; then best=$PCT; progressed=$SECONDS; fi
    else
      if [ "$PCT" -le $((LOW - 2)) ]; then fail 'Battery fell below the lower threshold while charging.'; fi
      if [ "$PCT" -ge "$HIGH" ]; then break; fi
      if [ "$PCT" -gt "$best" ]; then best=$PCT; progressed=$SECONDS; fi
    fi
    [ $((SECONDS - started)) -lt "$PHASE_TIMEOUT" ] || fail "$phase exceeded PHASE_TIMEOUT."
    [ $((SECONDS - progressed)) -lt "$STALL_TIMEOUT" ] || fail "$phase made no progress within STALL_TIMEOUT."
    if [[ -n "$LOAD_PID" ]]; then kill -0 "$LOAD_PID" 2>/dev/null || fail 'CPU load process exited unexpectedly.'; fi
    if [[ -n "$CAF_PID" ]]; then kill -0 "$CAF_PID" 2>/dev/null || fail 'caffeinate exited unexpectedly.'; fi
    if [[ -n "$BRIGHT_TARGET" ]]; then
      BRIGHTNESS_TOUCHED=1
      brightness_command -d 0 "$BRIGHT_TARGET" || fail 'Could not set display brightness.'
    fi
    next_poll=$POLL_SECONDS
    remaining=$((PHASE_TIMEOUT - (SECONDS - started)))
    [ "$next_poll" -le "$remaining" ] || next_poll=$remaining
    remaining=$((STALL_TIMEOUT - (SECONDS - progressed)))
    [ "$next_poll" -le "$remaining" ] || next_poll=$remaining
    # A large normal sample interval must not stretch the state-change grace.
    if ! phase_matches "$phase" && [ "$next_poll" -gt 5 ]; then next_poll=5; fi
    if [ "$next_poll" -gt 0 ]; then pause_poll "$next_poll"; fi
  done
  stop_owned "$LOAD_PID"
  LOAD_PID=''
  if [ "$phase" = discharging ]; then log_sample reached_low; else log_sample reached_high; fi
}

main() {
  set -e -o pipefail
  export LC_ALL=C
  local mode=dry-run round
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage; return 0 ;;
      --dry-run) mode=dry-run ;;
      --run) mode=run ;;
      *) fail "Unknown argument: $1 (use --help)." ;;
    esac
    shift
  done
  configure
  printf 'Battery Cycle 0.3.0 | %s | %s%% -> %s%% | %s cycle(s)\n' "$mode" "$LOW" "$HIGH" "$MAX_CYCLES"
  printf 'Log: %s | CPU load: %s | Brightness: %s\n' "$LOG" "$USE_STRESS_NG" "${BRIGHT_TARGET:-unchanged}"
  if [ "$mode" = dry-run ]; then
    printf 'Plan: stop Battery maintenance; discharge to LOW; charge to HIGH; repeat.\n'
    printf 'On exit: enable adapter/charging; restore changed brightness. No hardware or files touched.\n'
    return 0
  fi
  umask 077
  initialize
  trap 'cleanup "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  preflight
  BATTERY_TOUCHED=1
  battery_command maintain stop || fail 'Could not stop existing Battery maintenance.'
  caffeinate -di -w "$$" &
  CAF_PID=$!
  for ((round=1; round<=MAX_CYCLES; round++)); do
    printf '\nCycle %s/%s\n' "$round" "$MAX_CYCLES"
    run_phase discharging
    run_phase charging
  done
  printf '\nCompleted %s cycle(s). Log: %s\n' "$MAX_CYCLES" "$LOG"
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then main "$@"; fi
