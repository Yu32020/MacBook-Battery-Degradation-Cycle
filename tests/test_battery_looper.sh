#!/bin/bash
# All battery, brightness, telemetry, and workload actions below are mocks.
set -e -o pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/battery_looper_v5.sh"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/battery-cycle-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
export SCRIPT TEST_DIR
passed=0

check() {
  local name="$1"
  shift
  if "$@" > "$TEST_DIR/result" 2>&1; then
    printf 'ok - %s\n' "$name"
    passed=$((passed + 1))
  else
    printf 'not ok - %s\n' "$name"
    cat "$TEST_DIR/result"
    exit 1
  fi
}

check 'Bash syntax' /bin/bash -n "$SCRIPT"
check 'Help works without dependencies' /bin/bash "$SCRIPT" --help
check 'Dry-run creates no log and invokes no tools' /bin/bash -c '
  mkdir "$TEST_DIR/tripwire"
  for name in battery brightness pmset ioreg caffeinate stress-ng; do
    printf "#!/bin/bash\necho called >> \"%s/unexpected\"\nexit 99\n" "$TEST_DIR" > "$TEST_DIR/tripwire/$name"
    chmod +x "$TEST_DIR/tripwire/$name"
  done
  PATH="$TEST_DIR/tripwire:/usr/bin:/bin" LOG="$TEST_DIR/dry.csv" /bin/bash "$SCRIPT"
  test ! -e "$TEST_DIR/dry.csv" && test ! -e "$TEST_DIR/unexpected"
'
check 'Invalid configuration rejected before writes' /bin/bash -c '
  for entry in LOW=abc LOW=08 LOW=9 LOW=100 HIGH=101 HIGH=20 MAX_CYCLES=0 POLL_SECONDS=0 STALL_TIMEOUT=oops BRIGHT_TARGET=1.01 USE_STRESS_NG=2 LOG=; do
    if env "$entry" /bin/bash "$SCRIPT" --dry-run; then exit 1; fi
  done
  if LOW="1+19" /bin/bash "$SCRIPT"; then exit 1; fi
  if /bin/bash "$SCRIPT" --unknown; then exit 1; fi
'
check 'Percentage parser accepts internal battery and ignores peripherals' /bin/bash -c '
  source "$SCRIPT"
  actual=$(printf "Now drawing from '\''AC Power'\''\n -InternalBattery-0 (id=1) 80%%; charging; 1:00 remaining\n -UPS 30%%; discharging\n" | parse_pmset)
  test "$actual" = "80|charging|AC Power"
'
check 'Percentage parser rejects missing, duplicate, and invalid readings' /bin/bash -c '
  source "$SCRIPT"
  for sample in "" " -UPS 30%; discharging" " -InternalBattery-0 N/A%; unknown" " -InternalBattery-0 101%; charged" " -InternalBattery-0 20%; unknown"; do
    if printf "Now drawing from '\''AC Power'\''\n%s\n" "$sample" | parse_pmset; then exit 1; fi
  done
  if printf "Now drawing from '\''Battery Power'\''\n-InternalBattery-0 20%%; discharging\n-InternalBattery-1 20%%; discharging\n" | parse_pmset; then exit 1; fi
'
check 'Capacity parser uses exact keys; unknown telemetry stays blank' /bin/bash -c '
  source "$SCRIPT"
  actual=$(printf "  \"CycleCount\" = 12\n  \"AppleRawMaxCapacity\" = 4500\n  \"DesignCapacity\" = 5000\n  \"AppleRawDesignCapacity\" = 6000\n  \"BatteryData\" = {\"DesignCapacity\"=9999}\n" | parse_ioreg)
  test "$actual" = "12|90.0"
  test "$(printf "\"DesignCapacity\" = 0\n" | parse_ioreg)" = "|"
'

cat > "$TEST_DIR/harness.sh" <<'HARNESS'
source "$SCRIPT"
configure
initialize
LOG="$TEST_DIR/scenario.csv"
: > "$LOG"
EVENTS="$TEST_DIR/events"
: > "$EVENTS"
PCT=50 STATE=discharging POWER_SOURCE='AC Power' CYCLES=12 HEALTH=90.0
samples=0
battery_command() { printf 'battery %s\n' "$*" >> "$EVENTS"; }
brightness_command() { printf 'brightness %s\n' "$*" >> "$EVENTS"; }
start_load() { printf 'load start\n' >> "$EVENTS"; }
stop_owned() { printf 'stop %s\n' "$1" >> "$EVENTS"; }
pause_poll() { SECONDS=$((SECONDS + 15)); }
HARNESS
export HARNESS="$TEST_DIR/harness.sh"

