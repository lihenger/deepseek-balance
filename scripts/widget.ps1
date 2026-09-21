#Requires -Version 5.1
<#
    DeepSeek 余额悬浮挂件（deepseek-balance 插件的桌面挂件部分）

    视觉与交互还原自上游 DSH 小鲸鱼余额挂件：
      https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget （MIT）
    余额与今日已用复用插件内的 scripts/balance.mjs，不另写一套取数逻辑。

    用法：
      widget.ps1 -Action start            启动挂件（前台阻塞，直到窗口关闭）
      widget.ps1 -Action stop             结束挂件
      widget.ps1 -Action status           查看运行状态与自启状态
      widget.ps1 -Action autostart-on     写入「启动」快捷方式
      widget.ps1 -Action autostart-off    删除「启动」快捷方式
#>
[CmdletBinding()]
param(
    [ValidateSet('start', 'spawn', 'stop', 'status', 'autostart-on', 'autostart-off', 'test-sound')]
    [string]$Action = 'start',

    [int]$Interval = 60
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 路径

$PluginRoot = Split-Path -Parent $PSScriptRoot
$BalanceScript = Join-Path $PSScriptRoot 'balance.mjs'
$LauncherPath = Join-Path $PSScriptRoot 'widget-launch.vbs'
$AssetsDir = Join-Path $PluginRoot 'assets'

function Get-CodexHome {
    if ($env:CODEX_HOME) { return $env:CODEX_HOME }
    $profile = $env:USERPROFILE
    if (-not $profile) { $profile = [Environment]::GetFolderPath('UserProfile') }
    return (Join-Path $profile '.codex')
}

if ($env:DEEPSEEK_BALANCE_STATE_DIR) {
    $StateDir = $env:DEEPSEEK_BALANCE_STATE_DIR
} else {
    $StateDir = Join-Path (Get-CodexHome) 'deepseek-balance'
}

$StateFile = Join-Path $StateDir 'widget.json'
$PidFile = Join-Path $StateDir 'widget.pid'
$LogFile = Join-Path $StateDir 'widget.log'
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'DeepSeek 余额挂件.lnk'
$WhalePng = Join-Path $AssetsDir 'DSniang1.png'
$RuaGif = Join-Path $AssetsDir 'rua.gif'

$SoundSets = @{
    duck = @{ press = 'Ya1.mp3'; release = 'Ya2.mp3' }
    fx1  = @{ press = 'D1.mp3';  release = 'D2.mp3' }
}

function Write-Log {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $StateDir)) {
            New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
        }
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 100KB)) {
            Remove-Item -LiteralPath $LogFile -Force
        }
        Add-Content -LiteralPath $LogFile -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
    } catch { }
}

function Get-DefaultState {
    return [ordered]@{
        scale     = 1.5
        left      = $null
        top       = $null
        snapH     = 'right'
        snapV     = 'bottom'
        sound     = $true
        soundSet  = 'duck'
        volume    = 0.6
        usageMode = 'ledger'
        peakMode  = 'default'
        bubbleOn  = $true
        trayOnly  = $false
        trayNotify = $true
    }
}

function Read-WidgetState {
    $state = Get-DefaultState
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $saved = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($key in @($state.Keys)) {
                if ($saved.PSObject.Properties.Name -contains $key) {
                    $state[$key] = $saved.$key
                }
            }
        } catch {
            Write-Log ('状态文件解析失败，使用默认值: ' + $_.Exception.Message)
        }
    }
    if ($state.scale -lt 0.6) { $state.scale = 0.6 }
    if ($state.scale -gt 2.5) { $state.scale = 2.5 }
    if ($state.volume -lt 0) { $state.volume = 0 }
    if ($state.volume -gt 1) { $state.volume = 1 }
    if ($state.soundSet -ne 'fx1') { $state.soundSet = 'duck' }
    if ($state.usageMode -ne 'token') { $state.usageMode = 'ledger' }
    if (@('default', 'liangwen', 'qiangqiang') -notcontains $state.peakMode) { $state.peakMode = 'default' }
    if (@('left', 'right') -notcontains $state.snapH) { $state.snapH = $null }
    if (@('top', 'bottom') -notcontains $state.snapV) { $state.snapV = $null }
    return $state
}

