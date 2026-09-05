# MacBook Battery Degradation Cycle

A command-line experiment for cycling an Apple Silicon MacBook battery and recording capacity samples. Version **0.3.0** retains the original `battery_looper_v5.sh` filename.

**Running with no arguments now previews the plan.** A real run requires `--run`, defaults to **one 20% → 80% cycle**, and leaves brightness and CPU load unchanged. This is an experimental degradation-testing utility, not a battery-health improvement tool. Repeated cycling consumes battery life.

## Preview and run

```bash
# No dependencies, hardware reads, log writes, or settings changes:
/bin/bash battery_looper_v5.sh --dry-run
/bin/bash battery_looper_v5.sh --help

# A real, supervised run; requires the dependencies below:
/bin/bash battery_looper_v5.sh --run

# Explicitly choose the original experiment thresholds, for two cycles:
LOW=10 HIGH=100 MAX_CYCLES=2 /bin/bash battery_looper_v5.sh --run
```

Run as your normal user, without `sudo`, with the charger connected and the lid open. Stop conflicting charge-limit apps/automation first. A real run stops Battery CLI's maintenance policy; that policy is **not restarted** on exit. If you normally use a charge limit, re-enable your chosen policy afterward, for example `battery maintain 80`.

Battery cycling can produce heat and accelerate wear. Supervise the machine, allow ventilation, and stop if it becomes unusually hot or unstable. This script has **no temperature sensor cutoff**. The hardware's protections are not replaced by this script. Do not use it on a swollen, damaged, or suspect battery.

## Dependencies

For a real run:

- macOS on an **Apple Silicon MacBook**, running a native arm64 shell, and the bundled Bash 3.2 or later.
- [actuallymentor/battery CLI](https://github.com/actuallymentor/battery#command-line-version), installed and configured according to its upstream instructions. The CLI manages its own required privileged SMC operations. Review its installer and permissions before installing it; this repository does not install or update dependencies.
- `pmset`, `ioreg`, `caffeinate`, and standard macOS command-line tools.
- Optional: [stress-ng](https://github.com/ColinIanKing/stress-ng) for `USE_STRESS_NG=1`.
- Optional: [brightness](https://github.com/nriley/brightness) for a nonempty `BRIGHT_TARGET`.

The controller uses the upstream `adapter on/off` and `charging on/off` commands. It samples thresholds itself instead of calling the blocking `charge` / `discharge` helpers. Command failure or a timeout ends the run. A state mismatch allows a 60-second transition grace, with at most five seconds between subsequent reads; the first sample after that grace must agree with the requested phase. Upstream CLI and SMC support can vary by macOS/model. Installing dependencies does not prove hardware compatibility.

## Configuration

Set environment variables before the command; invalid values fail before a real run makes changes.

| Variable | Default | Accepted values / behavior |
| --- | --- | --- |
| `LOW` | `20` | Integer `10..99`; must be less than `HIGH` |
| `HIGH` | `80` | Integer `11..100` |
| `MAX_CYCLES` | `1` | Integer `1..1000`; no implicit infinite loop |
| `POLL_SECONDS` | `15` | Integer `1..300`; shorter than both timeouts |
| `PHASE_TIMEOUT` | `21600` | Integer `60..86400` seconds per phase |
| `STALL_TIMEOUT` | `1800` | Integer `60..86400` seconds without progress toward the target |
| `LOG` | `./battery_cycle_log.csv` | Regular CSV file in an existing writable directory |
| `USE_STRESS_NG` | `0` | `1` starts one CPU worker at 50% load during discharge only |
| `BRIGHT_TARGET` | empty | Optional `0..1` brightness for **display 0**; its initial value is saved and restored |

Example with optional load and brightness:

```bash
USE_STRESS_NG=1 BRIGHT_TARGET=0.8 LOG="$PWD/experiment.csv" \
  /bin/bash battery_looper_v5.sh --run
```

The workload allocates no VM stress memory and stops before charging. Brightness changes use the CLI directly; there are no simulated keyboard events or Accessibility permission requests. Keep the display arrangement unchanged during a run so display 0 remains the same physical display.

## Logs and stopping

The CSV retains the original column names:

```text
timestamp,battery_percent,state,cycle_count,health_percent,note
```

- New timestamps use UTC ISO 8601; older rows from previous versions may use local time.
- Percentage and state come from the **same** `pmset` snapshot of the internal battery. Missing, invalid, or ambiguous readings end the run.
- `cycle_count` comes from the exact `CycleCount` I/O Registry key.
- `health_percent` is `AppleRawMaxCapacity / DesignCapacity × 100`, **not** the macOS Battery Health percentage or a controlled measurement of degradation. It can exceed 100. Optional values are blank when unavailable; blanks are not zero.
- `note` records the observed phase (`discharging` / `charging`), a reached threshold, or `transition_discharging` / `transition_charging` while waiting for a state change. `state` always records the actual reported state.
- A stalled phase, phase deadline, inconsistent state, failed write, or unexpectedly exited owned worker ends the experiment.

Press **Ctrl+C** to stop. Normal completion, errors, Ctrl+C, TERM, and HUP all attempt to stop this run's own processes, enable adapter power and charging, and restore brightness if it was changed. They preserve a nonzero failure/signal exit code. A recovery failure is reported and also exits nonzero.

The script does **not** modify `lowpowermode`, `lessbright`, or other `pmset` settings. It does not kill unrelated `yes`, `stress-ng`, or `caffeinate` processes. A per-user atomic lock prevents two copies from running concurrently, even with different log paths. If a stale `/tmp/battery-cycle-<uid>.lock` remains after a crash, inspect the PID in its `pid` file and confirm the old run is gone before removing that specific lock directory.

No shell trap can recover from SIGKILL, a power loss, or a kernel crash. A dependency may also fail to apply an SMC write even after reporting success. **Exit recovery is best effort, not a hardware guarantee.** Check the battery status after stopping. If recovery reports a problem, use the upstream CLI to inspect and recover:

```bash
battery adapter on
battery charging on
battery status
```

On normal exit, charging is enabled again; `HIGH` is an experiment threshold, **not a persistent charge cap**. Reapply your usual maintenance policy separately if desired.

## Verification and maintenance

```bash
/bin/bash tests/test_battery_looper.sh
```

The suite runs on the macOS system Bash. It uses fixture data and mocked battery/brightness/workload functions, plus harmless `sleep` processes to exercise process ownership and command timeouts. It covers configuration, parsing, complete cycles, failures, recovery, and signal behavior without changing battery state or launching CPU stress. GitHub Actions runs the same tests on macOS, with no package installation.

This release was verified using static review and simulated tests. **Real charging/discharging, SMC writes, brightness restoration, thermal behavior, and compatibility across physical MacBook models have not been exercised by this maintenance pass.** A successful dry-run is a configuration preview, not a hardware test.

Changes from 0.2 include finite runs and an explicit start flag, bounded operations and state checks, reliable error/signal cleanup, precise process ownership, exact-key telemetry parsing, and optional workload/brightness. Legacy `LOW`, `HIGH`, `LOG`, `USE_STRESS_NG`, and `BRIGHT_TARGET` remain configurable, but their defaults are intentionally less aggressive. The old all-core/60%-RAM load, fallback `yes` load, and power-setting modifications were removed.

## 中文说明

这是一个用于 **MacBook 电池退化实验** 的命令行工具，不是延长电池寿命的工具。频繁充放电会消耗电池寿命。版本 0.3.0 默认只显示执行计划；必须显式传入 `--run` 才会真实操作，默认执行一次 **20% → 80%** 循环，不提高亮度、不施加 CPU 压力。

```bash
# 只预览：不读取硬件，不写日志，不修改设置
/bin/bash battery_looper_v5.sh

# 已安装并配置好依赖后，插电、开盖、以普通用户执行
/bin/bash battery_looper_v5.sh --run

# 明确指定原有实验范围及次数
LOW=10 HIGH=100 MAX_CYCLES=2 /bin/bash battery_looper_v5.sh --run
```

需要 Apple Silicon MacBook、原生 arm64 终端以及上游 [Battery CLI](https://github.com/actuallymentor/battery#command-line-version)。本项目不会自动安装依赖。开启 `USE_STRESS_NG=1` 才需要 stress-ng；设置 `BRIGHT_TARGET` 才需要 brightness。可调参数与限制见上表。

真实运行会停止 Battery CLI 原有的维护策略，退出后不会自动恢复原策略。请先退出可能冲突的充电控制程序；结束后如需原有充电上限，自行重新执行对应的 `battery maintain` 命令。`HIGH` 只是本次实验目标，不是退出后持续生效的充电上限。

Ctrl+C、正常结束及错误退出都会尝试停止本次启动的进程、恢复供电与充电，并恢复本次修改的显示器 0 亮度；恢复失败会明确报错。脚本不再修改系统低电量模式、不再使用全局 killall。缺失或异常电量、阶段状态不一致、超时、日志写入失败都会终止实验。日志中的原始容量比不是 macOS“电池健康度”，缺失可选字段留空。

实验必须有人看护并保持散热；脚本 **没有温度传感器自动切断保护**。SIGKILL、断电或系统崩溃无法由退出清理处理，硬件恢复也不能保证成功。退出后应检查充电状态；如果报错，可执行上方恢复命令。此次维护仅进行了静态检查和模拟测试，**没有对真实电池、SMC 控制、亮度恢复或各种机型做实机验证**。

## License

[MIT](LICENSE), retaining the original copyright.
