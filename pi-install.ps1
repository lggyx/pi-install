# ============================================================
# pi 管理器 —— Windows PowerShell 交互式菜单（安装 + 多中转站配置，单文件）
# 适用：Windows 10 / Windows 11 / Windows Server (2016/2019/2022/2025)
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File .\pi-install.ps1
#   或一行命令直接执行：
#   irm https://raw.githubusercontent.com/lggyx/pi-install/main/pi-install.ps1 | iex
#
# 菜单能力：
#   1. 安装 / 更新 pi（Node.js + pi 本体，免管理员便携式支持）
#   2. 添加 / 修改 provider：输入名字、baseUrl、模型列表、API Key
#   3. 查看当前配置：默认模型、所有 provider、key 状态
#   4. 切换默认模型
#   5. 重设某个 provider 的 API Key
#   6. 删除 provider
#   7. 修改单个模型（参数 / 追加 / 删除）
#   8. 卸载（pi / Node / 别名 / 配置）
#   0. 退出
# ============================================================

[CmdletBinding()]
param(
    [switch]$NoMenu
)

# ---------- 路径 / 常量 ----------
$NODE_MIN_MAJOR = 22
$PI_DIR = Join-Path $env:USERPROFILE ".pi\agent"
$PI_MODELS_FILE = Join-Path $PI_DIR "models.json"
$PI_SETTINGS_FILE = Join-Path $PI_DIR "settings.json"
$PI_KEYS_FILE = Join-Path $PI_DIR "keys.env"
$PI_KEYS_PS1 = Join-Path $PI_DIR "keys.ps1"
$PI_BIN_DIR = Join-Path $PI_DIR "bin"
$PROFILE_PATH = $PROFILE
$PROFILE_BLOCK_BEGIN = "# >>> pi-agent (managed by pi-install.ps1) >>>"
$PROFILE_BLOCK_END   = "# <<< pi-agent (managed by pi-install.ps1) <<<"
$UTF8_NO_BOM = New-Object System.Text.UTF8Encoding $false

# 保证目录存在
if (-not (Test-Path $PI_DIR)) { New-Item -ItemType Directory -Force -Path $PI_DIR | Out-Null }
if (-not (Test-Path $PI_BIN_DIR)) { New-Item -ItemType Directory -Force -Path $PI_BIN_DIR | Out-Null }