function Save-WidgetState {
    param($State)
    try {
        if (-not (Test-Path -LiteralPath $StateDir)) {
            New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
        }
        ($State | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $StateFile -Encoding UTF8
    } catch {
        Write-Log ('状态保存失败: ' + $_.Exception.Message)
    }
}

function Get-RunningPid {
    if (-not (Test-Path -LiteralPath $PidFile)) { return $null }
    try {
        $raw = (Get-Content -LiteralPath $PidFile -Raw -Encoding UTF8).Trim()
        $pidValue = 0
        if (-not [int]::TryParse($raw, [ref]$pidValue)) { return $null }
        $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
        if ($proc -and ($proc.ProcessName -eq 'powershell' -or $proc.ProcessName -eq 'pwsh')) { return $pidValue }
    } catch { }
    return $null
}

function Get-NodePath {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    foreach ($candidate in @('D:\node.js\node.exe', 'C:\Program Files\nodejs\node.exe')) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return 'node'
}

# ---------------------------------------------------------------- 开机自启

function Enable-Autostart {
    if (-not (Test-Path -LiteralPath $LauncherPath)) {
        throw ('启动器缺失: ' + $LauncherPath)
    }
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($ShortcutPath)
    $link.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $link.Arguments = '"{0}"' -f $LauncherPath
    $link.WorkingDirectory = $PSScriptRoot
    $link.Description = 'DeepSeek 余额悬浮挂件'
    $link.WindowStyle = 7
    $link.Save()
    Write-Log 'autostart-on'
}

function Disable-Autostart {
    if (Test-Path -LiteralPath $ShortcutPath) {
        Remove-Item -LiteralPath $ShortcutPath -Force
        Write-Log 'autostart-off'
        return $true
    }
    return $false
}

# ---------------------------------------------------------------- 动作

switch ($Action) {
    'status' {
        $running = Get-RunningPid
        $autostart = Test-Path -LiteralPath $ShortcutPath
        $state = Read-WidgetState
        if ($running) {
            Write-Output ("运行中 (pid {0})" -f $running)
        } else {
            Write-Output '未运行'
        }
        Write-Output ('开机自启: ' + $(if ($autostart) { '已开启' } else { '未开启' }))
        Write-Output ('状态文件: ' + $StateFile)
        Write-Output ('缩放 {0} / 用量模式 {1} / 音效 {2} / 气泡 {3}' -f $state.scale, $state.usageMode, $(if ($state.sound) { '开' } else { '关' }), $(if ($state.bubbleOn) { '开' } else { '关' }))
        exit 0
    }
    'stop' {
        $running = Get-RunningPid
        if (-not $running) {
            Write-Output '挂件未在运行'
            if (Test-Path -LiteralPath $PidFile) { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue }
            exit 0
        }
        try {
            Stop-Process -Id $running -Force -ErrorAction Stop
            Write-Log ('stop: 结束进程 ' + $running)
            Write-Output ('已结束挂件 (pid {0})' -f $running)
        } catch {
            Write-Output ('结束失败: ' + $_.Exception.Message)
        }
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        exit 0
    }
    'spawn' {
        # 后台启动：用 WMI 创建进程，既脱离调用者的进程树（避免父进程退出时被连带清理），
        # 也不继承受限沙箱令牌，适合从对话/受限 shell 里拉起挂件。
        $running = Get-RunningPid
        if ($running) {
            Write-Output ('挂件已在运行 (pid {0})' -f $running)
            exit 0
        }
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Output ('启动器缺失: ' + $LauncherPath)
            exit 1
        }
        try {
            $wmi = [wmiclass]'Win32_Process'
            $result = $wmi.Create(('wscript.exe "{0}"' -f $LauncherPath))
            if ($result.ReturnValue -ne 0) {
                Write-Output ('启动失败，WMI ReturnValue=' + $result.ReturnValue)
                exit 1
            }
        } catch {
            Write-Output ('启动失败: ' + $_.Exception.Message)
            exit 1
        }
        Start-Sleep -Seconds 2
        $started = Get-RunningPid
        if ($started) { Write-Output ('已启动挂件 (pid {0})' -f $started) }
        else { Write-Output '已发出启动请求，用 status 复查' }
        exit 0
    }
    'autostart-on' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Output ('启动器缺失: ' + $LauncherPath)
            exit 1
        }
        Enable-Autostart
        Write-Output ('已开启开机自启: ' + $ShortcutPath)
        exit 0
    }
    'autostart-off' {
        if (Disable-Autostart) {
            Write-Output '已关闭开机自启'
        } else {
            Write-Output '开机自启本来就没开'
        }
        exit 0
    }
    'test-sound' {
        # 排查"听不到声音"：依次播放两套音效的按下/松手音，并打印播放器状态。
        Add-Type -AssemblyName PresentationCore
        foreach ($setName in @('duck', 'fx1')) {
            foreach ($kind in @('press', 'release')) {
                $set = $SoundSets[$setName]
                $file = Join-Path $AssetsDir $set[$kind]
                if (-not (Test-Path -LiteralPath $file)) {
                    Write-Output ("{0}/{1}: 文件缺失 {2}" -f $setName, $kind, $file)
                    continue
                }
                $player = New-Object System.Windows.Media.MediaPlayer
                $player.Volume = 1
                $player.Open((New-Object System.Uri $file))
                Start-Sleep -Milliseconds 700
                $player.Play()
                Start-Sleep -Milliseconds 900
                Write-Output ("{0}/{1}: HasAudio={2} Duration={3} Position={4}" -f `
                    $setName, $kind, $player.HasAudio, $player.NaturalDuration, $player.Position)
                $player.Stop()
                $player.Close()
            }
        }
        Write-Output '以上四个音效应按顺序播放一遍（小黄鸭按下/松手，音效1按下/松手）。'
        exit 0
    }
}

# ---------------------------------------------------------------- 启动挂件

$existing = Get-RunningPid
if ($existing) {
    Write-Output ('挂件已在运行 (pid {0})' -f $existing)
    exit 0
}

if (-not (Test-Path -LiteralPath $BalanceScript)) {
    Write-Output ('缺少取数脚本: ' + $BalanceScript)
    exit 1
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# 用 wscript / Start-Process -WindowStyle Hidden 启动时，进程的 STARTUPINFO 会把
# wShowWindow 设为 SW_HIDE，WPF 的首个窗口会继承隐藏状态（窗口存在但看不见）。
# 这里在 Loaded 时显式 ShowWindow + 置顶，保证挂件一定能显示出来。
Add-Type -Namespace DeepSeekWidget -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
'@

$script:Cfg = Read-WidgetState
$script:BaseSize = 320
# 气泡文案可用区：白色气泡是椭圆（中心 454,247，半轴约 355×214），
# 取它的内接矩形 480×280 作为文字区，文案超框时再整体等比缩小
$script:TextBoxWidth = 480.0
$script:TextBoxHeight = 280.0
$script:BubbleOpen = $false
$script:RandomActive = $false
$script:RandomLines = $null
$script:ShownBalance = $null
$script:ShownCurrency = 'CNY'
$script:Status = 'loading'
$script:Message = ''
$script:TodayUsage = $null
$script:IsPeak = $false
$script:RefreshPipeline = $null
$script:RefreshHandle = $null
$script:RollTimer = $null
$script:RollFrom = 0.0
$script:RollTo = 0.0
$script:RollStartAt = Get-Date
$script:RollDurationMs = 700
$script:BubbleTimer = $null
$script:GifTimer = $null
$script:GifFrames = $null
$script:GifIndex = 0
$script:SnapshotTimer = $null
$script:LastHint = $null

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DeepSeek 余额挂件"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True" ResizeMode="NoResize"
        UseLayoutRounding="True" FontFamily="Microsoft YaHei UI, Segoe UI">
  <Window.ContextMenu>
    <ContextMenu x:Name="WidgetMenu" FontFamily="Microsoft YaHei UI, Segoe UI" FontSize="12">
      <MenuItem>
        <MenuItem.Header>
          <Slider x:Name="ScaleSlider" Width="170" Minimum="0.6" Maximum="2.5" Value="1.5"
                  TickFrequency="0.1" IsSnapToTickEnabled="True"/>
        </MenuItem.Header>
      </MenuItem>
      <Separator/>
      <MenuItem x:Name="SoundItem" Header="音效" IsCheckable="True" IsChecked="True"/>
      <MenuItem>
        <MenuItem.Header>
          <Slider x:Name="VolumeSlider" Width="170" Minimum="0" Maximum="1" Value="0.6"/>
        </MenuItem.Header>
      </MenuItem>
      <MenuItem Header="音效集">
        <MenuItem x:Name="SoundDuck" Header="小黄鸭" IsCheckable="True" IsChecked="True"/>
        <MenuItem x:Name="SoundFx1" Header="音效1" IsCheckable="True"/>
        <Separator/>
        <MenuItem x:Name="SoundReload" Header="重载音效"/>
      </MenuItem>
      <Separator/>
      <MenuItem Header="用量">
        <MenuItem x:Name="ModeLedger" Header="小鲸鱼记账 (推荐)" IsCheckable="True" IsChecked="True"/>
        <MenuItem x:Name="ModeToken" Header="实时·令牌" IsCheckable="True"/>
      </MenuItem>
      <MenuItem Header="峰谷文案">
        <MenuItem x:Name="PeakDefault" Header="默认" IsCheckable="True" IsChecked="True"/>
        <MenuItem x:Name="PeakLiangwen" Header="梁文峰谷" IsCheckable="True"/>
        <MenuItem x:Name="PeakQiangqiang" Header="!?强强?!" IsCheckable="True"/>
      </MenuItem>
      <Separator/>
      <MenuItem x:Name="BubbleItem" Header="气泡" IsCheckable="True" IsChecked="True"/>
      <MenuItem x:Name="TrayOnlyItem" Header="只留托盘（隐藏悬浮窗）" IsCheckable="True"/>
      <MenuItem x:Name="AutostartItem" Header="开机自启" IsCheckable="True"/>
      <Separator/>
      <MenuItem x:Name="RefreshItem" Header="立即刷新"/>
      <MenuItem x:Name="ExitItem" Header="退出"/>
    </ContextMenu>
  </Window.ContextMenu>
  <!-- RootGrid 全透明：分层窗口里 alpha=0 的像素不参与命中测试，点击会穿透到下层窗口。
       可交互区域改由 Body 内的两块隐形命中块划定。 -->
  <Grid x:Name="RootGrid" Background="{x:Null}">
    <Grid x:Name="Body" RenderTransformOrigin="0.5,1">
      <Grid.RenderTransform>
        <ScaleTransform x:Name="BodyScale" ScaleX="1" ScaleY="1"/>
      </Grid.RenderTransform>
      <!-- 命中块用 alpha=1 的近透明填充：肉眼看不见，但能让该矩形参与分层窗口命中测试。
           两块都放在 Body 内，左吸附整体镜像时自动跟着鲸鱼/气泡翻到另一侧。 -->
      <Rectangle x:Name="BubbleHit" HorizontalAlignment="Left" VerticalAlignment="Top"
                 Fill="#01000000" Visibility="Collapsed"/>
      <Rectangle x:Name="WhaleHit" HorizontalAlignment="Right" VerticalAlignment="Bottom"
                 Fill="#01000000"/>
      <Viewbox x:Name="BubbleBox" Stretch="Fill" HorizontalAlignment="Left" VerticalAlignment="Top"
               Width="480" Height="327">
        <Viewbox.RenderTransform>
          <ScaleTransform x:Name="BubbleScale" ScaleX="1" ScaleY="1"/>
        </Viewbox.RenderTransform>
        <Canvas x:Name="BubbleCanvas" Width="1026" Height="700">
          <Path x:Name="BubbleShape" Opacity="0"
                Data="M 827 248 A 373 232 0 1 0 81 246 A 373 232 0 0 0 301 465 A 57 32 10 0 0 413 484 A 373 232 0 0 0 827 248 Z"
                Fill="#FFFFFF" Stroke="#203170" StrokeThickness="18"
                StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
          <Ellipse x:Name="BubbleB1" Opacity="0" Canvas.Left="314.5" Canvas.Top="535" Width="75" Height="52"
                   Fill="#FFFFFF" Stroke="#203170" StrokeThickness="18"/>
          <Ellipse x:Name="BubbleB2" Opacity="0" Canvas.Left="417.5" Canvas.Top="628" Width="49" Height="36"
                   Fill="#FFFFFF" Stroke="#203170" StrokeThickness="18"/>
          <Image x:Name="GifImage" Canvas.Left="293.8" Canvas.Top="106" Width="320" Height="320"
                 Visibility="Collapsed" Stretch="Uniform"/>
          <Grid x:Name="TextGroup" Canvas.Left="214" Canvas.Top="107" Width="480" Height="280" Opacity="0"
                RenderTransformOrigin="0.5,0.5">
            <Grid.RenderTransform>
              <ScaleTransform x:Name="TextMirror" ScaleX="1" ScaleY="1"/>
            </Grid.RenderTransform>
            <StackPanel x:Name="TextStack" VerticalAlignment="Center" HorizontalAlignment="Stretch">
              <TextBlock x:Name="Line1" TextAlignment="Center" FontSize="66" FontWeight="SemiBold"
                         Foreground="#536ba9" Text="DeepSeek 余额"/>
              <TextBlock x:Name="Line2" TextAlignment="Center" FontSize="128" FontWeight="Bold"
                         Foreground="#536ba9" LineHeight="134"/>
              <TextBlock x:Name="Line3" TextAlignment="Center" FontSize="56" Foreground="#9fb0d9"
                         TextWrapping="Wrap" Margin="0,9,0,0"/>
            </StackPanel>
          </Grid>
        </Canvas>
      </Viewbox>
      <Image x:Name="WhaleImage" HorizontalAlignment="Right" VerticalAlignment="Bottom"
             Width="285" Height="285" Stretch="Uniform"/>
      <!-- 角标：取数失败/告警（红）、自愈事件（橙）、有新版本（蓝）；放在 Body 内随镜像一起翻转 -->
      <Ellipse x:Name="NoticeBadge" Width="34" Height="34" Visibility="Collapsed"
               HorizontalAlignment="Right" VerticalAlignment="Bottom"
               Fill="#e0433f" Stroke="#FFFFFF" StrokeThickness="6"/>
    </Grid>
  </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)

# 事件处理器里抛出的异常默认会让 WPF 直接结束整个挂件；这里兜住并写日志，
# 保证单个交互出错时挂件继续运行。
[System.Windows.Threading.Dispatcher]::CurrentDispatcher.Add_UnhandledException({
    param($sender, $eventArgs)
    Write-Log ('未处理异常: ' + $eventArgs.Exception.Message)
    $eventArgs.Handled = $true
})

$rootGrid = $window.FindName('RootGrid')
$body = $window.FindName('Body')
$bodyScale = $window.FindName('BodyScale')
$bubbleBox = $window.FindName('BubbleBox')
$bubbleScale = $window.FindName('BubbleScale')
$bubbleShape = $window.FindName('BubbleShape')
$bubbleB1 = $window.FindName('BubbleB1')
$bubbleB2 = $window.FindName('BubbleB2')
$textGroup = $window.FindName('TextGroup')
$textMirror = $window.FindName('TextMirror')
$line1 = $window.FindName('Line1')
$line2 = $window.FindName('Line2')
$line3 = $window.FindName('Line3')
$gifImage = $window.FindName('GifImage')
$whaleImage = $window.FindName('WhaleImage')
$textStack = $window.FindName('TextStack')
$whaleHit = $window.FindName('WhaleHit')
$bubbleHit = $window.FindName('BubbleHit')
$noticeBadge = $window.FindName('NoticeBadge')

$menu = $window.FindName('WidgetMenu')
$scaleSlider = $window.FindName('ScaleSlider')
$volumeSlider = $window.FindName('VolumeSlider')
$soundItem = $window.FindName('SoundItem')
$soundDuck = $window.FindName('SoundDuck')
$soundFx1 = $window.FindName('SoundFx1')
$soundReload = $window.FindName('SoundReload')
$modeLedger = $window.FindName('ModeLedger')
$modeToken = $window.FindName('ModeToken')
$peakDefault = $window.FindName('PeakDefault')
$peakLiangwen = $window.FindName('PeakLiangwen')
$peakQiangqiang = $window.FindName('PeakQiangqiang')
$bubbleItem = $window.FindName('BubbleItem')
$trayOnlyItem = $window.FindName('TrayOnlyItem')
$autostartItem = $window.FindName('AutostartItem')
$refreshItem = $window.FindName('RefreshItem')
$exitItem = $window.FindName('ExitItem')

if (Test-Path -LiteralPath $WhalePng) {
    $whaleImage.Source = New-Object System.Windows.Media.Imaging.BitmapImage (New-Object System.Uri $WhalePng)
}

$script:SoundDebug = ($env:DEEPSEEK_WIDGET_DEBUG_SOUND -eq '1')

# 播放器仍按需创建（自启是在登录时拉起的，那时音频栈可能还没就绪，早建的播放器会一直是哑的），
# 但创建后常驻复用：文件只 Open 一次，之后每次触发只做 Position=0 + Play。
# 旧实现每次触发都 Stop/Close/Open 同一个 MediaPlayer，并在 MediaOpened 回调里再 Play 一次，
# 刚开始的声音会被随后的 Open 或重复 Play 打断，听起来就是"播放不全"。
# 同一类音效准备 3 个播放器轮换，连续点击时前后两次不会互相截断。
$script:SoundPool = @{}
$script:SoundPoolCursor = @{}
$script:SoundReady = @{}
$script:SoundPending = @{}
$script:SoundLength = @{}
$script:LastPressAt = $null
$script:LastPressLengthMs = 150.0
$script:ReleaseTimer = $null
$script:PendingRelease = $null
$script:SoundStale = $false
$script:SoundCheckPlayer = $null
$script:SoundHealthTimer = $null
$script:SoundPoolSize = 3

function New-SoundPlayer {
    param([string]$File)
    $player = New-Object System.Windows.Media.MediaPlayer
    $player.Volume = [double]$script:Cfg.volume
    $player.add_MediaOpened({
        param($sender, $eventArgs)
        $script:SoundReady[$sender] = $true
        if ($script:SoundPending.ContainsKey($sender)) {
            $script:SoundPending.Remove($sender)
            try {
                $sender.Position = [TimeSpan]::Zero
                $sender.Play()
                if ($script:SoundDebug) { Write-Log ('音效已开始: ' + $sender.Source) }
            } catch {
                Write-Log ('音效启动失败: ' + $_.Exception.Message)
            }
        }
    })
    $player.add_MediaFailed({
        param($sender, $eventArgs)
        Write-Log ('音效播放失败: ' + $eventArgs.ErrorException.Message + ' (' + $sender.Source + ')')
    })
    $player.add_MediaEnded({
        # 排障用：确认音效整段播完（没有中途被打断）
        if ($script:SoundDebug) { Write-Log ('音效播放结束: ' + $sender.Source) }
    })
    $player.Open((New-Object System.Uri $File))
    return $player
}

function Reset-SoundPools {
    # 睡眠/切换音频设备后，WPF 的 MediaPlayer 会变成"哑"实例：进程、音频会话都在，
    # 就是不出声（Position 也不推进）。整池关掉重建即可恢复。
    param([string]$Reason)
    foreach ($key in @($script:SoundPool.Keys)) {
        foreach ($player in @($script:SoundPool[$key])) {
            try { $player.Stop(); $player.Close() } catch { }
        }
    }
    $script:SoundPool = @{}
    $script:SoundPoolCursor = @{}
    $script:SoundReady = @{}
    $script:SoundPending = @{}
    $script:SoundLength = @{}
    $script:SoundStale = $false
    if ($Reason) { Write-Log ('音效播放器已重建: ' + $Reason) }
}

function Get-SoundPool {
    param([string]$Key, [string]$File)
    if ($script:SoundStale) { Reset-SoundPools '系统唤醒或音频设备变化后重建' }
    if (-not $script:SoundPool.ContainsKey($Key)) {
        $players = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $script:SoundPoolSize; $i++) {
            [void]$players.Add((New-SoundPlayer -File $File))
        }
        $script:SoundPool[$Key] = $players
        $script:SoundPoolCursor[$Key] = 0
    }
    return ,$script:SoundPool[$Key]
}

function Warm-SoundPool {
    # 鼠标移到挂件上时先把当前音效集加载好，首次点击也能从头出声
    if (-not $script:Cfg.sound) { return }
    $set = $SoundSets[$script:Cfg.soundSet]
    if (-not $set) { return }
    foreach ($kind in @('press', 'release')) {
        $file = Join-Path $AssetsDir $set[$kind]
        if (Test-Path -LiteralPath $file) {
            [void](Get-SoundPool -Key ($script:Cfg.soundSet + ':' + $kind) -File $file)
        }
    }
}

# ---------------------------------------------------------------- 音频唤醒保持

# 蓝牙耳机/音箱空闲一段时间后会休眠，重新唤醒要 100~500ms 才出声，
# 而挂件音效只有 95~264ms，开头就被设备吞掉，听起来就是"只能听到后半段"。
# 这里循环播放一段数字静音（0.5 秒、8kHz、16bit 单声道，全 0 采样），
# 让音频设备一直保持活动状态；关掉「音效」开关会同时停掉它。
$script:KeepAlivePlayer = $null
$script:KeepAliveStream = $null

function New-SilenceWavStream {
    $rate = 8000
    $dataBytes = [int]($rate * 0.5) * 2
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([char[]]'RIFF'); $bw.Write([int](36 + $dataBytes)); $bw.Write([char[]]'WAVE')
    $bw.Write([char[]]'fmt '); $bw.Write([int]16); $bw.Write([int16]1); $bw.Write([int16]1)
    $bw.Write([int]$rate); $bw.Write([int]($rate * 2)); $bw.Write([int16]2); $bw.Write([int16]16)
    $bw.Write([char[]]'data'); $bw.Write([int]$dataBytes)
    $bw.Write((New-Object byte[] $dataBytes))
    $bw.Flush()
    $ms.Position = 0
    return $ms
}

function Start-SoundKeepAlive {
    if ($script:KeepAlivePlayer) { return }
    if (-not $script:Cfg.sound) { return }
    try {
        $stream = New-SilenceWavStream
        try {
            $player = New-Object System.Media.SoundPlayer($stream)
        } catch {
            Add-Type -AssemblyName System.Windows.Extensions -ErrorAction Stop
            $player = New-Object System.Media.SoundPlayer($stream)
        }
        $player.PlayLooping()
        $script:KeepAlivePlayer = $player
        $script:KeepAliveStream = $stream
        Write-Log '音频唤醒保持：静音循环已启动'
    } catch {
        Write-Log ('音频唤醒保持启动失败: ' + $_.Exception.Message)
    }
}

function Stop-SoundKeepAlive {
    if (-not $script:KeepAlivePlayer) { return }
    try { $script:KeepAlivePlayer.Stop() } catch { }
    $script:KeepAlivePlayer = $null
    if ($script:KeepAliveStream) {
        try { $script:KeepAliveStream.Dispose() } catch { }
        $script:KeepAliveStream = $null
    }
    Write-Log '音频唤醒保持：已停止'
}

# ---------------------------------------------------------------- 通知与角标

# 统一通知入口：写事件文件（events.json，最多 50 条）+ 更新角标 + 弹一次托盘气泡。
# 同一 Key 10 分钟内不重复弹托盘，但事件与角标照记。
$EventsFile = Join-Path $StateDir 'events.json'
$script:NoticeDedup = @{}
$script:NoticeLevels = @{ red = $false; orange = $false; blue = $false }
$script:TrayIcon = $null
$script:TrayMenu = $null

function Get-NoticeLevel {
    if ($script:NoticeLevels['red']) { return 'red' }
    if ($script:NoticeLevels['orange']) { return 'orange' }
    if ($script:NoticeLevels['blue']) { return 'blue' }
    return 'none'
}

function Update-NoticeBadge {
    if (-not $noticeBadge) { return }
    $level = Get-NoticeLevel
    if ($level -eq 'none') {
        $noticeBadge.Visibility = 'Collapsed'
        return
    }
    $noticeBadge.Fill = switch ($level) {
        'red' { '#e0433f' }
        'orange' { '#f0a020' }
        default { '#3f7fe0' }
    }
    $noticeBadge.Visibility = 'Visible'
}

function Clear-NoticeLevel {
    param([string]$Level)
    if (-not $Level) { return }
    $script:NoticeLevels[$Level] = $false
    Update-NoticeBadge
}

function Add-NoticeEvent {
    param([string]$Level, [string]$Key, [string]$Title, [string]$Text)
    try {
        $list = @()
        if (Test-Path -LiteralPath $EventsFile) {
            $parsed = Get-Content -LiteralPath $EventsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($parsed) { $list = @($parsed) }
        }
        $entry = [ordered]@{
            at    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            level = $Level
            key   = $Key
            title = $Title
            text  = $Text
        }
        $list = @($entry) + @($list)
        if ($list.Count -gt 50) { $list = $list[0..49] }
        ($list | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $EventsFile -Encoding UTF8
    } catch {
        Write-Log ('事件记录写入失败: ' + $_.Exception.Message)
    }
}

function Show-Notice {
    param(
        [string]$Level = 'orange',
        [string]$Key = 'general',
        [string]$Title = 'DeepSeek 余额挂件',
        [string]$Text = ''
    )
    Add-NoticeEvent -Level $Level -Key $Key -Title $Title -Text $Text
    $script:NoticeLevels[$Level] = $true
    Update-NoticeBadge
    Write-Log ('通知[{0}/{1}] {2} {3}' -f $Level, $Key, $Title, $Text)
    if (-not $script:Cfg.trayNotify) { return }
    $now = Get-Date
    $last = $script:NoticeDedup[$Key]
    if ($last -and (($now - $last).TotalMinutes -lt 10)) {
        Write-Log ('通知[{0}] 10 分钟内已弹过托盘，跳过气泡' -f $Key)
        return
    }
    $script:NoticeDedup[$Key] = $now
    try {
        if ($script:TrayIcon) {
            $script:TrayIcon.BalloonTipTitle = $Title
            $script:TrayIcon.BalloonTipText = $Text
            $script:TrayIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
            $script:TrayIcon.ShowBalloonTip(6000)
        }
    } catch {
        Write-Log ('托盘通知失败: ' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------- 托盘图标

function Show-FloatingWindow {
    try {
        if (-not $window.IsVisible) { $window.Show() }
        $window.Activate()
    } catch { }
}

function Hide-FloatingWindow {
    try { $window.Hide() } catch { }
}

function Set-TrayOnly {
    param([bool]$Enabled)
    $script:Cfg.trayOnly = $Enabled
    if ($Enabled) { Hide-FloatingWindow } else { Show-FloatingWindow }
    if ($trayOnlyItem) { $trayOnlyItem.IsChecked = $Enabled }
    if ($script:TrayItemTrayOnly) { $script:TrayItemTrayOnly.Checked = $Enabled }
    Save-WidgetState $script:Cfg
    Write-Log ('只留托盘: ' + $Enabled)
}

function Initialize-TrayIcon {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $icon = New-Object System.Windows.Forms.NotifyIcon
        if (Test-Path -LiteralPath $WhalePng) {
            $bitmap = New-Object System.Drawing.Bitmap($WhalePng)
            $handle = $bitmap.GetHicon()
            $icon.Icon = [System.Drawing.Icon]::FromHandle($handle)
            $bitmap.Dispose()
        }
        $icon.Text = 'DeepSeek 余额挂件'
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $script:TrayItemRefresh = $menu.Items.Add('立即刷新')
        $script:TrayItemAutostart = $menu.Items.Add('开机自启')
        $script:TrayItemAutostart.CheckOnClick = $true
        $script:TrayItemAutostart.Checked = Test-Path -LiteralPath $ShortcutPath
        $script:TrayItemTrayOnly = $menu.Items.Add('只留托盘（隐藏悬浮窗）')
        $script:TrayItemTrayOnly.CheckOnClick = $true
        $script:TrayItemTrayOnly.Checked = [bool]$script:Cfg.trayOnly
        $script:TrayItemExit = $menu.Items.Add('退出')

        $script:TrayItemRefresh.Add_Click({
            $script:RefreshIsManual = $true
            Start-BalanceRefresh
        })
        $script:TrayItemAutostart.Add_Click({
            try {
                if ($script:TrayItemAutostart.Checked) { Enable-Autostart } else { $null = Disable-Autostart }
            } catch {
                Write-Log ('自启设置失败: ' + $_.Exception.Message)
            }
            $script:TrayItemAutostart.Checked = Test-Path -LiteralPath $ShortcutPath
            Sync-Menu
        })
        $script:TrayItemTrayOnly.Add_Click({ Set-TrayOnly -Enabled ([bool]$script:TrayItemTrayOnly.Checked) })
        $script:TrayItemExit.Add_Click({ $window.Close() })
        $icon.add_MouseDoubleClick({ Show-FloatingWindow })

        $icon.ContextMenuStrip = $menu
        $icon.Visible = $true
        $script:TrayIcon = $icon
        $script:TrayMenu = $menu
        Write-Log '托盘图标已创建'
    } catch {
        Write-Log ('托盘图标创建失败: ' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------- 状态同步

function Sync-Menu {
    $script:SyncingMenu = $true
    $scaleSlider.Value = $script:Cfg.scale
    $volumeSlider.Value = $script:Cfg.volume
    $soundItem.IsChecked = [bool]$script:Cfg.sound
    $soundDuck.IsChecked = ($script:Cfg.soundSet -eq 'duck')
    $soundFx1.IsChecked = ($script:Cfg.soundSet -eq 'fx1')
    $modeLedger.IsChecked = ($script:Cfg.usageMode -eq 'ledger')
    $modeToken.IsChecked = ($script:Cfg.usageMode -eq 'token')
    $peakDefault.IsChecked = ($script:Cfg.peakMode -eq 'default')
    $peakLiangwen.IsChecked = ($script:Cfg.peakMode -eq 'liangwen')
    $peakQiangqiang.IsChecked = ($script:Cfg.peakMode -eq 'qiangqiang')
    $bubbleItem.IsChecked = [bool]$script:Cfg.bubbleOn
    $trayOnlyItem.IsChecked = [bool]$script:Cfg.trayOnly
    $autostartItem.IsChecked = (Test-Path -LiteralPath $ShortcutPath)
    $script:SyncingMenu = $false
}

# ---------------------------------------------------------------- 声音

function Start-SoundHealthCheck {
    # 播放后检查管线是否真的在走：哑掉的实例 Position 会一直停在 0
    param($Player)
    $script:SoundCheckPlayer = $Player
    if (-not $script:SoundHealthTimer) {
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(400)
        $timer.Add_Tick({
            $script:SoundHealthTimer.Stop()
            $checked = $script:SoundCheckPlayer
            $script:SoundCheckPlayer = $null
            if (-not $checked) { return }
            try {
                if ($checked.Position.TotalMilliseconds -lt 1) {
                    Reset-SoundPools '播放位置未推进（播放器已失效）'
                }
            } catch {
                Reset-SoundPools '播放器状态异常'
            }
        })
        $script:SoundHealthTimer = $timer
    }
    $script:SoundHealthTimer.Stop()
    $script:SoundHealthTimer.Start()
}

function Play-SoundFile {
    # 从播放器池里取一个播放器把整段放出来
    param([string]$Key, [string]$File, [string]$Label)
    $players = Get-SoundPool -Key $Key -File $File
    $index = ([int]$script:SoundPoolCursor[$Key] + $players.Count) % $players.Count
    $script:SoundPoolCursor[$Key] = $index + 1
    $player = $players[$index]
    try {
        $player.Volume = [double]$script:Cfg.volume
        if ($script:SoundReady.ContainsKey($player)) {
            $player.Position = [TimeSpan]::Zero
            $player.Play()
            if ($script:SoundDebug) { Write-Log ('播放音效({0} #{1}): {2}' -f $Label, $index, (Split-Path $File -Leaf)) }
            Start-SoundHealthCheck -Player $player
        } else {
            # 文件还在打开：交给 MediaOpened 回调补播，避免这次的 Play 被丢弃
            $script:SoundPending[$player] = $true
            if ($script:SoundDebug) { Write-Log ('等待音效就绪({0} #{1}): {2}' -f $Label, $index, (Split-Path $File -Leaf)) }
        }
        return $player
    } catch {
        Write-Log ('音效请求异常: ' + $_.Exception.Message)
        return $null
    }
}

function Get-SoundLengthMs {
    param([string]$Key, $Player)
    if ($script:SoundLength.ContainsKey($Key)) { return [double]$script:SoundLength[$Key] }
    try {
        if ($Player -and $Player.NaturalDuration.HasTimeSpan) {
            $ms = $Player.NaturalDuration.TimeSpan.TotalMilliseconds
            if ($ms -gt 0) { $script:SoundLength[$Key] = $ms; return $ms }
        }
    } catch { }
    return 150.0   # 播放器还没就绪时的保守估计
}

function Play-Sound {
    param([string]$Kind)
    if (-not $script:Cfg.sound) {
        if ($script:SoundDebug) { Write-Log ('跳过音效(' + $Kind + '): 音效开关关闭') }
        return
    }
    if ($script:Cfg.volume -le 0) {
        if ($script:SoundDebug) { Write-Log ('跳过音效(' + $Kind + '): 音量为 0') }
        return
    }
    $set = $SoundSets[$script:Cfg.soundSet]
    if (-not $set) {
        Write-Log ('音效集无效: ' + [string]$script:Cfg.soundSet)
        return
    }
    $file = Join-Path $AssetsDir $set[$Kind]
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Log ('音效文件缺失: ' + $file)
        return
    }
    $key = $script:Cfg.soundSet + ':' + $Kind

    if ($Kind -eq 'press') {
        # 新的按下动作作废掉上一次还没响的松开音效
        if ($script:ReleaseTimer) { $script:ReleaseTimer.Stop(); $script:ReleaseTimer = $null }
        $script:PendingRelease = $null
        $player = Play-SoundFile -Key $key -File $file -Label $Kind
        $script:LastPressAt = [DateTime]::Now
        $script:LastPressLengthMs = Get-SoundLengthMs -Key $key -Player $player
        return
    }

    # 松开音效：等按下那一整段放完（留 30ms 衔接）再响。
    # 闪一下的短按里，两段同时播会把前面那段盖掉，听起来就像"只有后半段"。
    $delayMs = 0.0
    if ($script:LastPressAt) {
        $elapsed = ([DateTime]::Now - $script:LastPressAt).TotalMilliseconds
        $delayMs = $script:LastPressLengthMs + 30 - $elapsed
    }
    if ($delayMs -gt 25) {
        if ($script:ReleaseTimer) { $script:ReleaseTimer.Stop() }
        $script:PendingRelease = @{ Key = $key; File = $file; Label = $Kind }
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds([int]$delayMs)
        $timer.Add_Tick({
            $script:ReleaseTimer.Stop()
            $script:ReleaseTimer = $null
            if ($script:PendingRelease) {
                $pending = $script:PendingRelease
                $script:PendingRelease = $null
                [void](Play-SoundFile -Key $pending.Key -File $pending.File -Label $pending.Label)
            }
        })
        $script:ReleaseTimer = $timer
        $timer.Start()
        if ($script:SoundDebug) { Write-Log ('松开音效延后 {0:N0}ms 播放（等按下那声放完）' -f $delayMs) }
        return
    }
    [void](Play-SoundFile -Key $key -File $file -Label $Kind)
}

# ---------------------------------------------------------------- GIF

function Load-GifFrames {
    $script:GifFrames = $null
    if (-not (Test-Path -LiteralPath $RuaGif)) { return }
    try {
        $decoder = [System.Windows.Media.Imaging.GifBitmapDecoder]::Create(
            (New-Object System.Uri $RuaGif),
            [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
            [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $frames = New-Object System.Collections.ArrayList
        foreach ($frame in $decoder.Frames) {
            $seconds = 0.1
            try {
                $query = $frame.Metadata.GetQuery('/grctlext/Delay')
                if ($query) {
                    $value = [int]$query.Value
                    if ($value -gt 0) { $seconds = $value / 100.0 }
                }
            } catch { }
            [void]$frames.Add(@{ Frame = $frame; Seconds = $seconds })
        }
        if ($frames.Count -gt 0) { $script:GifFrames = $frames }
    } catch {
        Write-Log ('gif 解码失败: ' + $_.Exception.Message)
    }
}

function Stop-GifTimer {
    if ($script:GifTimer) {
        $script:GifTimer.Stop()
        $script:GifTimer = $null
    }
    $gifImage.Visibility = 'Collapsed'
}

function Start-GifTimer {
    if (-not $script:GifFrames) { return $false }
    Stop-GifTimer
    $script:GifIndex = 0
    $gifImage.Source = $script:GifFrames[0].Frame
    $gifImage.Visibility = 'Visible'
    $script:GifTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:GifTimer.Interval = [TimeSpan]::FromSeconds([double]$script:GifFrames[0].Seconds)
    $script:GifTimer.Add_Tick({
        $script:GifIndex = ($script:GifIndex + 1) % $script:GifFrames.Count
        $entry = $script:GifFrames[$script:GifIndex]
        $gifImage.Source = $entry.Frame
        $script:GifTimer.Interval = [TimeSpan]::FromSeconds([double]$entry.Seconds)
    })
    $script:GifTimer.Start()
    return $true
}

Load-GifFrames

# ---------------------------------------------------------------- 气泡内容

function Format-Money {
    param($Value, [string]$Currency)
    $number = 0.0
    if ($null -eq $Value -or -not [double]::TryParse(([string]$Value), [ref]$number)) { return '--' }
    $text = $number.ToString('0.00')
    if ($Currency -eq 'CNY') { return ('¥ ' + $text) }
    return ($text + ' ' + $Currency)
}

function Set-LineStyle {
    param($Block, [string]$Style, [string]$Color, [bool]$Wrap)
    switch ($Style) {
        'B' { $Block.FontSize = 128; $Block.FontWeight = 'Bold'; $Block.Foreground = '#536ba9'; $Block.Width = [double]::NaN }
        'P' { $Block.FontSize = 104; $Block.FontWeight = 'Bold'; $Block.Foreground = '#536ba9'; $Block.Width = [double]::NaN }
        'C' { $Block.FontSize = 56; $Block.FontWeight = 'Normal'; $Block.Foreground = '#9fb0d9'; $Block.Width = [double]::NaN }
        default { $Block.FontSize = 66; $Block.FontWeight = 'SemiBold'; $Block.Foreground = '#536ba9'; $Block.Width = [double]::NaN }
    }
    # 行高必须跟着字号走：固定行高（原来的 134）配 66 号字的换行文案会撑高一大截，
    # 三行就顶出气泡被描边盖住。
    $Block.LineHeight = [Math]::Round([double]$Block.FontSize * 1.1)
    if ($Style -eq 'C') { $Block.Margin = '0,9,0,0' } else { $Block.Margin = '0' }
    if ($Wrap) {
        $Block.TextWrapping = 'Wrap'
        $Block.Width = $script:TextBoxWidth
        $Block.TextAlignment = 'Center'
    } else {
        $Block.TextWrapping = 'NoWrap'
    }
    if ($Color) { $Block.Foreground = $Color }
}

function Fit-TextGroup {
    # 文案整体超出气泡内接矩形时等比缩小，避免压到描边或被窗口边缘裁掉
    if (-not $textStack) { return }
    $textStack.LayoutTransform = $null
    $textStack.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
    $size = $textStack.DesiredSize
    if ($size.Width -le 0 -or $size.Height -le 0) { return }
    $scale = [Math]::Min(1.0, [Math]::Min(($script:TextBoxWidth / $size.Width), ($script:TextBoxHeight / $size.Height)))
    if ($scale -lt 0.999) {
        $textStack.LayoutTransform = New-Object System.Windows.Media.ScaleTransform($scale, $scale)
    }
}

function Apply-Lines {
    param($Lines)
    $blocks = @($line1, $line2, $line3)

    if ($Lines -and $Lines.gif) {
        if (Start-GifTimer) {
            foreach ($block in $blocks) { $block.Visibility = 'Collapsed' }
            return
        }
        $fallback = @('gif 加载失败了...', '今天没有动图给你看~', '呜呜 动图不见了...')
        $Lines = @($null, @{ t = (Get-PickOne -Items $fallback); s = 'A'; c = ''; w = $true }, $null)
    }

    Stop-GifTimer
    for ($index = 0; $index -lt 3; $index++) {
        $block = $blocks[$index]
        $line = $null
        if ($Lines -and $Lines.Count -gt $index) { $line = $Lines[$index] }
        if ($line) {
            $block.Visibility = 'Visible'
            $block.Text = [string]$line.t
            Set-LineStyle -Block $block -Style ([string]$line.s) -Color ([string]$line.c) -Wrap ([bool]$line.w)
        } else {
            $block.Visibility = 'Collapsed'
            $block.Text = ''
        }
    }
    Fit-TextGroup
}

function New-SingleCenter {
    param([string]$Style, [string]$Text, [string]$Color, [bool]$Wrap)
    return , @($null, @{ t = $Text; s = $Style; c = $Color; w = $Wrap }, $null)
}

function Get-PickOne {
    param([string[]]$Items)
    return $Items[(Get-Random -Minimum 0 -Maximum $Items.Count)]
}

function Get-PeakTexts {
    $offText = '空闲时段'
    $peakText = '高峰时段'
    switch ($script:Cfg.peakMode) {
        'liangwen' { $offText = '梁文谷'; $peakText = '梁文峰' }
        'qiangqiang' { $offText = '!?谷谷?!'; $peakText = '!?峰峰?!' }
    }
    return @{ off = $offText; peak = $peakText }
}

function New-BalanceLines {
    $texts = Get-PeakTexts
    $peak = [bool]$script:IsPeak
    return @(
        @{ t = '当前时间段为:'; s = 'A'; c = ''; w = $false },
        @{ t = $(if ($peak) { $texts.peak } else { $texts.off }); s = 'P'; c = $(if ($peak) { '#e0433f' } else { '#2fa24c' }); w = $false },
        @{ t = ('今日已用 ' + (Format-Money $script:TodayUsage $script:ShownCurrency)); s = 'C'; c = ''; w = $false }
    )
}

function Get-RandomLines {
    $groups = @(
        @{ w = 45; make = { New-BalanceLines } },
        @{ w = 7;  make = { New-SingleCenter 'B' (Get-PickOne -Items @('好模型... ↓', '好女孩...↓')) '' $false } },
        @{ w = 7;  make = { New-SingleCenter 'A' (Get-PickOne -Items @('不知道用户有什么用，先赶走吧~', '我...我...我也要挣钱吗？', '我去吃饭啦，测完叫我', '压力一只蓝色大肥鱼？！', 'DeepSleep...', '坏了...用户彻底怒了！')) '' $true } },
        @{ w = 10; make = { @{ gif = $true } } },
        @{ w = 3;  make = { New-SingleCenter 'A' (Get-PickOne -Items @('你目录里的dsh是什么...大烧货吗...?', '恭喜你实现token自由！token全跑了！', '真当我是便宜货啊...')) '' $true } },
        @{ w = 1;  make = { New-SingleCenter 'B' '哦鲸鲸... ' '' $false } }
    )
    $total = 0
    foreach ($group in $groups) { $total += $group.w }
    $roll = Get-Random -Minimum 0 -Maximum $total
    foreach ($group in $groups) {
        $roll -= $group.w
        if ($roll -lt 0) { return (& $group.make) }
    }
    return (& $groups[$groups.Count - 1].make)
}

function Set-DefaultLines {
$script:LastHint = $null
$script:SyncingMenu = $false
$script:RefreshIsManual = $false
    $script:RandomActive = $false
    $script:RandomLines = $null
    Apply-Lines -Lines @(
        @{ t = 'DeepSeek 余额'; s = 'A'; c = ''; w = $false },
        @{ t = $(if ($script:ShownBalance -ne $null) { Format-Money $script:ShownBalance $script:ShownCurrency } elseif ($script:Status -eq 'error') { '--' } else { '…' }); s = 'B'; c = ''; w = $false },
        @{ t = (Get-HintText); s = 'C'; c = ''; w = $false }
    )
}

function Get-HintText {
    if ($script:Status -eq 'error') {
        if ($script:Message) {
            $trimmed = [string]$script:Message
            if ($trimmed.Length -gt 14) { $trimmed = $trimmed.Substring(0, 14) }
            return $trimmed
        }
        return '获取失败 · 点击重试'
    }
    if ($script:ShownBalance -eq $null) { return '加载中…' }
    $today = if ($null -ne $script:TodayUsage) { Format-Money $script:TodayUsage $script:ShownCurrency } else { '--' }
    return ('今日已用 ' + $today)
}

# ---------------------------------------------------------------- 气泡开关动画

function New-FadeAnimation {
    param([double]$To, [double]$From, [double]$Seconds, [double]$Delay)
    $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
    $animation.From = $From
    $animation.To = $To
    $animation.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds($Seconds))
    if ($Delay -gt 0) { $animation.BeginTime = [TimeSpan]::FromSeconds($Delay) }
    return $animation
}

function Show-Bubble {
    if (-not $script:Cfg.bubbleOn) { return }
    Set-DefaultLines
    $script:BubbleOpen = $true
    # 气泡出现后，气泡那片区域才纳入命中范围
    $bubbleHit.Visibility = 'Visible'
    $bubbleShape.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-FadeAnimation 1 0 0.18 0.26))
    $bubbleB1.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-FadeAnimation 1 0 0.18 0.13))
    $bubbleB2.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-FadeAnimation 1 0 0.18 0))
    $textGroup.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-FadeAnimation 1 0 0.16 0.36))
    $bubbleScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, (New-FadeAnimation 1 0.94 0.2 0))
    $bubbleScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, (New-FadeAnimation 1 0.94 0.2 0))
    if ($script:BubbleTimer) { $script:BubbleTimer.Stop() }
    $script:BubbleTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:BubbleTimer.Interval = [TimeSpan]::FromSeconds(5)
    $script:BubbleTimer.Add_Tick({
        $script:BubbleTimer.Stop()
        Hide-Bubble
    })
    $script:BubbleTimer.Start()
}

function Hide-Bubble {
    if ($script:BubbleTimer) { $script:BubbleTimer.Stop(); $script:BubbleTimer = $null }
    $script:BubbleOpen = $false
    $bubbleHit.Visibility = 'Collapsed'
    $script:RandomActive = $false
    $script:RandomLines = $null
    $bubbleShape.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-FadeAnimation 0 1 0.14 0.1))
    $bubbleB1.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-FadeAnimation 0 1 0.14 0.2))
    $bubbleB2.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-FadeAnimation 0 1 0.14 0.3))
    $textGroup.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-FadeAnimation 0 1 0.12 0))
    Stop-GifTimer
}

# ---------------------------------------------------------------- 数值渲染

function Update-AmountText {
    param([double]$Value)
    $line2.Text = Format-Money $Value $script:ShownCurrency
}

function Animate-Amount {
    param([double]$To)
    if ($script:RollTimer) { $script:RollTimer.Stop(); $script:RollTimer = $null }
    $from = $script:ShownBalance
    if ($null -eq $from -or [Math]::Abs([double]$from - $To) -lt 0.005) {
        $script:ShownBalance = $To
        Update-AmountText $To
        return
    }
    $script:ShownBalance = $To
    # 定时器回调运行在脚本作用域，函数局部变量那时已不存在，必须放脚本级变量
    $script:RollFrom = [double]$from
    $script:RollTo = $To
    $script:RollStartAt = Get-Date
    $script:RollDurationMs = 700
    $script:RollTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:RollTimer.Interval = [TimeSpan]::FromMilliseconds(16)
    $script:RollTimer.Add_Tick({
        $elapsed = ((Get-Date) - $script:RollStartAt).TotalMilliseconds
        $t = [Math]::Min(1.0, $elapsed / $script:RollDurationMs)
        $eased = 1 - [Math]::Pow(1 - $t, 3)
        Update-AmountText ($script:RollFrom + ($script:RollTo - $script:RollFrom) * $eased)
        if ($t -ge 1) {
            $script:RollTimer.Stop()
            $script:RollTimer = $null
            Update-AmountText $script:RollTo
        }
    })
    $script:RollTimer.Start()
}

function Render-Balance {
    if ($script:RandomActive -and $script:RandomLines) { return }
    if ($script:Status -eq 'error') {
        $line3.Text = Get-HintText
        return
    }
    if ($null -ne $script:TodayUsage) {
        $line3.Text = '今日已用 ' + (Format-Money $script:TodayUsage $script:ShownCurrency)
    }
}

# 诊断用：把窗口内容渲染成 PNG（仅在 DEEPSEEK_WIDGET_SNAPSHOT=1 时启用），
# 用于在 GDI 截屏抓不到分层窗口时核对布局。
function Save-Snapshot {
    try {
        $width = [int][Math]::Round($window.ActualWidth)
        $height = [int][Math]::Round($window.ActualHeight)
        $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($width, $height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($rootGrid)
        $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $path = Join-Path $StateDir 'widget-snapshot.png'
        $stream = [System.IO.File]::Create($path)
        $encoder.Save($stream)
        $stream.Close()
        Write-Log ('snapshot: ' + $path)
    } catch {
        Write-Log ('snapshot 失败: ' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------- 取数

$NodePath = Get-NodePath
$script:RefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:RefreshTimer.Interval = [TimeSpan]::FromSeconds([Math]::Max(10, $Interval))

function Start-BalanceRefresh {
    if ($script:RefreshHandle -ne $null) { return }
    $pipeline = [powershell]::Create()
    [void]$pipeline.AddScript({
        param($NodeExe, $ScriptPath, $Mode)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $NodeExe
        $psi.Arguments = '"{0}" balance --json --mode {1}' -f $ScriptPath, $Mode
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $process = [System.Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEnd()
        $null = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return $stdout
    }).AddArgument($NodePath).AddArgument($BalanceScript).AddArgument([string]$script:Cfg.usageMode)
    $script:RefreshPipeline = $pipeline
    $script:RefreshHandle = $pipeline.BeginInvoke()
}

function Complete-BalanceRefresh {
    if ($script:RefreshHandle -eq $null) { return }
    if (-not $script:RefreshHandle.IsCompleted) { return }
    try {
        $output = $script:RefreshPipeline.EndInvoke($script:RefreshHandle)
        $text = ''
        if ($output -and $output.Count -gt 0) { $text = [string]$output[0] }
        if ($text.Trim()) {
            $payload = $text | ConvertFrom-Json
            if ($payload.ok) {
                $newCurrency = [string]$payload.balance.currency
                $newBalance = [double]$payload.balance.totalBalance
                $previousBalance = $script:ShownBalance
                $changed = ($null -ne $previousBalance) -and
                    ([Math]::Abs($newBalance - [double]$previousBalance) -ge 0.0005) -and
                    ($newCurrency -eq $script:ShownCurrency) -and
                    (-not $script:RefreshIsManual)
                if ($changed) { Show-Bubble }
                $script:Status = 'ok'
                $script:Message = ''
                $script:ShownCurrency = $newCurrency
                $script:TodayUsage = $payload.todayUsage.amount
                $script:IsPeak = [bool]$payload.isPeak
                Animate-Amount $newBalance
                Render-Balance
                foreach ($warning in @($payload.warnings)) {
                    if ($warning) { Write-Log ('警告: ' + $warning) }
                }
            } else {
                $script:Status = 'error'
                $script:Message = [string]$payload.error
                Render-Balance
                Write-Log ('取数失败: ' + $payload.code + ' ' + $payload.error)
            }
        } else {
            $script:Status = 'error'
            $script:Message = 'balance.mjs 无输出'
            Render-Balance
        }
    } catch {
        $script:Status = 'error'
        $script:Message = '取数异常'
        Render-Balance
        Write-Log ('取数异常: ' + $_.Exception.Message)
    } finally {
        try { $script:RefreshPipeline.Dispose() } catch { }
        $script:RefreshPipeline = $null
        $script:RefreshHandle = $null
    }
}

$script:RefreshPump = New-Object System.Windows.Threading.DispatcherTimer
$script:RefreshPump.Interval = [TimeSpan]::FromMilliseconds(200)
$script:RefreshPump.Add_Tick({ Complete-BalanceRefresh })

$script:RefreshTimer.Add_Tick({
    $script:RefreshIsManual = $false
    Start-BalanceRefresh
})

# ---------------------------------------------------------------- 布局与吸附

function Apply-Scale {
    $size = [Math]::Round($script:BaseSize * [double]$script:Cfg.scale)
    $window.Width = $size
    $window.Height = $size
    $bubbleBox.Width = $size
    $bubbleBox.Height = [Math]::Round($size * 700 / 1026)
    $whaleSize = [Math]::Round($size * 0.5945)
    $whaleImage.Width = $whaleSize
    $whaleImage.Height = $whaleSize
    # 命中块与鲸鱼/气泡同尺寸同位置：不弹气泡时窗口里只有鲸鱼那片接收鼠标
    $whaleHit.Width = $whaleSize
    $whaleHit.Height = $whaleSize
    $bubbleHit.Width = [double]$bubbleBox.Width
    $bubbleHit.Height = [double]$bubbleBox.Height
    # 角标落在鲸鱼头部右上角（鲸鱼右下对齐、边长 0.5945*size）
    $badgeSize = [Math]::Round($size * 0.11)
    $noticeBadge.Width = $badgeSize
    $noticeBadge.Height = $badgeSize
    $noticeBadge.StrokeThickness = [Math]::Max(2, [Math]::Round($badgeSize * 0.18))
    $noticeBadge.Margin = New-Object System.Windows.Thickness(0, 0, [Math]::Round($whaleSize * 0.06), [Math]::Round($whaleSize * 0.74))
}

function Set-Mirror {
    $mirrored = ($script:Cfg.snapH -eq 'left')
    $bodyScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
    $bodyScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
    $bodyScale.ScaleX = if ($mirrored) { -1 } else { 1 }
    # 按压会把 ScaleY 直接写成 0.88，这里是"静止状态"的唯一出口：
    # 不复位的话，拖动结束清掉动画后鲸鱼就一直卡在压扁状态。
    $bodyScale.ScaleY = 1
    $textMirror.ScaleX = if ($mirrored) { -1 } else { 1 }
}

function Settle-Window {
    $area = [System.Windows.SystemParameters]::WorkArea
    $size = [double]$window.Width
    $left = $script:Cfg.left
    $top = $script:Cfg.top
    if ($null -eq $left) { $left = $area.Right - $size - 12 }
    if ($null -eq $top) { $top = $area.Bottom - $size - 12 }
    switch ($script:Cfg.snapH) {
        'left' { $left = $area.Left }
        'right' { $left = $area.Right - $size }
    }
    switch ($script:Cfg.snapV) {
        'top' { $top = $area.Top }
        'bottom' { $top = $area.Bottom - $size }
    }
    $left = [Math]::Max($area.Left, [Math]::Min([double]$left, $area.Right - $size))
    $top = [Math]::Max($area.Top, [Math]::Min([double]$top, $area.Bottom - $size))
    $window.Left = $left
    $window.Top = $top
    $script:Cfg.left = $left
    $script:Cfg.top = $top
    Set-Mirror
}

function Update-Snap {
    $area = [System.Windows.SystemParameters]::WorkArea
    $width = [double]$window.Width
    $height = [double]$window.Height
    $centerX = [double]$window.Left + $width / 2
    $centerY = [double]$window.Top + $height / 2
    $third = $area.Width / 4
    $script:Cfg.snapH = $null
    $script:Cfg.snapV = $null
    if ($centerX -lt ($area.Left + $third)) { $script:Cfg.snapH = 'left' }
    elseif ($centerX -gt ($area.Right - $third)) { $script:Cfg.snapH = 'right' }
    if ($centerY -lt ($area.Top + $third)) { $script:Cfg.snapV = 'top' }
    elseif ($centerY -gt ($area.Bottom - $third)) { $script:Cfg.snapV = 'bottom' }
}

# ---------------------------------------------------------------- 交互

function Start-PressAnimation {
    # 按下即压扁。不能只启动一段动画：紧跟其后的 DragMove() 会进入模态循环，
    # 分层窗口在此期间不刷新，动画画不出来，松手后才一次性看到结果（表现为"要长按才触发"）。
    # 所以这里直接写入形变值并强制渲染一帧，保证点一下就能看到压扁，松手再由回弹动画复原。
    $mirror = if ($script:Cfg.snapH -eq 'left') { -1 } else { 1 }
    $bodyScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
    $bodyScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
    $bodyScale.ScaleY = 0.88
    $bodyScale.ScaleX = 1.05 * $mirror
    [void]$window.Dispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Render)
}

function Start-ReleaseAnimation {
    $targetX = if ($script:Cfg.snapH -eq 'left') { -1 } else { 1 }
    $duration = [TimeSpan]::FromSeconds(0.22)
    $ease = New-Object System.Windows.Media.Animation.BackEase
    $ease.EasingMode = 'EaseOut'
    $ease.Amplitude = 0.56
    # 显式写出 From：拖动结束时先执行 Settle-Window/Set-Mirror（会清动画并把形变复位），
    # 只写 To 的话没有起点可弹。
    $animY = New-Object System.Windows.Media.Animation.DoubleAnimation (0.88, 1.0, $duration)
    $animY.EasingFunction = $ease
    $animX = New-Object System.Windows.Media.Animation.DoubleAnimation ((1.05 * $targetX), $targetX, $duration)
    $animX.EasingFunction = $ease
    $bodyScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $animY)
    $bodyScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $animX)
}

# 鼠标移到挂件上才开始音频唤醒保持：蓝牙设备在没有声音时会休眠，
# 只有光标停在挂件上（即将点击）时才需要让它保持活动，平时不占用设备、不额外耗电。
# 同时预热播放器，首次点击时不必等文件打开。
# 睡眠恢复 / 解锁 / 音频设备变化后，WPF 的 MediaPlayer 常常变成"哑"实例：
# 进程和音频会话都在，就是不出声。这里先把播放器池标记为过期，
# 下次用到（鼠标移到挂件上）时会自动重建，用户感知不到。
try {
    [Microsoft.Win32.SystemEvents]::add_PowerModeChanged({
        param($sender, $eventArgs)
        if ([string]$eventArgs.Mode -eq 'Resume') {
            $script:SoundStale = $true
            Write-Log '系统从睡眠恢复：音效播放器将重建'
        }
    })
    [Microsoft.Win32.SystemEvents]::add_SessionSwitch({
        param($sender, $eventArgs)
        if ([string]$eventArgs.Reason -eq 'SessionUnlock') {
            $script:SoundStale = $true
            Write-Log '会话解锁：音效播放器将重建'
        }
    })
} catch {
    Write-Log ('系统事件订阅失败（不影响其它功能）: ' + $_.Exception.Message)
}

$window.Add_MouseEnter({
    Warm-SoundPool
    Start-SoundKeepAlive
})

# 光标离开即停掉静音循环，避免蓝牙设备一直处于活动状态耗电
$window.Add_MouseLeave({
    Stop-SoundKeepAlive
})

$window.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    $point = $eventArgs.GetPosition($window)
    # 气泡位置按命中块实算：吸到左边界时整体镜像，气泡会跑到右侧
    $insideBubble = $false
    if ($script:BubbleOpen) {
        try {
            $bubbleBounds = $bubbleHit.TransformToAncestor($window).TransformBounds(
                (New-Object System.Windows.Rect(0, 0, [double]$bubbleHit.ActualWidth, [double]$bubbleHit.ActualHeight)))
            $insideBubble = $bubbleBounds.Contains($point)
        } catch {
            $insideBubble = $false
        }
    }
    Play-Sound 'press'
    Start-PressAnimation
    $startLeft = [double]$window.Left
    $startTop = [double]$window.Top
    try { $window.DragMove() } catch { }
    $moved = ([Math]::Abs([double]$window.Left - $startLeft) -gt 3) -or ([Math]::Abs([double]$window.Top - $startTop) -gt 3)
    if ($moved) {
        $script:Cfg.left = [double]$window.Left
        $script:Cfg.top = [double]$window.Top
        Update-Snap
        Settle-Window          # 内部会 Set-Mirror（清动画 + 复位形变），所以回弹必须放它后面
        Save-WidgetState $script:Cfg
        Start-ReleaseAnimation
        Play-Sound 'release'
        return
    }
    # 松手立即复原（回弹动画），不额外等待
    Start-ReleaseAnimation
    Play-Sound 'release'
    if ($insideBubble) {
        if ($script:RandomActive) {
            Hide-Bubble
        } else {
            $script:RandomActive = $true
    $script:RandomLines = Get-RandomLines
    Apply-Lines -Lines $script:RandomLines
            if ($script:BubbleTimer) {
                $script:BubbleTimer.Stop()
                $script:BubbleTimer.Start()
            }
        }
        return
    }
    $script:RefreshIsManual = $true
    Start-BalanceRefresh
    if ($script:BubbleOpen) { Set-DefaultLines; $script:RandomActive = $false; $script:RandomLines = $null }
    else { Show-Bubble }
})

$window.Add_MouseRightButtonUp({
    param($sender, $eventArgs)
    Sync-Menu
})

$scaleSlider.Add_ValueChanged({
    param($sender, $eventArgs)
    if ($script:SyncingMenu) { return }
    $value = [Math]::Round([double]$eventArgs.NewValue, 1)
    if ([Math]::Abs($value - [double]$script:Cfg.scale) -lt 0.001) { return }
    $script:Cfg.scale = $value
    Apply-Scale
    Settle-Window
    Save-WidgetState $script:Cfg
})

$volumeSlider.Add_ValueChanged({
    param($sender, $eventArgs)
    if ($script:SyncingMenu) { return }
    $script:Cfg.volume = [Math]::Round([double]$eventArgs.NewValue, 2)
    Save-WidgetState $script:Cfg
})

$soundItem.Add_Click({
    $script:Cfg.sound = [bool]$soundItem.IsChecked
    if ($script:Cfg.sound) {
        if ($window.IsMouseOver) { Start-SoundKeepAlive }
    } else {
        Stop-SoundKeepAlive
    }
    Save-WidgetState $script:Cfg
})

$soundDuck.Add_Click({
    $script:Cfg.soundSet = 'duck'
    $soundDuck.IsChecked = $true
    $soundFx1.IsChecked = $false
    Save-WidgetState $script:Cfg
})

$soundFx1.Add_Click({
    $script:Cfg.soundSet = 'fx1'
    $soundDuck.IsChecked = $false
    $soundFx1.IsChecked = $true
    Save-WidgetState $script:Cfg
})

$soundReload.Add_Click({
    Reset-SoundPools '菜单手动重载'
    Warm-SoundPool
})

$modeLedger.Add_Click({
    $script:Cfg.usageMode = 'ledger'
    $modeLedger.IsChecked = $true
    $modeToken.IsChecked = $false
    Save-WidgetState $script:Cfg
    $script:RefreshIsManual = $true
    Start-BalanceRefresh
})

$modeToken.Add_Click({
    $script:Cfg.usageMode = 'token'
    $modeLedger.IsChecked = $false
    $modeToken.IsChecked = $true
    Save-WidgetState $script:Cfg
    $script:RefreshIsManual = $true
    Start-BalanceRefresh
})

$peakDefault.Add_Click({
    $script:Cfg.peakMode = 'default'
    Sync-Menu
    Save-WidgetState $script:Cfg
})

$peakLiangwen.Add_Click({
    $script:Cfg.peakMode = 'liangwen'
    Sync-Menu
    Save-WidgetState $script:Cfg
})

$peakQiangqiang.Add_Click({
    $script:Cfg.peakMode = 'qiangqiang'
    Sync-Menu
    Save-WidgetState $script:Cfg
})

$bubbleItem.Add_Click({
    $script:Cfg.bubbleOn = [bool]$bubbleItem.IsChecked
    if (-not $script:Cfg.bubbleOn) { Hide-Bubble }
    Save-WidgetState $script:Cfg
})

$trayOnlyItem.Add_Click({
    Set-TrayOnly -Enabled ([bool]$trayOnlyItem.IsChecked)
})

$autostartItem.Add_Click({
    try {
        if ($autostartItem.IsChecked) { Enable-Autostart } else { $null = Disable-Autostart }
    } catch {
        Write-Log ('自启设置失败: ' + $_.Exception.Message)
    }
    $autostartItem.IsChecked = (Test-Path -LiteralPath $ShortcutPath)
})

$refreshItem.Add_Click({
    $script:RefreshIsManual = $true
    Start-BalanceRefresh
})
$exitItem.Add_Click({ $window.Close() })

$window.Add_Closed({
    Stop-SoundKeepAlive
    if ($script:TrayIcon) {
        try { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } catch { }
        $script:TrayIcon = $null
    }
    Save-WidgetState $script:Cfg
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Write-Log 'window closed'
})

# ---------------------------------------------------------------- 运行

Apply-Scale
Settle-Window
Sync-Menu
if (Test-Path -LiteralPath $StateDir) { } else { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
Set-Content -LiteralPath $PidFile -Value $PID -Encoding UTF8
Write-Log ('start pid=' + $PID)

$window.Add_Loaded({
    $area = [System.Windows.SystemParameters]::WorkArea
    Write-Log ('loaded area={0},{1},{2},{3} left={4} top={5} w={6} h={7}' -f `
        $area.Left, $area.Top, $area.Right, $area.Bottom, `
        [double]$window.Left, [double]$window.Top, [double]$window.Width, [double]$window.Height)
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        $handle = $helper.Handle
        [void][DeepSeekWidget.NativeMethods]::ShowWindow($handle, 5)
        $window.Topmost = $true
    } catch {
        Write-Log ('窗口显示修正失败: ' + $_.Exception.Message)
    }
    Write-Log ('after-show left={0} top={1}' -f [double]$window.Left, [double]$window.Top)
    try {
        $shapeBounds = $bubbleShape.TransformToAncestor($window).TransformBounds((New-Object System.Windows.Rect(0, 0, 1026, 700)))
        $whaleBounds = $whaleImage.TransformToAncestor($window).TransformBounds((New-Object System.Windows.Rect(0, 0, $whaleImage.ActualWidth, $whaleImage.ActualHeight)))
        Write-Log ('layout bubble={0:N1},{1:N1} {2:N1}x{3:N1} | whale={4:N1},{5:N1} {6:N1}x{7:N1}' -f `
            $shapeBounds.X, $shapeBounds.Y, $shapeBounds.Width, $shapeBounds.Height, `
            $whaleBounds.X, $whaleBounds.Y, $whaleBounds.Width, $whaleBounds.Height)
        $hitBounds = $whaleHit.TransformToAncestor($window).TransformBounds((New-Object System.Windows.Rect(0, 0, $whaleHit.ActualWidth, $whaleHit.ActualHeight)))
        Write-Log ('hit whale={0:N1},{1:N1} {2:N1}x{3:N1}' -f `
            $hitBounds.X, $hitBounds.Y, $hitBounds.Width, $hitBounds.Height)
    } catch {
        Write-Log ('布局诊断失败: ' + $_.Exception.Message)
    }
    if ($env:DEEPSEEK_WIDGET_SNAPSHOT -eq '1') {
        $snapTimer = New-Object System.Windows.Threading.DispatcherTimer
        $snapTimer.Interval = [TimeSpan]::FromSeconds(4)
        $snapTimer.Add_Tick({
            $script:SnapshotTimer.Stop()
            Save-Snapshot
        })
        $script:SnapshotTimer = $snapTimer
        $snapTimer.Start()
    }
    Start-BalanceRefresh
    $script:RefreshTimer.Start()
    $script:RefreshPump.Start()
    Initialize-TrayIcon
    if ($script:Cfg.trayOnly) {
        Hide-FloatingWindow
        Write-Log '启动时按状态隐藏悬浮窗（只留托盘）'
    }
})

$null = $window.ShowDialog()

foreach ($timer in @($script:RefreshTimer, $script:RefreshPump, $script:BubbleTimer, $script:GifTimer, $script:RollTimer)) {
    if ($timer) { try { $timer.Stop() } catch { } }
}
Write-Log 'exit'
exit 0
