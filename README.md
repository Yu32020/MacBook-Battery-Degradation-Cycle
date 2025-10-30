# MacBook Battery Degradation Cycle (Beta 0.2)

A macOS shell script to cycle battery charge/discharge between 10% and 100% and log stats to evaluate long-term degradation.  
**CLI-only, headless (no GUI pop-ups).**

---

## 🧰 Requirements

Install **Battery CLI** (no GUI needed):
```bash
curl -sS https://raw.githubusercontent.com/actuallymentor/battery/main/setup.sh | bash
battery visudo
battery status
```

Install other tools:
```bash
brew install brightness stress-ng
```

---

## ▶️ Usage

```bash
chmod +x battery_looper_v5.sh
./battery_looper_v5.sh
```

What it does:
- Forces **max brightness**.
- Applies **CPU load** to accelerate discharge.
- **Discharges to 10%**, then **charges to 100%**, looping automatically.
- Writes logs to `~/battery_cycle_log.csv`:
  - `timestamp, battery_percent, state, cycle_count, health_percent, note`
- Safe stop: press **Ctrl + C** (restores charging and power settings).

Tip:
```bash
tail -f ~/battery_cycle_log.csv
```

---

## ⚙️ Version
**Beta 0.2 — CLI-only, headless.**

---

## 🪪 License
MIT License © 2025

---

# 💡 中文说明

## 📘 项目简介
用于评估 **MacBook 电池长期老化** 的自动化脚本。  
循环在 **10% ↔ 100%** 之间充放电，并记录日志。  
**仅使用 Battery 的 CLI，不唤起 GUI，因此不会弹窗。**

---

## 🧰 运行前准备

安装 **Battery CLI**（无需 GUI）：
```bash
curl -sS https://raw.githubusercontent.com/actuallymentor/battery/main/setup.sh | bash
battery visudo
battery status
```

安装其它依赖：
```bash
brew install brightness stress-ng
```

---

## ▶️ 使用方法

```bash
chmod +x battery_looper_v5.sh
./battery_looper_v5.sh
```

脚本会：
- 强制 **最高亮度**；
- 施加 **CPU 压力** 加速放电；
- **放电到 10%** 后 **自动充到 100%**，持续循环；
- 日志写入 `~/battery_cycle_log.csv`，字段为：
  - `timestamp, battery_percent, state, cycle_count, health_percent, note`
- **Ctrl + C** 可安全停止（会恢复充电与电源设置）。

查看日志：
```bash
tail -f ~/battery_cycle_log.csv
```

---

## ⚙️ 版本
**Beta 0.2 —— 仅 CLI、无弹窗。**