# ---------- 日志输出 ----------
function Write-Info($msg) { Write-Host "[INFO]  $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Fail($msg) { Write-Host "[FAIL]  $msg" -ForegroundColor Red }

# ---------- 输入辅助（支持交互式控制台与管道重定向） ----------
function Read-Input($prompt = "") {
    if ([Console]::IsInputRedirected) {
        $line = [Console]::In.ReadLine()
        if ($null -eq $line) { return "" }
        return $line
    }
    return (Read-Host $prompt)
}

function Read-SecretInput($prompt = "") {
    if ([Console]::IsInputRedirected) {
        $line = [Console]::In.ReadLine()
        if ($null -eq $line) { return "" }
        return $line
    }
    $sec = Read-Host -Prompt $prompt -AsSecureString
    if (-not $sec) { return "" }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $val = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    return $val
}

# ---------- 旧版遗留损坏文件的自愈 ----------
function Repair-LegacyFiles {
    if (-not (Test-Path $PI_DIR)) { return }
    $checkFiles = @("trust.json", "settings.json", "models.json")
    foreach ($fn in $checkFiles) {
        $fp = Join-Path $PI_DIR $fn
        if (Test-Path $fp) {
            $raw = [System.IO.File]::ReadAllText($fp, [System.Text.Encoding]::UTF8)
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            try {
                $null = ConvertFrom-Json $raw -ErrorAction Stop
            } catch {
                $bak = "$fp.broken.bak"
                Move-Item -Path $fp -Destination $bak -Force
                Write-Warn "检测到损坏的 $fn（非法 JSON），已备份为 $fn.broken.bak"
            }
        }
    }
}
Repair-LegacyFiles

# ---------- JSON 读写辅助函数 ----------
function Read-ModelsJson {
    if (Test-Path $PI_MODELS_FILE) {
        try {
            $raw = [System.IO.File]::ReadAllText($PI_MODELS_FILE, [System.Text.Encoding]::UTF8)
            $obj = ConvertFrom-Json $raw -ErrorAction Stop
            if ($null -eq $obj) { $obj = [PSCustomObject]@{} }
            if ($null -eq $obj.PSObject.Properties['$schema']) {
                $obj | Add-Member -NotePropertyName '$schema' -NotePropertyValue "https://pi.dev/schemas/models.schema.json" -Force
            }
            if ($null -eq $obj.PSObject.Properties['providers']) {
                $obj | Add-Member -NotePropertyName 'providers' -NotePropertyValue ([PSCustomObject]@{}) -Force
            }
            return $obj
        } catch {
            Write-Warn "读取 models.json 失败: $($_.Exception.Message)"
        }
    }
    return [PSCustomObject]@{
        '$schema' = "https://pi.dev/schemas/models.schema.json"
        providers = [PSCustomObject]@{}
    }
}

function Write-ModelsJson($obj) {
    if (-not (Test-Path $PI_DIR)) { New-Item -ItemType Directory -Force -Path $PI_DIR | Out-Null }
    $json = ConvertTo-Json $obj -Depth 20
    [System.IO.File]::WriteAllText($PI_MODELS_FILE, ($json + [Environment]::NewLine), $UTF8_NO_BOM)
}

function Read-SettingsJson {
    if (Test-Path $PI_SETTINGS_FILE) {
        try {
            $raw = [System.IO.File]::ReadAllText($PI_SETTINGS_FILE, [System.Text.Encoding]::UTF8)
            $obj = ConvertFrom-Json $raw -ErrorAction Stop
            if ($null -eq $obj) { $obj = [PSCustomObject]@{} }
            return $obj
        } catch {
            Write-Warn "读取 settings.json 失败: $($_.Exception.Message)"
        }
    }
    return [PSCustomObject]@{}
}

function Write-SettingsJson($obj) {
    if (-not (Test-Path $PI_DIR)) { New-Item -ItemType Directory -Force -Path $PI_DIR | Out-Null }
    if ($null -eq $obj.PSObject.Properties['$schema']) {
        $obj | Add-Member -NotePropertyName '$schema' -NotePropertyValue "https://pi.dev/schemas/settings.schema.json" -Force
    }
    $json = ConvertTo-Json $obj -Depth 20
    [System.IO.File]::WriteAllText($PI_SETTINGS_FILE, ($json + [Environment]::NewLine), $UTF8_NO_BOM)
}

# ---------- API Key 存储与管理 ----------
function Set-KeyStore($envName, $val) {
    # 1. 写入用户环境变量（永久有效，所有新终端自动继承）
    [Environment]::SetEnvironmentVariable($envName, $val, [System.EnvironmentVariableTarget]::User)
    # 2. 写入当前进程环境变量（当前会话立即可用）
    [Environment]::SetEnvironmentVariable($envName, $val, [System.EnvironmentVariableTarget]::Process)
    Set-Item -Path "env:$envName" -Value $val -Force

    # 3. 写入 keys.ps1（PowerShell 脚本导入格式）
    $existingPs1 = @()
    if (Test-Path $PI_KEYS_PS1) {
        $existingPs1 = Get-Content -Path $PI_KEYS_PS1 -Encoding UTF8 | Where-Object { $_ -notmatch "^\`$env:$envName\s*=" }
    }
    $newPs1 = @($existingPs1) + @("`$env:$envName = `"$val`"")
    [System.IO.File]::WriteAllLines($PI_KEYS_PS1, $newPs1, $UTF8_NO_BOM)

    # 4. 写入 keys.env（bash/cmd 导出格式）
    $existingEnv = @()
    if (Test-Path $PI_KEYS_FILE) {
        $existingEnv = Get-Content -Path $PI_KEYS_FILE -Encoding UTF8 | Where-Object { $_ -notmatch "^export\s+$envName=" }
    }
    $newEnv = @($existingEnv) + @("export $envName=`"$val`"")
    [System.IO.File]::WriteAllLines($PI_KEYS_FILE, $newEnv, $UTF8_NO_BOM)
}

function Remove-KeyStore($envName) {
    [Environment]::SetEnvironmentVariable($envName, $null, [System.EnvironmentVariableTarget]::User)
    [Environment]::SetEnvironmentVariable($envName, $null, [System.EnvironmentVariableTarget]::Process)
    Remove-Item -Path "env:$envName" -Force -ErrorAction SilentlyContinue

    if (Test-Path $PI_KEYS_PS1) {
        $lines = Get-Content -Path $PI_KEYS_PS1 -Encoding UTF8 | Where-Object { $_ -notmatch "^\`$env:$envName\s*=" }
        [System.IO.File]::WriteAllLines($PI_KEYS_PS1, @($lines), $UTF8_NO_BOM)
    }
    if (Test-Path $PI_KEYS_FILE) {
        $lines = Get-Content -Path $PI_KEYS_FILE -Encoding UTF8 | Where-Object { $_ -notmatch "^export\s+$envName=" }
        [System.IO.File]::WriteAllLines($PI_KEYS_FILE, @($lines), $UTF8_NO_BOM)
    }
}

# ---------- 别名与快捷命令托管块 ----------
function Update-ProfileBlock {
    # 1. 在 $PI_BIN_DIR 下生成 CMD / 终端通用的快捷调用脚本 pi-<provider>.cmd
    if (-not (Test-Path $PI_BIN_DIR)) { New-Item -ItemType Directory -Force -Path $PI_BIN_DIR | Out-Null }
    Get-ChildItem -Path $PI_BIN_DIR -Filter "pi-*.cmd" -ErrorAction SilentlyContinue | Remove-Item -Force

    $models = Read-ModelsJson
    $profileLines = @()
    $profileLines += $PROFILE_BLOCK_BEGIN
    $profileLines += "if (Test-Path `"`$env:USERPROFILE\.pi\agent\keys.ps1`") { . `"`$env:USERPROFILE\.pi\agent\keys.ps1`" }"

    if ($models.providers) {
        foreach ($prop in $models.providers.PSObject.Properties) {
            $pk = $prop.Name
            $p = $prop.Value
            $mList = @($p.models)
            if ($mList.Count -gt 0) {
                $firstModel = $mList[0].id
                # PowerShell profile 函数
                $profileLines += "function global:pi-$pk { pi --provider $pk --model $firstModel @args }"
                # 当前 PowerShell 会话立即可用
                Set-Item -Path "Function:global:pi-$pk" -Value ([ScriptBlock]::Create("pi --provider $pk --model $firstModel @args")) -Force

                # CMD shim: pi-<pk>.cmd（供 cmd.exe、Git Bash 或 Win+R 直接运行）
                $cmdFile = Join-Path $PI_BIN_DIR "pi-$pk.cmd"
                $cmdContent = "@echo off`r`npi --provider $pk --model $firstModel %*`r`n"
                [System.IO.File]::WriteAllText($cmdFile, $cmdContent, [System.Text.Encoding]::ASCII)
            }
        }
    }
    $profileLines += $PROFILE_BLOCK_END

    # 2. 写入 PowerShell $PROFILE
    try {
        $profileDir = Split-Path -Path $PROFILE_PATH -Parent
        if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }
        $existingProfile = @()
        if (Test-Path $PROFILE_PATH) {
            $rawProfile = Get-Content -Path $PROFILE_PATH -Encoding UTF8
            $inBlock = $false
            foreach ($line in $rawProfile) {
                if ($line -eq $PROFILE_BLOCK_BEGIN) { $inBlock = $true; continue }
                if ($line -eq $PROFILE_BLOCK_END) { $inBlock = $false; continue }
                if (-not $inBlock) { $existingProfile += $line }
            }
        }
        $finalProfile = @($existingProfile) + @($profileLines)
        [System.IO.File]::WriteAllLines($PROFILE_PATH, $finalProfile, $UTF8_NO_BOM)
    } catch {
        # 若环境受组策略限制无法修改 Profile，不阻断运行
    }
}

# ---------- Node 状态与安装 ----------
function Get-NodeMajorVersion {
    try {
        $v = & node -v 2>$null
        if ($v -match '^v?(\d+)') {
            return [int]$matches[1]
        }
    } catch {}
    return 0
}

function Ensure-NodeInstalled {
    $cur = Get-NodeMajorVersion
    if ($cur -ge $NODE_MIN_MAJOR) {
        Write-Info "Node.js 已就绪：$(& node -v) ($((Get-Command node).Source))"
        return $true
    }

    Write-Warn "未检测到满足要求的 Node.js（当前: $(if ($cur -gt 0) { "v$cur" } else { "未安装" })，要求 >= v${NODE_MIN_MAJOR}.x）"
    Write-Host "请选择 Node.js 获取方式："
    Write-Host "  1) 自动下载配置便携版 Node.js LTS（推荐，免管理员权限，解压即用）"
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "  2) 使用 winget 安装 Node.js LTS"
    }
    Write-Host "  0) 稍后手动安装并退出"
    
    $choice = Read-Input "选择 [1]"
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }

    if ($choice -eq "2" -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Info "正在通过 winget 安装 Node.js LTS..."
        & winget install OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements
        # 刷新环境变量
        $userPath = [Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::User)
        $sysPath  = [Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::Machine)
        $env:PATH = "$userPath;$sysPath"
    } elseif ($choice -eq "1") {
        Write-Info "正在查询 Node.js 官方最新 LTS 版本号..."
        $ltsVer = "v22.14.0"
        try {
            $indexJson = Invoke-RestMethod -Uri "https://nodejs.org/dist/index.json" -UseBasicParsing -TimeoutSec 10
            $matched = $indexJson | Where-Object { $_.lts -ne $false } | Select-Object -First 1
            if ($matched -and $matched.version) {
                $ltsVer = $matched.version
            }
        } catch {
            Write-Warn "查询 index.json 超时，使用兜底稳定版本 $ltsVer"
        }

        $zipUrl = "https://nodejs.org/dist/$ltsVer/node-$ltsVer-win-x64.zip"
        $destDir = Join-Path $env:LOCALAPPDATA "Programs\nodejs"
        $tempZip = Join-Path $env:TEMP "node-$ltsVer-win-x64.zip"
        $tempExtract = Join-Path $env:TEMP "node_extract_$([System.IO.Path]::GetRandomFileName())"

        Write-Info "正在下载便携版 Node.js $ltsVer..."
        Write-Info "下载地址: $zipUrl"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing
        } catch {
            Write-Fail "下载 Node.js 失败: $($_.Exception.Message)"
            Write-Host "建议手动前往 https://nodejs.org/ 下载安装包后重试。"
            return $false
        }

        Write-Info "正在解压 Node.js..."
        try {
            Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force
            $innerDir = Join-Path $tempExtract "node-$ltsVer-win-x64"
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
            Copy-Item -Path "$innerDir\*" -Destination $destDir -Recurse -Force
            Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Fail "解压配置 Node.js 失败: $($_.Exception.Message)"
            return $false
        }

        # 添加至用户 PATH
        $userPath = [Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::User)
        if ($userPath -notlike "*$destDir*") {
            [Environment]::SetEnvironmentVariable("PATH", "$destDir;$userPath", [System.EnvironmentVariableTarget]::User)
        }
        $env:PATH = "$destDir;$env:PATH"
        Write-Info "便携版 Node.js 已配置就绪：$destDir"
    } else {
        Write-Warn "请先安装 Node.js >= 22 并配置 PATH，然后重跑本脚本。"
        return $false
    }

    $cur = Get-NodeMajorVersion
    if ($cur -ge $NODE_MIN_MAJOR) {
        Write-Info "Node.js 校验通过：$(& node -v)"
        return $true
    }
    Write-Fail "Node.js 版本仍不满足要求，请新开 PowerShell 窗口确认 node -v"
    return $false
}

