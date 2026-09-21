# deepseek-balance

Codex 插件：在本机 Codex 里查询 DeepSeek 账户余额与今日消耗金额。

引用并移植自开源项目 [DSH 小鲸鱼余额挂件](https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget)（作者 MeteorNOX，MIT 许可）：余额与今日已用的取数逻辑来自其宿主侧实现 `lib/index.js`，悬浮挂件的鲸鱼素材、气泡视觉规格与交互（拖拽吸附、Q 弹、音效）来自其前端实现。Codex 的 `.app.json` 只能引用外部连接器（ChatGPT App），不支持自定义 UI 面板，因此挂件在 Codex 侧改写成独立置顶窗口（PowerShell + WPF）重做。

## 能力

- **余额**：`GET https://api.deepseek.com/user/balance`，选币规则与原挂件一致（优先 CNY 且余额 > 0 → 任意非零 → 回退 CNY → 首项）
- **今日已用**：两种模式
  - `ledger`（默认，免令牌）：脚本每次观测余额后用余额下降的差值累计当天用量，跨天归零并归档最近 30 天；币种切换只重置基准、不记差值
  - `token`（可选）：配置 `DEEPSEEK_PLATFORM_TOKEN` 后调用平台用量接口，按内置峰谷定价表实时换算当天金额
- **零配置凭据**：优先 `DEEPSEEK_API_KEY`，缺省时回落到 `~/.codex/config.toml` 里 `base_url` 指向 `api.deepseek.com` 的 provider token
- **续航预估与峰谷切换**：账本按小时分桶（保留最近 48 小时），`--json` 额外返回 `runtime`（每小时消耗速率、按当前余额估算的可用时长）与 `peak`（当前是否高峰、下一次切换时刻），供挂件做"还能用多久"和"峰谷提醒"

## 目录结构

```text
deepseek-balance/
├── .codex-plugin/plugin.json       # 插件清单（插件页元数据）
├── skills/deepseek-balance/SKILL.md# 技能说明：何时用、怎么调、怎么读结果
├── skills/deepseek-whale-widget/   # 技能：启动/关闭桌面悬浮挂件
├── scripts/balance.mjs             # 取数脚本（余额 + 今日已用），零依赖 Node
├── scripts/widget.ps1              # 桌面悬浮挂件主程序（PowerShell 5.1 + WPF）
├── scripts/widget-launch.vbs       # 静默启动器（开机自启快捷方式指向它）
├── assets/                         # 鲸鱼图、动图与音效（来自上游 MIT 项目）
├── install.ps1                     # 一键安装到本机 Codex
├── README.md                       # 项目文档（本文件）
├── docs/接口文档.md                 # 接口文档：CLI、JSON、账本、上游接口
├── THIRD_PARTY_NOTICES.md          # 上游素材归属与许可
└── data.md                         # 变更记录
```

## 安装

在**普通 PowerShell**（不要在 Codex 沙箱会话里）执行一条命令：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

脚本会：复制本目录到 `%USERPROFILE%\plugins\deepseek-balance` → 在 `%USERPROFILE%\.agents\plugins\marketplace.json` 写入 `personal` 市场条目 → 执行 `codex plugin add deepseek-balance@personal`。

装完后**新开一个 Codex 线程**（技能在新线程才会加载）。

### 如果提示 `The term 'codex' is not recognized`

Codex 桌面版自带 CLI，但通常不写进系统 PATH。脚本会按 `PATH` → `CODEX_CLI_PATH` → `%LOCALAPPDATA%\OpenAI\Codex\bin\<版本目录>\codex.exe` 的顺序自动定位；如果都没找到，前两步（复制源码、写市场条目）仍然已完成，改用下面任一方式收尾：

**方式 A：在 Codex 应用里安装（推荐）** —— 个人市场是被自动发现的，打开插件页点安装即可：

```text
codex://plugins/deepseek-balance?marketplacePath=C%3A%5CUsers%5C<用户名>%5C.agents%5Cplugins%5Cmarketplace.json
```

**方式 B：用完整路径执行 CLI**

```powershell
& "$env:LOCALAPPDATA\OpenAI\Codex\bin\7ac07f4ce733f89a\codex.exe" plugin add deepseek-balance@personal
```

