---
name: deepseek-whale-widget
description: 启动、关闭或查询 DeepSeek 余额悬浮挂件（桌面小鲸鱼挂件），并设置它是否开机自启。当用户说「打开余额挂件」「启动小鲸鱼」「把挂件关掉」「挂件在跑吗」「设置挂件开机自启」时使用。
---

# DeepSeek 余额悬浮挂件

桌面悬浮挂件：无边框置顶的小鲸鱼 + 气泡，显示 DeepSeek 余额与今日已用，每 60 秒自动刷新。
它是**独立进程**，不在 Codex 界面里，关闭 Codex 后依然运行。

## 怎么执行

主程序位于本技能所在插件的 `scripts/widget.ps1`（相对本文件为 `../../scripts/widget.ps1`）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <plugin>/scripts/widget.ps1 -Action status
powershell -NoProfile -ExecutionPolicy Bypass -File <plugin>/scripts/widget.ps1 -Action spawn
powershell -NoProfile -ExecutionPolicy Bypass -File <plugin>/scripts/widget.ps1 -Action stop
powershell -NoProfile -ExecutionPolicy Bypass -File <plugin>/scripts/widget.ps1 -Action autostart-on
powershell -NoProfile -ExecutionPolicy Bypass -File <plugin>/scripts/widget.ps1 -Action autostart-off
```

| Action | 行为 |
| --- | --- |
| `spawn` | **后台启动**（推荐，从对话里用它）：用 WMI 创建进程，脱离调用方进程树与沙箱令牌，命令立即返回 |
| `start` | 前台启动并阻塞到窗口关闭；已在运行则只提示，不会开出第二个 |
| `stop` | 结束挂件进程并清理 pid 文件 |
| `status` | 输出运行状态、pid、是否开机自启、当前缩放与模式 |
| `autostart-on` / `autostart-off` | 在「启动」目录创建/删除快捷方式 |

## 注意事项

- 从对话里启动请用 `-Action spawn`（或 `wscript.exe <plugin>/scripts/widget-launch.vbs`）；不要用 `start`，它会一直占住 shell 直到窗口关闭。
- 如果启动后取数一直失败，通常是沙箱限制了子进程的网络/写盘：改用 `spawn`，或让用户双击 `widget-launch.vbs` / 开启开机自启——这两条路径都不经过 Codex 沙箱。
- 挂件默认**不开机自启**；未设自启时每次开机都需要通过对话或双击 `widget-launch.vbs` 打开。
- 挂件的数据来自同插件的 `scripts/balance.mjs`，因此它每 60 秒观测一次余额，账本会持续累积，`todayUsage` 比只靠问答触发更准。
- 排障看状态目录里的 `widget.log`（默认 `%USERPROFILE%\.codex\deepseek-balance\widget.log`），配置在同目录 `widget.json`。