# ============================================================
# 菜单 1：安装 / 更新 pi
# ============================================================
function Install-Pi {
    if (-not (Ensure-NodeInstalled)) { return }

    # 检查当前 pi 版本
    $installedVer = ""
    try {
        $verOut = & pi --version 2>$null
        if ($verOut -match '(\d+\.\d+\.\d+)') {
            $installedVer = $matches[1]
        }
    } catch {}

    # 查询 npm 远端最新版本
    $targetVer = "latest"
    try {
        $viewOut = & npm view @earendil-works/pi-coding-agent version 2>$null
        if ($viewOut -match '^\d+\.\d+\.\d+') {
            $targetVer = $viewOut.Trim()
        }
    } catch {}

    if ($installedVer -ne "" -and $installedVer -eq $targetVer) {
        Write-Info "pi 已是最新版本 v$installedVer，跳过安装"
    } else {
        if ($installedVer -ne "") {
            Write-Info "检测到旧版 pi v$installedVer，正在更新到 v$targetVer ..."
        } else {
            Write-Info "正在通过 npm 全局安装 pi v$targetVer ..."
        }
        & npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@$targetVer"
    }

    # 检查并配置 npm 全局 bin 路径与 pi 快捷目录
    try {
        $npmPrefix = (& npm prefix -g 2>$null).Trim()
        if ($npmPrefix -and (Test-Path $npmPrefix)) {
            $userPath = [Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::User)
            if ($userPath -notlike "*$npmPrefix*") {
                [Environment]::SetEnvironmentVariable("PATH", "$npmPrefix;$userPath", [System.EnvironmentVariableTarget]::User)
                Write-Info "已将 npm 全局目录添加至用户 PATH: $npmPrefix"
            }
            $env:PATH = "$npmPrefix;$env:PATH"
        }
    } catch {}

    $userPath = [Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::User)
    if ($userPath -notlike "*$PI_BIN_DIR*") {
        [Environment]::SetEnvironmentVariable("PATH", "$PI_BIN_DIR;$userPath", [System.EnvironmentVariableTarget]::User)
    }
    $env:PATH = "$PI_BIN_DIR;$env:PATH"

    # 执行策略优化（防止 Windows 阻拦执行 npm 生成的 .ps1 脚本）
    try {
        $currPolicy = Get-ExecutionPolicy -Scope CurrentUser
        if ($currPolicy -eq "Restricted" -or $currPolicy -eq "Undefined") {
            $procPolicy = Get-ExecutionPolicy -Scope Process
            if ($procPolicy -ne "Bypass" -and $procPolicy -ne "Unrestricted") {
                Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction SilentlyContinue
                Write-Info "已将当前用户 PowerShell 执行策略设为 RemoteSigned（允许执行本地安装脚本）"
            }
        }
    } catch {}

    # 补写 settings（压制初次启动更新弹窗）
    $settings = Read-SettingsJson
    $finalVer = if ($installedVer) { $installedVer } else { $targetVer }
    $settings | Add-Member -NotePropertyName "lastChangelogVersion" -NotePropertyValue $finalVer -Force
    Write-SettingsJson $settings
    Update-ProfileBlock

    # 自检
    try {
        $check = & pi --version 2>$null
        Write-Info "自检通过：pi 命令可用（v$check）"
    } catch {
        Write-Warn "当前窗口尚未刷新 PATH，若直接输入 pi 找不到，请新开一个 PowerShell 窗口。"
    }

    Write-Host ""
    Write-Info "完成！输入 pi 即可开用。"

    $go = Read-Input "现在添加一个模型 provider（中转站）? [Y/n]"
    if ($go -notmatch '^[nN]') {
        Add-Provider
    }
}