版本目录名（这里是 `7ac07f4ce733f89a`）以 `%LOCALAPPDATA%\OpenAI\Codex\bin` 下的实际目录为准。

> 为什么安装要手工跑一次：Codex 会话内的 shell 沙箱只允许写工作区，`%USERPROFILE%\plugins`、`%USERPROFILE%\.agents`、`%USERPROFILE%\.codex` 都在工作区之外，因此最后这一步需要你在沙箱外用普通权限执行。

卸载：

```powershell
codex plugin remove deepseek-balance
Remove-Item "$env:USERPROFILE\plugins\deepseek-balance" -Recurse -Force
```

## 使用

在 Codex 里直接问即可，例如：

- 查一下 DeepSeek 余额
- 今天 DeepSeek 花了多少钱

也可以手工跑脚本：

```powershell
node "$env:USERPROFILE\plugins\deepseek-balance\scripts\balance.mjs" balance
node "$env:USERPROFILE\plugins\deepseek-balance\scripts\balance.mjs" today --json
node "$env:USERPROFILE\plugins\deepseek-balance\scripts\balance.mjs" balance --mode token
```

参数与输出字段见 [docs/接口文档.md](docs/接口文档.md)。

## 悬浮挂件

桌面悬浮小鲸鱼：无边框、置顶、不占任务栏，显示余额与今日已用，每 60 秒自动刷新。它是**独立进程**，关掉 Codex 也照常在跑。

```powershell
$w = "$env:USERPROFILE\plugins\deepseek-balance\scripts\widget.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $w -Action spawn   # 后台启动（推荐）
powershell -NoProfile -ExecutionPolicy Bypass -File $w -Action stop    # 关闭
powershell -NoProfile -ExecutionPolicy Bypass -File $w -Action status  # 查看状态
powershell -NoProfile -ExecutionPolicy Bypass -File $w -Action autostart-on   # 开机自启
powershell -NoProfile -ExecutionPolicy Bypass -File $w -Action autostart-off
```

也可以双击 `scripts\widget-launch.vbs` 启动（无控制台窗口），或在对话里说「打开余额挂件」。

**交互**：拖拽移动，松手后按四分之一区域吸附（左右上下可组合），吸到左边时整体水平镜像、文字仍可读；点击鲸鱼立即刷新并弹出气泡；按下瞬间鲸鱼就压扁（Q 弹 + 音效），松手回弹复原，不需要长按或先拖动；气泡打开时点击气泡切换随机台词，再点一次关闭；气泡 5 秒自动收起；余额变化时自动弹气泡并滚动数字。

**命中范围**：窗口是透明分层窗口，只有划定的命中块接收鼠标，其余区域的点击直接穿透到下层窗口——气泡收起时只有鲸鱼那片生效，气泡弹出后气泡 + 鲸鱼整片生效。

**蓝牙/无线音频设备**：这类设备静置一会儿会休眠，唤醒要 100~500ms 才出声，而挂件音效只有 95~264ms，开头会被设备吞掉。所以光标停在挂件上时，挂件会循环播放一段数字静音让音频设备保持活动，光标移开立即停止——只在即将点击的这段时间占用设备，不会额外耗电。

**文案排版**：文字区取气泡内接矩形（480×280，居中于气泡椭圆），行高随字号按 1.1 倍缩放；文案整体超框时（超长台词、百万级金额等）自动等比缩小，不会再顶出气泡描边或被窗口边缘裁掉。

**右键菜单**：大小滑块、音效开关与音量、音效集（小黄鸭 / 音效1 / 重载音效）、用量模式（小鲸鱼记账 / 实时·令牌）、峰谷文案（默认 / 梁文峰谷 / !?强强?!）、告警（余额告警 / 今日预算 / 峰谷切换提醒）、气泡开关、只留托盘、开机自启、立即刷新、退出。设置写在 `%USERPROFILE%\.codex\deepseek-balance\widget.json`。

**续航与提醒**：气泡第三行显示 `今日已用 ¥x.xx · 可用约 N 天`（按最近小时分桶的消耗速率估算，样本不足时退回今日均值，估不出来就不显示）。峰谷切换前 15 分钟提醒一次、切换瞬间弹一次气泡与通知；余额低于告警线（默认 ¥5，6 小时内只提醒一次）或今日用量超过预算（默认关）时同样会提醒，金额档位在右键菜单「告警」里选。

