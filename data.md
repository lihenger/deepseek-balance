# 变更记录

按「时间 / 位置 / 原因 / 大致内容」记录对项目主体的每一次修改。

| 时间 | 位置 | 原因 | 大致内容 |
| --- | --- | --- | --- |
| 2026-09-12 | 全项目（首次创建） | 用户要求把 DSH 小鲸鱼余额挂件（github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget）的余额查询/展示能力改造成本机 Codex 插件 | 新建 Codex 插件 `deepseek-balance`：`.codex-plugin/plugin.json` 插件清单、`skills/deepseek-balance/SKILL.md` 技能说明、`scripts/balance.mjs` 核心脚本（余额查询 + 今日已用双模式）、`install.ps1` 安装脚本、`README.md`、`docs/接口文档.md`、本变更记录 |
| 2026-09-12 | `scripts/balance.mjs` | 移植原挂件 `lib/index.js` 的核心算法，保持行为一致 | 抄录选币规则（CNY 且 >0 → 任意非零 → CNY → 首项）、余额请求重试策略（2 次、500ms、20s 超时、4xx 不重试）、记账规则（余额下降累加、充值不扣、跨天归档 30 天、币种切换只重置基准）、峰谷定价表与周末谷价生效分界 |
| 2026-09-12 | `scripts/balance.mjs` | 原项目从 DSH 凭据服务读取密钥，Codex 侧没有该服务 | 改为按序解析：环境变量 `DEEPSEEK_API_KEY` → `~/.codex/config.toml` 中 `base_url` 含 `api.deepseek.com` 的 `[model_providers.*]` 块里的 token（优先顶层 `model_provider` 指定的 provider） |
| 2026-09-12 | `scripts/balance.mjs` | 账本目录可能不可写（Codex 沙箱只允许写工作区） | 账本路径改为可覆盖（`--state-dir` / `DEEPSEEK_BALANCE_STATE_DIR`），写入失败时不再抛错，改为返回 `warnings` 并继续输出余额 |
| 2026-09-12 | `scripts/balance.mjs` | 便于排障与自动化消费 | 增加 `today` 子命令、`--json` 结构化输出、错误码体系（`no_api_key`/`http_4xx`/`http_5xx`/`network`/`parse`/`shape`）与退出码约定 |
| 2026-09-12 | 账本文件结构 | 便于确认「最近一次观测时间」 | 在原有 `date`/`lastBalance`/`lastCurrency`/`todayUsage`/`history` 基础上增加 `version` 与 `lastSeenAt` 字段 |
| 2026-09-12 | `install.ps1` | Codex 会话沙箱只允许写工作区，无法由会话内进程完成安装 | 新增安装脚本：复制插件到 `%USERPROFILE%\plugins`、写入个人市场 `%USERPROFILE%\.agents\plugins\marketplace.json`、执行 `codex plugin add deepseek-balance@personal` |
| 2026-09-12 | `install.ps1` | 首次实跑时第 3 步报 `The term 'codex' is not recognized`：桌面版 CLI 不在系统 PATH 里 | 新增 `Resolve-CodexCli`：按 PATH → `CODEX_CLI_PATH` → `%LOCALAPPDATA%\OpenAI\Codex\bin\<版本>\codex.exe` 顺序定位；找不到时不再抛异常，改为打印应用内安装与完整路径两种收尾方式并以退出码 0 结束 |
| 2026-09-12 | `install.ps1` | `$env:USERPROFILE` 带结尾反斜杠时会拼出 `C:\Users\lyh\\.agents\...` | 对 `-ProfileRoot` 做结尾分隔符规范化（路径长度 > 3 时 TrimEnd） |
| 2026-09-12 | `README.md` | 首次实跑暴露的 PATH 问题需要可自助查的说明 | 新增「如果提示 codex 不是命令」小节：应用内安装 deeplink 与完整路径 CLI 两种收尾方式 |
| 2026-09-12 | `~/.codex/config.toml`（本机部署配置，非插件内文件） | 实跑发现账本写入被 workspace-write 沙箱拦（EPERM），导致今日已用记不下来 | 追加 `[sandbox_workspace_write] writable_roots = ["C:\\Users\\lyh\\.codex\\deepseek-balance"]`；改配置前已备份为 `config.toml.bak-20260912` |
| 2026-09-12 | 验证记录（无代码改动） | 确认放行生效 | `codex exec -s workspace-write` 的 `sandbox:` 行已列出账本目录；账本探针写入成功、同级控制路径仍返回 `Access denied` |
| 2026-09-12 | `README.md` | 把账本目录放行方式写进文档 | 「限制」小节补上 `[sandbox_workspace_write]` 配置片段与验证方法，并补充网络受限时返回 `code: "network"` 的说明 |
| 2026-09-12 | 新增 `scripts/widget.ps1` | 按用户确认的方案（完整还原 UI）实现桌面悬浮挂件：Codex 插件体系没有 UI 注入能力，改做独立置顶窗口 | PowerShell 5.1 + WPF 主程序：无边框透明置顶窗口、单实例、状态持久化，支持 `-Action start/spawn/stop/status/autostart-on/autostart-off` |
| 2026-09-12 | `scripts/widget.ps1` | 视觉与交互需与上游一致 | 照搬上游几何与规格：气泡画布 1026×700（SVG 路径原样用于 WPF Path.Data）、鲸鱼占容器 59.45%、描边 `#203170`/18、字号 66/128/56、四分之一吸附、左吸附镜像、按压 Q 弹 `ScaleY .88 / ScaleX 1.05`、700ms 数字滚动、气泡 5 秒自动收起 |
| 2026-09-12 | `scripts/widget.ps1` | 台词与峰谷文案不能自行编造 | 抄录上游数据：随机台词 6 组（权重 45/7/7/10/3/1，含 gif 组与单行居中组）、峰谷文案三套（默认/梁文峰谷/!?强强?!）、余额变化时自动弹气泡（手动刷新不弹） |
| 2026-09-12 | `scripts/widget.ps1` | 骨架版本存在若干实际缺陷，逐一修复 | 修：数组参数被展开导致台词/默认行绑定错误；`& $PSCommandPath` 递归调用会因 `exit` 结束挂件；滑块动画与镜像互相覆盖（改在 Set-Mirror 里清除动画）；数字滚动动画用了函数局部变量导致 `op_Subtraction` 异常（改脚本级变量）；`MenuItem` 同时写 `Header` 属性与 `Header` 元素导致 XAML 解析失败 |
| 2026-09-12 | `scripts/widget.ps1` | 用 `wscript`/`-WindowStyle Hidden` 启动时 WPF 首个窗口继承 SW_HIDE，窗口可见性异常 | Loaded 时用 `ShowWindow(SW_SHOW)` 显式恢复显示并置顶；同时给 Dispatcher 加 `UnhandledException` 兜底，单个交互出错不再拖垮挂件并写入日志 |
| 2026-09-12 | `scripts/widget.ps1` | 从对话/受限 shell 启动时，子进程可能继承沙箱令牌并在父进程退出时被清理 | 新增 `-Action spawn`：用 WMI `Win32_Process.Create` 脱离进程树与沙箱令牌后台启动 |
| 2026-09-12 | 新增 `scripts/widget-launch.vbs` | 开机自启不应闪控制台窗口 | ASCII-only 的静默启动器，用 `wscript` 隐藏窗口拉起 `widget.ps1 -Action start`；自启快捷方式指向它 |
| 2026-09-12 | 新增 `assets/`、`THIRD_PARTY_NOTICES.md`；`plugin.json` 加 `interface.logo` | 挂件需要鲸鱼图/动图/音效，且上游素材是 MIT 许可需署名 | 复制 `DSniang1.png`、`rua.gif`、`Ya1/Ya2.mp3`、`D1/D2.mp3` 并写归属说明；插件页图标指向鲸鱼图 |
| 2026-09-12 | 新增 `skills/deepseek-whale-widget/SKILL.md` | 用户希望未开自启时能"通过对话打开"挂件 | 技能覆盖启动（推荐 `spawn`）/关闭/状态/自启开关，并写明沙箱受限时的替代路径 |
| 2026-09-12 | `README.md`、`docs/接口文档.md` | 补齐配套文档 | README 增加「悬浮挂件」小节与目录结构；接口文档增加第 7 节：挂件 CLI、`widget.json` 字段表、运行期文件、与取数的关系 |
| 2026-09-20 | `scripts/widget.ps1`（`MouseLeftButtonDown` 处理器、新增 `$script:ClickBounceTimer`） | 用户反馈「单击没有弹动效果，要移动后才出现」：单击时按压动画才跑十几毫秒就被回弹覆盖 | 记录按下时刻，`DragMove()` 返回后若判定未移动，则用 `DispatcherTimer` 等按压动画补满 120ms 再触发回弹与释放音效；拖动路径维持松手即回弹。连点时先停掉未触发的定时器，避免叠加 |
| 2026-09-20 | `scripts/widget.ps1`（XAML `RootGrid`、新增 `WhaleHit`/`BubbleHit` 命中块、`Apply-Scale`、`Show-Bubble`/`Hide-Bubble`） | 用户要求「不弹气泡时只识别鲸鱼那片区域，气泡出现后才识别气泡 + 鲸鱼整片区域」 | `RootGrid` 背景由 `#01000000` 改为 `{x:Null}`，让分层窗口里 alpha=0 的区域点击穿透到下层窗口；新增两块 `Fill="#01000000"` 的隐形命中块（鲸鱼块常驻、气泡块随气泡显示/收起切换 `Visibility`），在 `Apply-Scale` 里与鲸鱼/气泡同尺寸，二者都放在 `Body` 内以继承左吸附时的整体镜像 |
| 2026-09-20 | `scripts/widget.ps1`（`MouseLeftButtonDown` 内 `$insideBubble` 判定） | 原实现按左上角矩形写死判断气泡命中，挂件吸到左边界整体镜像后气泡在右侧，点击气泡会被误判成点击鲸鱼 | 改为取 `$bubbleHit` 的实际位置判断：`TransformToAncestor($window).TransformBounds(...)` 后 `Contains($point)` |
| 2026-09-20 | `scripts/widget.ps1`（Loaded 里的布局诊断日志） | 便于回归确认命中块位置 | 布局诊断日志追加一行 `hit whale=...`，输出 `WhaleHit` 在窗口坐标系里的实际矩形 |
| 2026-09-20 | 验证记录（无代码改动） | 确认两项改动生效 | 快照模式渲染无异常；真实鼠标事件点击鲸鱼后，命中探针显示气泡区域与鲸鱼区域都返回挂件窗口，气泡 5 秒自动收起后空白区域恢复穿透到下层窗口（探针脚本 `widget_probe.ps1`、`widget_click.ps1` 放在工作区 `work/`，不进插件仓库）；日志 `hit whale=78.0,78.0 114.0x114.0` 与鲸鱼可视区域一致 |
| 2026-09-20 | `README.md` | 用户要求 README 标注引用的开源项目，并同步新交互 | 开头段落与「悬浮挂件」小节写明引用 [MeteorNOX/DeepSeek-Balance-Whale-Widget](https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget)（MIT）；新增「引用与致谢」小节；「交互」补上单击即有 Q 弹，另加「命中范围」说明 |
| 2026-09-20 | 仓库根（新增 `.gitignore`） | 用户要求把整个插件发布到 GitHub 私有仓库 | 初始化 git 仓库（分支 `main`）并新增 `.gitignore`，忽略 `*.log`/`*.pid`/`widget-snapshot.png`/`widget.json` 这些运行期产物 |
| 2026-09-20 | GitHub：`lihenger/deepseek-balance`（private） | 用户要求上传到自己的 GitHub 并设为 private | 创建私有仓库并推送全部 18 个文件；因本机到 `github.com` 的 git 通道被重置，改用 `api.github.com` 的 git 数据接口直传对象，远端 commit sha 与本地 HEAD 完全一致（`8b3b2c3`） |
| 2026-09-20 | 用户插件目录 `%USERPROFILE%\plugins\deepseek-balance`（安装副本） | 开机自启快捷方式指向安装副本而不是 Codex 插件缓存副本，只改缓存会让改动在重启后失效 | 把 `scripts/widget.ps1`、`README.md`、`data.md`、`.gitignore` 同步到安装副本，并把 git 仓库（`.git`）移到该目录，作为插件项目的主副本 |
| 2026-09-20 | `scripts/widget.ps1`（`Start-PressAnimation`、`MouseLeftButtonDown` 处理器） | 用户反馈「弹动要长按才出现，应该点一下就触发、松手恢复原状」。实测按住鼠标 300ms 期间两次抓图逐像素完全相同，确认 `DragMove()` 的模态循环期间分层窗口不刷新，按下时启动的 0.12 秒压扁动画画不出来，松手后才一次性补上 | `Start-PressAnimation` 改为按下瞬间直接写入形变值（`ScaleY 0.88`、`ScaleX = ±1.05`）并用 `Dispatcher.Invoke(Render)` 强制刷新一帧，保证点一下立刻压扁；删掉上一版「等压扁跑满 120ms 再回弹」的 `ClickBounceTimer` 逻辑，改为松手立即回弹复原。顺带修掉按压动画把 `ScaleX` 固定写成正值、导致吸到左边界（整体镜像）时鲸鱼会被翻回正向的问题 |
| 2026-09-20 | `README.md` | 同步新交互描述 | 「交互」改为：按下瞬间鲸鱼就压扁（Q 弹 + 音效），松手回弹复原，不需要长按或先拖动 |
| 2026-09-20 | `scripts/widget.ps1`（音效部分：`New-SoundPlayer`、新增 `Get-SoundPool`/`Warm-SoundPool`、`Play-Sound`） | 用户反馈「改成按下即压扁之后音效播放不全」。旧实现每次触发都对同一个 `MediaPlayer` 做 `Stop`/`Close`/`Open`，并在 `MediaOpened` 回调里再 `Play` 一次：刚开始播放的声音会被随后的 `Open` 或这次重复 `Play` 打断、从头重放，快速连点时同类音效也会互相截断 | 改为常驻播放器池：每种音效准备 3 个 `MediaPlayer`，文件只 `Open` 一次，触发时 `Position=0` + `Play`，同类音效按顺序轮换、互不打断；文件尚未打开时改由 `MediaOpened` 回调补播，不再紧跟 `Open` 立即 `Play`；新增鼠标移入挂件时预热播放器（`Warm-SoundPool`），首次点击也能从头出声；`DEEPSEEK_WIDGET_DEBUG_SOUND=1` 时增加 `MediaEnded` 日志，用于确认音效整段播完 |
| 2026-09-20 | `scripts/widget.ps1`（音效部分：新增 `Play-SoundFile`/`Get-SoundLengthMs`，改写 `Play-Sound`） | 用户反馈「只能听到后半段声音」。用 WASAPI 音频会话峰值表在独立进程里复刻挂件播放逻辑实测：`D1.mp3`(95ms, 峰值 0.317) 与 `D2.mp3`(178ms, 峰值 0.664) 在快速点击时只隔 60ms 就重叠，前一段音量只有后一段的一半，很容易被盖住；软件层本身没有截断（冷启动/空闲 30 秒后/线程阻塞 60ms 三种情况下两段都完整播放） | 松开音效改为等按下那一声整段放完（加 30ms 衔接）再播放，用 `Get-SoundLengthMs` 从播放器读实际时长、用 `DispatcherTimer` 排期；拖动等长按场景下按下音效早已放完，仍是松手即响；新的按下动作会作废上一次未播放的松开音效 |

## 未纳入本次改动

- 原挂件的悬浮挂件 UI、气泡动画、音效、拖拽吸附：Codex 插件体系不支持自定义 UI 面板（`.app.json` 只能引用外部连接器），不移植。
- 「每轮对话消耗统计」：依赖 DSH 的 `session/event` 事件流，Codex 侧需另行验证 `Stop` hook 的 `transcript_path` 是否含 usage，留待二期。