# ============================================================
# 菜单 2：添加 / 修改 provider
# ============================================================
function Add-Provider {
    $models = Read-ModelsJson

    # 1. provider 标识
    $pk = ""
    while ($true) {
        $pk = (Read-Input "provider 名（小写字母/数字/下划线，如 stepfun、myrelay）").Trim()
        if ($pk -match '^[a-z][a-z0-9_]*$') { break }
        Write-Warn "名字不合法，只能用小写字母/数字/下划线，且以字母开头"
    }

    if ($models.providers.PSObject.Properties[$pk]) {
        $ow = Read-Input "provider '$pk' 已存在，覆盖修改? [y/N]"
        if ($ow -notmatch '^[yY]') { return }
    }

    # 2. baseUrl
    $baseUrl = ""
    while ($true) {
        $baseUrl = (Read-Input "baseUrl（如 https://api.stepfun.com/step_plan/v1）").Trim()
        if (-not [string]::IsNullOrEmpty($baseUrl)) { break }
        Write-Warn "baseUrl 不能为空"
    }

    # 3. API 类型
    Write-Host "API 类型："
    Write-Host "  1) openai-completions   （绝大多数中转站/OpenAI 兼容端点，默认）"
    Write-Host "  2) openai-responses"
    Write-Host "  3) anthropic-messages   （Claude 系中转）"
    Write-Host "  4) google-generative-ai （Gemini 系中转）"
    $apiChoice = Read-Input "选择 [1]"
    $apiType = switch ($apiChoice.Trim()) {
        "2" { "openai-responses" }
        "3" { "anthropic-messages" }
        "4" { "google-generative-ai" }
        default { "openai-completions" }
    }

    # 4. 模型列表
    Write-Info "输入模型 ID（发给 API 的名字，如 step-3.7-flash、gpt-4o），每行一个，直接回车结束"
    Write-Info "每个模型可设置上下文窗口 / 最大输出 token，直接回车用默认（128000 / 16384）"
    $modelsList = @()
    while ($true) {
        $mid = (Read-Input "模型ID").Trim()
        if ([string]::IsNullOrEmpty($mid)) { break }
        
        $mctx = (Read-Input "  $mid 上下文窗口 token（输入+输出总量）[128000]").Trim()
        $mmax = (Read-Input "  $mid 最大输出 token [16384]").Trim()

        $mObj = [PSCustomObject]@{ id = $mid }
        if ($mctx -match '^\d+$' -and [int]$mctx -gt 0) {
            $mObj | Add-Member -NotePropertyName "contextWindow" -NotePropertyValue ([int]$mctx) -Force
        }
        if ($mmax -match '^\d+$' -and [int]$mmax -gt 0) {
            $mObj | Add-Member -NotePropertyName "maxTokens" -NotePropertyValue ([int]$mmax) -Force
        }
        $modelsList += $mObj
    }

    if ($modelsList.Count -eq 0) {
        Write-Warn "至少要有一个模型，已取消添加"
        return
    }

    # 5. API Key（密文输入）
    $envName = "$($pk.ToUpper())_API_KEY"
    Write-Host ""
    $keyVal = Read-SecretInput "API Key（存为用户环境变量，models.json 记 `$$envName 引用；无鉴权端点直接回车）"

    $apiKeyArg = $null
    if (-not [string]::IsNullOrEmpty($keyVal)) {
        Set-KeyStore $envName $keyVal
        $apiKeyArg = "`$$envName"
        Write-Info "Key 已持久化存入 Windows 用户环境变量 $envName 与 $PI_KEYS_FILE"
    }

    # 6. 组装并写入 models.json
    $entry = [PSCustomObject]@{
        baseUrl = $baseUrl
        api     = $apiType
        models  = @($modelsList)
    }
    if ($apiKeyArg) {
        $entry | Add-Member -NotePropertyName "apiKey" -NotePropertyValue $apiKeyArg -Force
    }
    $models.providers | Add-Member -NotePropertyName $pk -NotePropertyValue $entry -Force
    Write-ModelsJson $models

    # 若尚未设置默认 provider，则自动设为默认
    $settings = Read-SettingsJson
    if ([string]::IsNullOrEmpty($settings.defaultProvider)) {
        $settings | Add-Member -NotePropertyName "defaultProvider" -NotePropertyValue $pk -Force
        $settings | Add-Member -NotePropertyName "defaultModel" -NotePropertyValue $modelsList[0].id -Force
        Write-SettingsJson $settings
        Write-Info "已设为默认模型：$pk / $($modelsList[0].id)"
    }

    Update-ProfileBlock
    Write-Info "provider '$pk' 已保存！快捷命令：pi-$pk"
}

