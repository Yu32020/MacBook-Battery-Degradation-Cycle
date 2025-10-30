# MacBook Battery Degradation Cycle (Beta 0.1)

A macOS shell script to automatically cycle battery charge and discharge to test long-term degradation.

---

## 🧰 Requirements
Before running, make sure these tools are installed:

```bash
brew install brightness stress-ng
brew install --cask battery
open -a Battery
battery visudo
```

---

## ▶️ Usage

1. **Clone or download the repository:**
   ```bash
   git clone https://github.com/Yu32020/MacBook-Battery-Degradation-Cycle.git
   cd MacBook-Battery-Degradation-Cycle
   ```

2. **Grant permission and run:**
   ```bash
   chmod +x battery_looper_v5.sh
   ./battery_looper_v5.sh
   ```

3. **What it does:**
   - Discharges the battery to 10%.
   - Charges it back to 100%.
   - Repeats the cycle automatically.
   - Logs battery percentage, health, and cycles in `~/battery_cycle_log.csv`.

Press **Ctrl + C** to stop safely (it will restore all power settings automatically).

---

## ⚙️ Version
**Beta 0.1** — Initial public beta release.

---

## 🪪 License
MIT License © 2025 Yu32020

---

# 💡 中文说明（Chinese Version）

## 📘 项目简介
这是一个用于 **MacBook 电池老化测试** 的自动化 Shell 脚本。  
它能自动控制电池循环充放电，以观察电池健康度随循环次数的变化。

---

## 🧰 运行前准备
请先确保你已安装以下工具：

```bash
brew install brightness stress-ng
brew install --cask battery
open -a Battery
battery visudo
```

这些工具的作用如下：
- `brightness`：控制屏幕亮度；
- `stress-ng`：制造 CPU 压力，加速放电；
- `battery`：AlDente 提供的 CLI，用于充放电控制。

---

## ▶️ 使用方法

1. 克隆或下载本仓库：
   ```bash
   git clone https://github.com/Yu32020/MacBook-Battery-Degradation-Cycle.git
   cd MacBook-Battery-Degradation-Cycle
   ```

2. 赋予执行权限并运行：
   ```bash
   chmod +x battery_looper_v5.sh
   ./battery_looper_v5.sh
   ```

3. 脚本会自动执行以下流程：
   - 放电至 10%；
   - 自动充电至 100%；
   - 持续循环；
   - 并将日志记录到 `~/battery_cycle_log.csv`。

按下 **Ctrl + C** 可安全中止，程序会自动恢复充电状态及节能设置。

---

## ⚙️ 版本信息
**Beta 0.1** — 首个公开测试版。

---

## 🪪 许可证
MIT 开源许可证 © 2025 Yu32020
