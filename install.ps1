#Requires -Version 5.1
<#
.SYNOPSIS
    把 deepseek-balance 插件安装到本机 Codex。

.DESCRIPTION
    在普通 PowerShell（不要放在 Codex 沙箱会话里）执行。脚本做三件事：
      1. 复制插件源码到 %USERPROFILE%\plugins\deepseek-balance
      2. 在个人插件市场 %USERPROFILE%\.agents\plugins\marketplace.json 写入/更新条目
      3. 运行 codex plugin add deepseek-balance@personal

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    # 只准备文件与市场条目，不执行安装
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -SkipInstall
#>
[CmdletBinding()]
param(
    [string]$ProfileRoot = $env:USERPROFILE,
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'

$pluginName = 'deepseek-balance'
$marketplaceName = 'personal'
$category = 'Developer Tools'

# 去掉用户档案路径结尾的分隔符，避免拼出 C:\Users\x\\.agents 这种双反斜杠
if ($ProfileRoot.Length -gt 3) {
    $ProfileRoot = $ProfileRoot.TrimEnd('\', '/')
}

$source = $PSScriptRoot
$pluginsDir = Join-Path $ProfileRoot 'plugins'
$target = Join-Path $pluginsDir $pluginName
$marketplacePath = Join-Path $ProfileRoot '.agents\plugins\marketplace.json'

function Write-JsonFile {
    param([string]$Path, $Data)

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $json = $Data | ConvertTo-Json -Depth 12
    # 不带 BOM 的 UTF-8：Codex 的 JSON 解析不接受 BOM
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# codex CLI 常常不在 PATH 里（Codex 桌面版自带 CLI，但只写在应用自己的环境变量中），
# 因此按 PATH -> CODEX_CLI_PATH -> 应用安装目录 的顺序定位。
function Resolve-CodexCli {
    $onPath = Get-Command codex -ErrorAction SilentlyContinue
    if ($onPath -and $onPath.Source) {
        return $onPath.Source
    }
    if ($env:CODEX_CLI_PATH -and (Test-Path -LiteralPath $env:CODEX_CLI_PATH)) {
        return $env:CODEX_CLI_PATH
    }
    if ($env:LOCALAPPDATA) {
        $binRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
        $candidates = Get-ChildItem -Path $binRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        foreach ($dir in $candidates) {
            $exe = Join-Path $dir.FullName 'codex.exe'
            if (Test-Path -LiteralPath $exe) {
                return $exe
            }
        }
    }
    return $null
}

Write-Host "[1/3] 复制插件源码到 $target"
if ([System.IO.Path]::GetFullPath($source) -ne [System.IO.Path]::GetFullPath($target)) {
    if (-not (Test-Path -LiteralPath $pluginsDir)) {
        New-Item -ItemType Directory -Force -Path $pluginsDir | Out-Null
    }
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
} else {
    Write-Host '      源目录与目标目录相同，跳过复制'
}

Write-Host "[2/3] 注册个人市场条目：$marketplacePath"
if (Test-Path -LiteralPath $marketplacePath) {
    $market = Get-Content -Raw -LiteralPath $marketplacePath | ConvertFrom-Json
    if ($market.name -ne $marketplaceName) {
        throw "现有市场文件里 name = '$($market.name)'，与预期 '$marketplaceName' 不一致；请先手工确认该文件。"
    }
} else {
    $market = [pscustomobject]@{ name = $marketplaceName }
}

if (-not $market.PSObject.Properties['interface']) {
    $market | Add-Member -NotePropertyName interface -NotePropertyValue ([pscustomobject]@{ displayName = 'Personal' })
}
if (-not $market.PSObject.Properties['plugins']) {
    $market | Add-Member -NotePropertyName plugins -NotePropertyValue @()
}

$entry = [pscustomobject]@{
    name     = $pluginName
    source   = [pscustomobject]@{ source = 'local'; path = "./plugins/$pluginName" }
    policy   = [pscustomobject]@{ installation = 'AVAILABLE'; authentication = 'ON_INSTALL' }
    category = $category
}

$kept = @($market.plugins | Where-Object { $_.name -ne $pluginName })
$market.plugins = @($kept + $entry)
Write-JsonFile -Path $marketplacePath -Data $market

Write-Host "[3/3] 安装到 Codex"
if ($SkipInstall) {
    Write-Host '      已跳过（-SkipInstall）'
} else {
    $codex = Resolve-CodexCli
    if (-not $codex) {
        Write-Warning "PATH 与 %LOCALAPPDATA%\OpenAI\Codex\bin 里都没找到 codex CLI，已跳过安装。"
        Write-Host '插件源码与个人市场条目已就绪，可改用下面任一方式安装：'
        Write-Host '  A) 在 Codex 应用里打开插件页直接安装（见 README「安装」）'
        Write-Host '  B) 用完整路径执行：'
        Write-Host "     & `"$env:LOCALAPPDATA\OpenAI\Codex\bin\<版本目录>\codex.exe`" plugin add $pluginName@$marketplaceName"
        exit 0
    }
    Write-Host "      使用 CLI：$codex"
    & $codex plugin add "$pluginName@$marketplaceName"
    if ($LASTEXITCODE -ne 0) {
        throw "codex plugin add 失败（退出码 $LASTEXITCODE）"
    }
    & $codex plugin list
}

Write-Host ''
Write-Host '完成。请在 Codex 里新开一个线程（技能在新线程才会加载），然后问：查一下 DeepSeek 余额'