# ============================================================
# 菜单 3：查看当前配置
# ============================================================
function Show-Config {
    $models = Read-ModelsJson
    $settings = Read-SettingsJson

    Write-Host ""
    Write-Host "================ pi 当前配置 ================" -ForegroundColor Cyan
    $piVer = "未安装"
    try {
        $v = & pi --version 2>$null
        if ($v) { $piVer = $v }
    } catch {}
    $nodeVer = "未安装"
    try {
        $nv = & node -v 2>$null
        if ($nv) { $nodeVer = $nv }
    } catch {}
    Write-Host " pi 版本  : $piVer    node: $nodeVer"

    $defP = if ($settings.defaultProvider) { $settings.defaultProvider } else { "-" }
    $defM = if ($settings.defaultModel) { $settings.defaultModel } else { "-" }
    if ($defP -eq "-") {
        Write-Host " 默认模型 : （未设置，pi 启动时需手动 /model 选择）"
    } else {
        Write-Host " 默认模型 : $defP / $defM"
    }
    Write-Host ""

    $hasProviders = $false
    if ($models.providers) {
        $props = $models.providers.PSObject.Properties
        if ($props.Count -gt 0) { $hasProviders = $true }
    }

    if (-not $hasProviders) {
        Write-Warn "还没有配置任何 provider，请使用菜单 2 添加"
        return
    }

    Write-Host (" {0,-14} {1,-36} {2,-16} {3}" -f "PROVIDER", "BASEURL", "KEY", "MODELS[上下文/最大输出]")
    Write-Host (" " + ("-" * 85))

    foreach ($prop in $models.providers.PSObject.Properties) {
        $pk = $prop.Name
        $p = $prop.Value
        $keyDisp = "无"
        if ($p.apiKey) {
            if ($p.apiKey -like "`$*") { $keyDisp = $p.apiKey } else { $keyDisp = "字面量" }
        }
        $mDisps = @($p.models) | ForEach-Object {
            $m = $_
            $s = $m.id
            if ($m.contextWindow -or $m.maxTokens) {
                $ctx = if ($m.contextWindow) { $m.contextWindow } else { "" }
                $max = if ($m.maxTokens) { "/$($m.maxTokens)" } else { "" }
                $s += "[$ctx$max]"
            }
            $s
        }
        $mStr = $mDisps -join ", "
        Write-Host (" {0,-14} {1,-36} {2,-16} {3}" -f $pk, $p.baseUrl, $keyDisp, $mStr)
    }
    Write-Host ""
    Write-Host " 配置文件：$PI_MODELS_FILE / $PI_SETTINGS_FILE / $PI_KEYS_FILE"
}