check 'Complete simulated cycle has correct commands and thresholds' /bin/bash -c '
  set -e
  source "$HARNESS"
  read_sample() {
    samples=$((samples + 1))
    case "$samples" in
      1|2) PCT=50; STATE=discharging ;;
      3|4) PCT=20; STATE=discharging ;;
      5) PCT=40; STATE=charging ;;
      6) PCT=80; STATE=charged ;;
      *) exit 98 ;;
    esac
  }
  run_phase discharging
  run_phase charging
  test "$samples" = 6
  grep -q "battery charging off" "$EVENTS"
  grep -q "battery adapter off" "$EVENTS"
  grep -q "battery adapter on" "$EVENTS"
  grep -q "battery charging on" "$EVENTS"
  grep -q ",20,discharging,12,90.0,reached_low" "$LOG"
  grep -q ",80,charged,12,90.0,reached_high" "$LOG"
'
check 'Reached threshold skips unnecessary discharge and load' /bin/bash -c '
  source "$HARNESS"
  read_sample() { PCT=20; }
  run_phase discharging
  ! grep -q "battery\|load start" "$EVENTS"
'
check 'Stalled percentage terminates with nonzero status' /bin/bash -c '
  if /bin/bash -c '\''source "$HARNESS"; STALL_TIMEOUT=30; read_sample() { PCT=50; }; run_phase discharging'\''; then exit 1; fi
'
check 'Phase deadline terminates even with percentage progress' /bin/bash -c '
  if /bin/bash -c '\''source "$HARNESS"; PHASE_TIMEOUT=30; read_sample() { PCT=$((PCT-1)); }; run_phase discharging'\''; then exit 1; fi
'
check 'Charge losing capacity below its floor terminates' /bin/bash -c '
  if /bin/bash -c '\''source "$HARNESS"; read_sample() { samples=$((samples+1)); if [ "$samples" = 1 ]; then PCT=20; else PCT=18; fi; }; run_phase charging'\''; then exit 1; fi
'
check 'Failed battery command triggers EXIT recovery and preserves failure' /bin/bash -c '
  if /bin/bash -c '\''
    source "$HARNESS"
    trap '\''\'\'''\''cleanup "$?"'\''\'\'''\'' EXIT
    read_sample() { PCT=50; }
    battery_command() { printf "battery %s\n" "$*" >> "$EVENTS"; [ "$*" != "adapter off" ]; }
    run_phase discharging
  '\''; then exit 1; fi
  grep -q "battery adapter on" "$TEST_DIR/events"
  grep -q "battery charging on" "$TEST_DIR/events"
'
check 'Cleanup restores saved brightness and reports recovery failure' /bin/bash -c '
  if /bin/bash -c '\''
    source "$HARNESS"
    BATTERY_TOUCHED=1 BRIGHTNESS_TOUCHED=1 ORIGINAL_BRIGHTNESS=0.4
    battery_command() { printf "battery %s\n" "$*" >> "$EVENTS"; return 1; }
    cleanup 0
  '\''; then exit 1; fi
  grep -q "brightness -d 0 0.4" "$TEST_DIR/events"
  grep -q "battery charging on" "$TEST_DIR/events"
'
check 'Bounded command returns original failure and timeout' /bin/bash -c '
  source "$SCRIPT"
  initialize
  if run_bounded /bin/bash -c "exit 7"; then exit 1; else test "$?" = 7 || exit 1; fi
  COMMAND_TIMEOUT=1
  if run_bounded /bin/sleep 10; then exit 1; else test "$?" = 124 || exit 1; fi
  test -z "$ACTIVE_PID"
'
check 'Only owned process stops; unrelated process survives' /bin/bash -c '
  source "$SCRIPT"
  initialize
  /bin/sleep 20 & unrelated=$!
  /bin/sleep 20 & owned=$!
  trap '\''kill "$unrelated" "$owned" 2>/dev/null || true'\'' EXIT
  stop_owned "$owned"
  kill -0 "$unrelated"
  ! kill -0 "$owned" 2>/dev/null
'
check 'Missing sensor invokes failure and cleanup without fabricated data' /bin/bash -c '
  if /bin/bash -c '\''
    source "$HARNESS"
    trap '\''\'\'''\''cleanup "$?"'\''\'\'''\'' EXIT
    BATTERY_TOUCHED=1
    capture_command() { COMMAND_OUTPUT="Now drawing from '\''\'\'''\''AC Power'\''\'\'''\''"; }
    read_sample
  '\''; then exit 1; fi
  grep -q "battery charging on" "$TEST_DIR/events"