**托盘与通知**：挂件常驻一个托盘图标（鲸鱼头像）。双击托盘切换悬浮窗显示，右键托盘可 立即刷新 / 开机自启 / 只留托盘 / 退出。需要告知你的事情（取数失败、自愈动作、后续的余额告警与更新提示）会走同一条通道：鲸鱼右上角角标（红=取数失败或余额告警、橙=自愈事件、蓝=有新版本）+ 一次 Windows 托盘气泡，事件记在 `events.json`（最多 50 条）；同一个来源 10 分钟内只弹一次气泡。托盘气泡可以在菜单里关掉，角标与事件记录不受影响。

**排障**：日志在同目录 `widget.log`；窗口是分层窗口（GDI 截屏抓不到），需要核对渲染时用 `DEEPSEEK_WIDGET_SNAPSHOT=1` 启动，会在同目录生成 `widget-snapshot.png`。音效没声音时：挂件在系统睡眠恢复 / 解锁后会自动重建播放器（WPF `MediaPlayer` 睡眠后会变成不出声的"哑"实例），也可以右键菜单点「音效集 → 重载音效」，或直接重启挂件。

挂件素材（鲸鱼图、动图、音效）与视觉规格来自上游项目 [MeteorNOX/DeepSeek-Balance-Whale-Widget](https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget)（MIT），署名与许可全文见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 凭据

| 变量 | 必需 | 说明 |
| --- | --- | --- |
| `DEEPSEEK_API_KEY` | 否 | 余额接口密钥。未设置时回落到 `~/.codex/config.toml` |
| `DEEPSEEK_PLATFORM_TOKEN` | 否 | 仅 `token` 模式需要；平台网页会话令牌（非 `sk-` 开头） |
| `DEEPSEEK_BALANCE_MODE` | 否 | 默认用量模式，`ledger` 或 `token` |
| `DEEPSEEK_BALANCE_STATE_DIR` | 否 | 账本目录，默认 `%USERPROFILE%\.codex\deepseek-balance` |

## 限制

- **记账模式只在脚本被调用时观测余额**，Codex 没运行期间的消耗会漏记；要更准就用 `token` 模式，或让某个自动化定时调用脚本刷账本。
- 账本默认写在 `~/.codex/deepseek-balance/`。Codex 的 workspace-write 沙箱默认只允许写工作区，需要在 `~/.codex/config.toml` 里额外放行该目录（本机已配置）：

  ```toml
  [sandbox_workspace_write]
  writable_roots = ["C:\\Users\\lyh\\.codex\\deepseek-balance"]
  ```

  验证方式：`codex exec -s workspace-write "..."` 启动时的 `sandbox:` 行会列出可写根目录。若不方便改配置，用 `--state-dir` 或 `DEEPSEEK_BALANCE_STATE_DIR` 指到可写目录；写入失败时脚本不报错，只在 `warnings` 里说明并继续给出余额。
- 网络同样受沙箱约束：受限会话里调用余额接口可能返回 `code: "network"`，需要放行网络后在允许网络的会话里重跑。
- 峰谷定价表内置在 `scripts/balance.mjs` 顶部（`PRICING` / `PEAK_HOURS` / `WEEKEND_VALLEY_FROM_SEC`），DeepSeek 调价后需要手工同步。
- 未移植原挂件的"每轮对话消耗统计"：那依赖 DSH 的 `session/event` 事件流，Codex 侧需要另做验证，暂不在本插件范围内。

## 引用与致谢

本项目的取数逻辑、挂件视觉规格与素材均引用自开源项目 [DSH 小鲸鱼余额挂件（MeteorNOX/DeepSeek-Balance-Whale-Widget）](https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget)，原作者 MeteorNOX，MIT 许可。Codex 侧做的是宿主改造：取数重写为 Node 脚本（`scripts/balance.mjs`），挂件重写为 PowerShell + WPF 独立置顶窗口（`scripts/widget.ps1`）。素材署名与许可全文见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 变更记录

见 [data.md](data.md)。