# ============================================================
# 菜单 4：切换默认模型
# ============================================================
function Choose-Default {
    $models = Read-ModelsJson
    if (-not $models.providers) {
        Write-Warn "未配置任何 provider，请先使用菜单 2 添加"
        return
    }

    $allModels = @()
    foreach ($prop in $models.providers.PSObject.Properties) {
        $pk = $prop.Name
        foreach ($m in @($prop.Value.models)) {
            $allModels += [PSCustomObject]@{ Provider = $pk; Model = $m.id }
        }
    }

    if ($allModels.Count -eq 0) {
        Write-Warn "没有配置任何模型，请先用菜单 2 添加 provider"
        return
    }

    Write-Host ""
    Write-Info "选择默认模型："
    for ($i = 0; $i -lt $allModels.Count; $i++) {
        Write-Host "  $($i + 1)) $($allModels[$i].Provider) / $($allModels[$i].Model)"
    }

    $sel = Read-Input "输入序号 [1]"
    $idx = 0
    if ($sel -match '^\d+$') {
        $idx = [int]$sel - 1
    }
    if ($idx -lt 0 -or $idx -ge $allModels.Count) { $idx = 0 }

    $chosen = $allModels[$idx]
    $settings = Read-SettingsJson
    $settings | Add-Member -NotePropertyName "defaultProvider" -NotePropertyValue $chosen.Provider -Force
    $settings | Add-Member -NotePropertyName "defaultModel" -NotePropertyValue $chosen.Model -Force
    Write-SettingsJson $settings

    Write-Info "默认模型已设为：$($chosen.Provider) / $($chosen.Model)"
}

# ============================================================
# 菜单 5：重设 API Key
# ============================================================
function Reset-Key {
    $models = Read-ModelsJson
    if (-not $models.providers -or $models.providers.PSObject.Properties.Count -eq 0) {
        Write-Warn "没有 provider，请先用菜单 2 添加"
        return
    }

    $pks = @($models.providers.PSObject.Properties | ForEach-Object { $_.Name })
    Write-Host ""
    Write-Info "给哪个 provider 重设 Key："
    for ($i = 0; $i -lt $pks.Count; $i++) {
        Write-Host "  $($i + 1)) $($pks[$i])"
    }

    $sel = Read-Input "序号 [1]"
    $idx = 0
    if ($sel -match '^\d+$') { $idx = [int]$sel - 1 }
    if ($idx -lt 0 -or $idx -ge $pks.Count) { $idx = 0 }
    $pk = $pks[$idx]

    $envName = "$($pk.ToUpper())_API_KEY"
    Write-Host ""
    $keyVal = Read-SecretInput "$pk 的新 API Key"
    if ([string]::IsNullOrEmpty($keyVal)) {
        Write-Warn "输入为空，未做修改"
        return
    }

    Set-KeyStore $envName $keyVal
    $models.providers.$pk | Add-Member -NotePropertyName "apiKey" -NotePropertyValue "`$$envName" -Force
    Write-ModelsJson $models
    Write-Info "已更新 $envName 并写入 models.json"
}

# ============================================================
# 菜单 6：删除 provider
# ============================================================
function Delete-Provider {
    $models = Read-ModelsJson
    if (-not $models.providers -or $models.providers.PSObject.Properties.Count -eq 0) {
        Write-Warn "没有 provider 可删"
        return
    }

    $pks = @($models.providers.PSObject.Properties | ForEach-Object { $_.Name })
    Write-Host ""
    Write-Info "删除哪个 provider："
    for ($i = 0; $i -lt $pks.Count; $i++) {
        Write-Host "  $($i + 1)) $($pks[$i])"
    }

    $sel = Read-Input "序号 [1]"
    $idx = 0
    if ($sel -match '^\d+$') { $idx = [int]$sel - 1 }
    if ($idx -lt 0 -or $idx -ge $pks.Count) { $idx = 0 }
    $pk = $pks[$idx]

    $confirm = Read-Input "确认删除 '$pk'（含它的模型定义）? [y/N]"
    if ($confirm -notmatch '^[yY]') { return }

    $models.providers.PSObject.Properties.Remove($pk)
    Write-ModelsJson $models

    $settings = Read-SettingsJson
    if ($settings.defaultProvider -eq $pk) {
        $settings.PSObject.Properties.Remove("defaultProvider")
        $settings.PSObject.Properties.Remove("defaultModel")
        Write-SettingsJson $settings
        Write-Warn "该 provider 原为默认模型，默认设置已被清除"
    }

    Remove-KeyStore "$($pk.ToUpper())_API_KEY"
    Update-ProfileBlock
    Write-Info "已删除 provider '$pk'"
}