'

check 'Successful command with the wrong observed discharge state fails' /bin/bash -c '
  if /bin/bash -c '\''source "$HARNESS"; STATE_GRACE_SECONDS=15; read_sample() { PCT=50; STATE=charging; }; run_phase discharging'\''; then exit 1; fi
'
check 'Missing adapter during charge fails after transition grace' /bin/bash -c '
  if /bin/bash -c '\''source "$HARNESS"; STATE_GRACE_SECONDS=15; read_sample() { PCT=50; STATE=charging; POWER_SOURCE="Battery Power"; }; run_phase charging'\''; then exit 1; fi
'
check 'Wrong state at threshold cannot be logged as successful completion' /bin/bash -c '
  if /bin/bash -c '\''
    source "$HARNESS"
    read_sample() { samples=$((samples+1)); if [ "$samples" = 1 ]; then PCT=50; STATE=discharging; else PCT=20; STATE=charging; fi; }
    run_phase discharging
  '\''; then exit 1; fi
  grep -q "transition_discharging" "$TEST_DIR/scenario.csv" || exit 1
  ! grep -q "reached_low" "$TEST_DIR/scenario.csv"
'
check 'Log failure stops the run and attempts recovery' /bin/bash -c '
  if /bin/bash -c '\''
    source "$HARNESS"
    trap '\''\'\'''\''cleanup "$?"'\''\'\'''\'' EXIT
    LOG="$TEST_DIR"
    read_sample() { PCT=50; STATE=discharging; }
    run_phase discharging
  '\''; then exit 1; fi
  grep -q "battery adapter on" "$TEST_DIR/events" || exit 1
  grep -q "battery charging on" "$TEST_DIR/events"
'
check 'Long poll interval cannot extend an observed transition grace' /bin/bash -c '
  source "$HARNESS"
  POLL_SECONDS=300
  read_sample() {
    samples=$((samples+1))
    if [ "$samples" -le 2 ]; then PCT=50; STATE=charging; else PCT=20; STATE=discharging; fi
  }
  pause_poll() { printf "%s\n" "$1" > "$TEST_DIR/transition-wait"; SECONDS=$((SECONDS + $1)); }
  run_phase discharging
  interval=$(cat "$TEST_DIR/transition-wait")
  test "$interval" -le 5
'

cat > "$TEST_DIR/signal-command.sh" <<'SIGNAL_COMMAND'
#!/bin/bash
printf '%s\n' "$$" > "$TEST_DIR/command.pid"
/bin/sleep 20 &
printf '%s\n' "$!" > "$TEST_DIR/grandchild.pid"
kill -"$TEST_SIGNAL" "$PPID"
wait
SIGNAL_COMMAND
cat > "$TEST_DIR/signal-target.sh" <<'SIGNAL_TARGET'
#!/bin/bash
set -e -o pipefail
source "$SCRIPT"
initialize
BATTERY_TOUCHED=1
battery_command() { printf 'recovery %s\n' "$*" >> "$TEST_DIR/signal-events"; }
trap 'cleanup "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
run_bounded /bin/bash "$TEST_DIR/signal-command.sh"
exit 99
SIGNAL_TARGET

check 'Real INT and TERM preserve status, clean descendants, recover, preserve unrelated process' /bin/bash -c '
  /bin/sleep 30 & unrelated=$!
  trap '\''kill "$unrelated" 2>/dev/null || true'\'' EXIT
  for signal in INT TERM; do
    : > "$TEST_DIR/signal-events"
    status=0
    TEST_SIGNAL="$signal" /bin/bash "$TEST_DIR/signal-target.sh" || status=$?
    if [ "$signal" = INT ]; then test "$status" = 130 || exit 1; else test "$status" = 143 || exit 1; fi
    grep -q "recovery adapter on" "$TEST_DIR/signal-events" || exit 1
    grep -q "recovery charging on" "$TEST_DIR/signal-events" || exit 1
    for file in command.pid grandchild.pid; do
      if kill -0 "$(cat "$TEST_DIR/$file")" 2>/dev/null; then exit 1; fi
    done
    kill -0 "$unrelated" || exit 1
  done
'

printf '\n%s checks passed. No hardware commands or workloads executed.\n' "$passed"