# ============================================================
# 菜单 7：修改单个模型（参数 / 追加 / 删除）
# ============================================================
function Edit-Model {
    $models = Read-ModelsJson
    if (-not $models.providers -or $models.providers.PSObject.Properties.Count -eq 0) {
        Write-Warn "没有配置任何模型，请先用菜单 2 添加 provider"
        return
    }

    $pks = @($models.providers.PSObject.Properties | ForEach-Object { $_.Name })
    Write-Host ""
    Write-Info "选择 provider："
    for ($i = 0; $i -lt $pks.Count; $i++) {
        Write-Host "  $($i + 1)) $($pks[$i])"
    }
    $sel = Read-Input "序号 [1]"
    $idx = 0
    if ($sel -match '^\d+$') { $idx = [int]$sel - 1 }
    if ($idx -lt 0 -or $idx -ge $pks.Count) { $idx = 0 }
    $pk = $pks[$idx]
    $p = $models.providers.$pk

    $mList = [System.Collections.ArrayList]@(@($p.models))
    Write-Host ""
    Write-Info "'$pk' 的模型列表："
    for ($i = 0; $i -lt $mList.Count; $i++) {
        $m = $mList[$i]
        $ctx = if ($m.contextWindow) { $m.contextWindow } else { "-" }
        $max = if ($m.maxTokens) { $m.maxTokens } else { "-" }
        Write-Host "  $($i + 1)) $($m.id)    上下文=$ctx  最大输出=$max（- = pi 默认）"
    }
    Write-Host "  0) 追加一个新模型"

    $mSel = Read-Input "选择模型序号（0=追加新模型） [0]"
    if ([string]::IsNullOrWhiteSpace($mSel)) { $mSel = "0" }

    # 分支：追加
    if ($mSel -eq "0") {
        $mid = ""
        while ($true) {
            $mid = (Read-Input "新模型 ID").Trim()
            if (-not [string]::IsNullOrEmpty($mid)) { break }
            Write-Warn "模型 ID 不能为空"
        }
        $mctx = (Read-Input "  上下文窗口 token [128000]").Trim()
        $mmax = (Read-Input "  最大输出 token [16384]").Trim()

        $mObj = [PSCustomObject]@{ id = $mid }
        if ($mctx -match '^\d+$' -and [int]$mctx -gt 0) {
            $mObj | Add-Member -NotePropertyName "contextWindow" -NotePropertyValue ([int]$mctx) -Force
        }
        if ($mmax -match '^\d+$' -and [int]$mmax -gt 0) {
            $mObj | Add-Member -NotePropertyName "maxTokens" -NotePropertyValue ([int]$mmax) -Force
        }

        $mList.Add($mObj) | Out-Null
        $p.models = @($mList)
        Write-ModelsJson $models
        Update-ProfileBlock
        Write-Info "已追加模型：$pk / $mid"
        return
    }

    $mIdx = [int]$mSel - 1
    if ($mIdx -lt 0 -or $mIdx -ge $mList.Count) {
        Write-Warn "序号超出范围"
        return
    }
    $targetModel = $mList[$mIdx]

    Write-Host ""
    Write-Host "  1) 修改参数（上下文 / 最大输出）"
    Write-Host "  2) 删除该模型"
    $act = Read-Input "操作 [1]"
    if ([string]::IsNullOrWhiteSpace($act)) { $act = "1" }

    if ($act -eq "2") {
        $okDel = Read-Input "确认删除 '$pk / $($targetModel.id)' ? [y/N]"
        if ($okDel -notmatch '^[yY]') { return }

        $mList.RemoveAt($mIdx)
        $p.models = @($mList)
        Write-ModelsJson $models

        $settings = Read-SettingsJson
        if ($settings.defaultProvider -eq $pk -and $settings.defaultModel -eq $targetModel.id) {
            $settings.PSObject.Properties.Remove("defaultProvider")
            $settings.PSObject.Properties.Remove("defaultModel")
            Write-SettingsJson $settings
            Write-Warn "该模型原为默认模型，默认设置已被清除"
        }
        Update-ProfileBlock
        Write-Info "已删除模型 $pk / $($targetModel.id)"
    } else {
        Write-Info "回车=不变，纯数字=修改，0=恢复 pi 默认值"
        $newCtx = (Read-Input "上下文窗口 token").Trim()
        $newMax = (Read-Input "最大输出 token").Trim()

        if ($newCtx -eq "0") {
            $targetModel.PSObject.Properties.Remove("contextWindow")
        } elseif ($newCtx -match '^\d+$' -and [int]$newCtx -gt 0) {
            $targetModel | Add-Member -NotePropertyName "contextWindow" -NotePropertyValue ([int]$newCtx) -Force
        }

        if ($newMax -eq "0") {
            $targetModel.PSObject.Properties.Remove("maxTokens")
        } elseif ($newMax -match '^\d+$' -and [int]$newMax -gt 0) {
            $targetModel | Add-Member -NotePropertyName "maxTokens" -NotePropertyValue ([int]$newMax) -Force
        }

        $p.models = @($mList)
        Write-ModelsJson $models
        Update-ProfileBlock
        Write-Info "已更新模型：$($targetModel.id) 上下文=$($targetModel.contextWindow) 最大输出=$($targetModel.maxTokens)"
    }
}

# ============================================================
# 菜单 8：卸载
# ============================================================
function Uninstall-PiPkg {
    try {
        if (Get-Command npm -ErrorAction SilentlyContinue) {
            Write-Info "正在卸载 pi 全局 npm 包..."
            & npm uninstall -g @earendil-works/pi-coding-agent
            Write-Info "pi 已卸载"
        }
    } catch {
        Write-Warn "卸载 pi 遇到错误: $($_.Exception.Message)"
    }
}

function Clean-ProfileAndShims {
    # 1. 清理 Profile 托管块
    if (Test-Path $PROFILE_PATH) {
        $rawProfile = Get-Content -Path $PROFILE_PATH -Encoding UTF8
        $newProfile = @()
        $inBlock = $false
        foreach ($line in $rawProfile) {
            if ($line -eq $PROFILE_BLOCK_BEGIN) { $inBlock = $true; continue }
            if ($line -eq $PROFILE_BLOCK_END) { $inBlock = $false; continue }
            if (-not $inBlock) { $newProfile += $line }
        }
        [System.IO.File]::WriteAllLines($PROFILE_PATH, $newProfile, $UTF8_NO_BOM)
        Write-Info "已清理 PowerShell Profile 托管块"
    }

    # 2. 清理 pi-*.cmd
    if (Test-Path $PI_BIN_DIR) {
        Get-ChildItem -Path $PI_BIN_DIR -Filter "pi-*.cmd" -ErrorAction SilentlyContinue | Remove-Item -Force
        Write-Info "已清理快捷脚本 shims"
    }
}

function Remove-PiData {
    if (-not (Test-Path $PI_DIR)) {
        Write-Info "~/.pi/agent 不存在，跳过"
        return
    }
    Write-Host "  1) 全部删除 ~/.pi（配置 + Key + 登录状态 + 会话历史）"
    Write-Host "  2) 只删本工具写的配置（models/settings/keys），保留会话历史"
    $c = Read-Input "选择 [2]"
    if ($c -eq "1") {
        $piRoot = Join-Path $env:USERPROFILE ".pi"
        Remove-Item -Path $piRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Info "$piRoot 已完全删除"
    } else {
        Remove-Item -Path $PI_MODELS_FILE, $PI_SETTINGS_FILE, $PI_KEYS_FILE, $PI_KEYS_PS1 -Force -ErrorAction SilentlyContinue
        Write-Info "配置文件已删除（历史会话保留在 ~/.pi）"
    }
}

function Uninstall-PortableNode {
    $destDir = Join-Path $env:LOCALAPPDATA "Programs\nodejs"
    if (Test-Path $destDir) {
        Write-Warn "检测到本脚本安装的便携版 Node.js: $destDir"
        $ok = Read-Input "确认删除该 Node.js? [y/N]"
        if ($ok -match '^[yY]') {
            Remove-Item -Path $destDir -Recurse -Force -ErrorAction SilentlyContinue
            $userPath = [Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::User)
            $newPath = ($userPath -split ';' | Where-Object { $_ -ne $destDir -and $_ -ne "" }) -join ';'
            [Environment]::SetEnvironmentVariable("PATH", $newPath, [System.EnvironmentVariableTarget]::User)
            Write-Info "便携版 Node.js 已卸载，并已移出用户 PATH"
        }
    } else {
        Write-Info "未发现便携版 Node.js（系统原有 Node.js 不受影响）"
    }
}

function Uninstall-All {
    Write-Host "将依次执行："
    Write-Host "  1) 卸载 pi 全局 npm 包"
    Write-Host "  2) 清理 Profile 别名与快捷命令"
    Write-Host "  3) 删除 pi 配置数据"
    Write-Host "  4) 卸载便携版 Node.js"
    $ok = Read-Input "确认全部卸载? [y/N]"
    if ($ok -notmatch '^[yY]') { return }

    Uninstall-PiPkg
    Clean-ProfileAndShims
    Remove-PiData
    Uninstall-PortableNode
    Write-Info "卸载完成！"
}

function Uninstall-Menu {
    Write-Host ""
    Write-Info "卸载向导（分块清理，系统原有软件不受影响）"
    Write-Host "  a) 全部卸载（pi + 别名/Shim + 配置数据 + 便携版 Node）"
    Write-Host "  1) 只卸载 pi 本体（npm 包）"
    Write-Host "  2) 只清理别名与快捷命令（Profile / shims）"
    Write-Host "  3) 只删 pi 配置与数据"
    Write-Host "  4) 只卸载便携版 Node.js"
    Write-Host "  0) 取消"
    $c = Read-Input "选择 [0]"
    switch ($c.Trim()) {
        "a" { Uninstall-All }
        "A" { Uninstall-All }
        "1" { Uninstall-PiPkg }
        "2" { Clean-ProfileAndShims }
        "3" { Remove-PiData }
        "4" { Uninstall-PortableNode }
        default { }
    }
}

# ============================================================
# 主菜单
# ============================================================
function Show-MainMenu {
    while ($true) {
        Write-Host ""
        Write-Host "=============================================" -ForegroundColor Cyan
        Write-Host "  pi 管理器（安装 · 中转站 · 模型切换）[Win]" -ForegroundColor Cyan
        Write-Host "=============================================" -ForegroundColor Cyan
        Write-Host "  1) 安装 / 更新 pi"
        Write-Host "  2) 添加 / 修改 provider（baseUrl、模型、API Key）"
        Write-Host "  3) 查看当前配置和默认模型"
        Write-Host "  4) 切换默认模型"
        Write-Host "  5) 重设 API Key"
        Write-Host "  6) 删除 provider"
        Write-Host "  7) 修改单个模型（参数 / 追加 / 删除）"
        Write-Host "  8) 卸载（pi / Node / 别名 / 配置）"
        Write-Host "  0) 退出"

        $status = "pi 未安装"
        try {
            $piVer = & pi --version 2>$null
            if ($piVer) { $status = "pi $piVer" }
        } catch {}
        Write-Host "  状态: $status"
        Write-Host "---------------------------------------------" -ForegroundColor Cyan

        $choice = Read-Input "选择> "
        switch ($choice.Trim()) {
            "1" { Install-Pi }
            "2" { Add-Provider }
            "3" { Show-Config }
            "4" { Choose-Default }
            "5" { Reset-Key }
            "6" { Delete-Provider }
            "7" { Edit-Model }
            "8" { Uninstall-Menu }
            "0" { return }
            "q" { return }
            "Q" { return }
            default { }
        }
    }
}

if (-not $NoMenu) {
    Show-MainMenu
}
