<#
.SYNOPSIS
    安装最新 Oracle JDK（LTS 21 / 25 等）到指定目录，并可选配置 JAVA_HOME 与系统 PATH。

.DESCRIPTION
    - 从 Oracle 官方 latest 链接下载 zip，校验 SHA256，解压后命名为 jdk-<主版本> 放入目标目录。
    - 幂等：目标目录已存在则跳过；加 -Force 会将旧目录备份为 .old-<时间戳> 再重装（不删除任何数据）。
    - 环境：用户级 JAVA_HOME 指向最高主版本；系统 PATH 首位插入 <默认JDK>\bin（需 UAC 提权，会弹窗确认）。
    - 全程使用 Windows 自带工具（curl / tar / PowerShell），无需额外安装软件。

.PARAMETER Majors
    要安装的 JDK 主版本列表，默认 21,25。

.PARAMETER InstallDir
    安装根目录，默认 D:\dev\Java。

.PARAMETER SkipEnv
    只安装，不修改任何环境变量。

.PARAMETER Force
    目标目录已存在时，先改名备份再重装最新版。

.EXAMPLE
    .\install-jdk.ps1                                   # 默认安装 JDK 21、25 到 D:\dev\Java 并配置环境
    .\install-jdk.ps1 -Majors 25 -SkipEnv               # 只装 JDK 25，不动环境变量
    .\install-jdk.ps1 -Majors 17,21,25 -InstallDir "C:\Java"   # 自定义版本与目录
#>
param(
    [int[]]$Majors = @(21, 25),
    [string]$InstallDir = "D:\dev\Java",
    [switch]$SkipEnv,
    [switch]$Force
)

# 注意：不使用全局 $ErrorActionPreference='Stop'，因为 java/tar 等原生命令会向
# stderr 输出正常信息（如 java -version），Stop 模式会把它们误判为终止错误。
# 关键步骤改用 $LASTEXITCODE 显式检查与 throw 处理。

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    !: $msg" -ForegroundColor Yellow }

# java -version 的全部输出走 stderr；用 .NET Process 捕获，彻底规避 PowerShell 错误记录噪音
function Get-JavaVersion([string]$exe) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = '-version'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $first = (($out + $err) -split "`r?`n" | Where-Object { $_ -ne '' } | Select-Object -First 1)
    if ($first) { $first } else { '(无法获取版本)' }
}

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " Oracle JDK 一键安装脚本" -ForegroundColor Cyan
Write-Host " 版本: $($Majors -join ',')  目录: $InstallDir" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# ---------- 基础检查 ----------
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw "未找到 curl.exe，无法下载（Windows 10/11 自带）" }
if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue))  { Write-Warn "未找到 tar.exe，将改用 Expand-Archive 解压" }

$InstallDir = $InstallDir.TrimEnd('\')
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Write-Ok "已创建目录 $InstallDir"
}

$DefaultMajor = ($Majors | Measure-Object -Maximum).Maximum

# ---------- 逐个版本安装 ----------
foreach ($m in $Majors) {
    Write-Host ""
    Write-Step "========== 处理 JDK $m =========="
    $target = Join-Path $InstallDir "jdk-$m"

    if ((Test-Path $target) -and -not $Force) {
        Write-Warn "jdk-$m 已存在，跳过安装（如需重装最新版请加 -Force）"
        $cur = Get-JavaVersion "$target\bin\java.exe"
        Write-Ok "当前版本: $cur"
        continue
    }
    if ((Test-Path $target) -and $Force) {
        $old = "$target.old-$(Get-Date -Format 'yyyyMMddHHmmss')"
        Rename-Item $target $old
        Write-Warn "原目录已备份为 $old"
    }

    # 1. 下载
    $zip = Join-Path $env:TEMP "jdk-$m.zip"
    $url = "https://download.oracle.com/java/$m/latest/jdk-${m}_windows-x64_bin.zip"
    Write-Step "下载 $url"
    curl.exe -L --retry 3 --retry-delay 3 --connect-timeout 30 -o $zip $url
    if ($LASTEXITCODE -ne 0) { throw "JDK $m 下载失败，请检查网络后重试" }
    Write-Ok "下载完成: $([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB"

    # 2. SHA256 校验（Oracle 官方提供 .sha256 文件）
    try {
        $expect = (curl.exe -s "$url.sha256").Trim().ToLower()
        $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
        if ([string]::IsNullOrEmpty($expect)) { throw 'sha-empty' }
        if ($expect -ne $actual) { throw "JDK $m SHA256 校验失败（文件损坏或被篡改），已中止" }
        Write-Ok "SHA256 校验通过"
    } catch {
        if ($_.Exception.Message -match '校验失败') { throw }
        Write-Warn "无法获取官方 SHA256，跳过校验（$($_.Exception.Message)）"
    }

    # 3. 解压到临时目录
    $stage = Join-Path $env:TEMP "jdk-${m}-stage"
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Write-Step "解压中..."
    if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
        tar.exe -xf $zip -C $stage
        if ($LASTEXITCODE -ne 0) { throw "JDK $m 解压失败" }
    } else {
        Expand-Archive -Path $zip -DestinationPath $stage -Force
    }
    $top = Get-ChildItem $stage -Directory | Select-Object -First 1
    if (-not $top) { throw "JDK $m 解压结果为空" }

    # 4. 版本核对（release 文件）
    $rel = Get-Content (Join-Path $top.FullName 'release') -Raw
    if ($rel -notmatch ("JAVA_VERSION=`"{0}\." -f $m)) {
        throw "JDK $m 解压后版本与预期不符，已中止（release: $rel）"
    }
    if ($rel -match 'IMPLEMENTOR="([^"]+)"') { Write-Ok "厂商: $($Matches[1])" }
    Write-Ok "版本核对通过"

    # 5. 就位
    Move-Item $top.FullName $target
    Write-Ok "已安装到 $target"

    # 6. 运行验证
    $ver = Get-JavaVersion "$target\bin\java.exe"
    $jvc = Get-JavaVersion "$target\bin\javac.exe"
    Write-Ok "java : $ver"
    Write-Ok "javac: $jvc"

    # 7. 清理临时文件
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------- 环境变量配置 ----------
if (-not $SkipEnv) {
    Write-Host ""
    Write-Step "========== 配置环境变量（JAVA_HOME + PATH） =========="
    $jdkHome = Join-Path $InstallDir "jdk-$DefaultMajor"
    $jdkBin  = Join-Path $jdkHome "bin"
    if (-not (Test-Path $jdkBin)) { throw "默认 JDK jdk-$DefaultMajor 未安装，无法配置环境变量" }

    # 备份
    $backupFile = Join-Path $InstallDir ("java_env_backup_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $mPath = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -ErrorAction SilentlyContinue).Path
    $uPath = (Get-ItemProperty 'HKCU:\Environment' -ErrorAction SilentlyContinue).Path
    $uJh   = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User')
    @"
JDK 环境变量备份（修改前） 时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
------------------------------------------------------------------
Machine PATH:
$mPath

User PATH:
$uPath

JAVA_HOME(User): $uJh
"@ | Set-Content -Path $backupFile -Encoding UTF8
    Write-Ok "环境变量已备份到 $backupFile"

    # JAVA_HOME（用户级，无需管理员）
    if ($uJh -ne $jdkHome) {
        [Environment]::SetEnvironmentVariable('JAVA_HOME', $jdkHome, 'User')
        Write-Ok "JAVA_HOME(User) = $jdkHome"
    } else {
        Write-Ok "JAVA_HOME 已正确，跳过"
    }

    # 系统 PATH 前置（需管理员，走 UAC）
    $escBin = [regex]::Escape($jdkBin)
    if ($mPath -match "^$escBin(;|$)") {
        Write-Ok "系统 PATH 已包含 $jdkBin 且在首位，跳过"
    } else {
        $helper = Join-Path $env:TEMP "jdk-env-elevated-$PID.ps1"
        $log    = Join-Path $env:TEMP "jdk-env-elevated-$PID.log"
        @"
`$ErrorActionPreference = 'Stop'
`$raw = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').Path
`$items = `$raw -split ';' | Where-Object { `$_ -ne '' -and `$_ -ine '$jdkBin' }
`$new = '$jdkBin;' + (`$items -join ';')
reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' /v Path /t REG_EXPAND_SZ /d `$new /f | Out-Null
Add-Type -Namespace Win32 -Name EnvBroadcast -MemberDefinition '[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'
`$r = [UIntPtr]::Zero
[void][Win32.EnvBroadcast]::SendMessageTimeout([IntPtr]0xFFFF, 0x001A, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]`$r)
Set-Content -Path '$log' -Value ('OK ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
"@ | Set-Content -Path $helper -Encoding UTF8
        Write-Step "修改系统 PATH 需要管理员权限，将弹出 UAC 窗口，请点击「是」"
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$helper`"" -Verb RunAs -Wait
        } catch {
            throw "UAC 提权失败：$($_.Exception.Message)"
        }
        if (-not (Test-Path $log)) { throw "UAC 未确认或提权脚本执行失败，系统 PATH 未修改（其余安装已完成）" }
        Write-Ok "系统 PATH 已前置 $jdkBin"
        Remove-Item $helper, $log -Force -ErrorAction SilentlyContinue
    }

    # 模拟新会话，验证 java 解析结果
    Write-Host ""
    Write-Step "模拟新终端环境验证："
    $env:Path = [Environment]::ExpandEnvironmentVariables((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').Path) + ';' + [Environment]::ExpandEnvironmentVariables((Get-ItemProperty 'HKCU:\Environment').Path)
    $env:JAVA_HOME = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User')
    Write-Ok "JAVA_HOME = $env:JAVA_HOME"
    $javaCmd = Get-Command java -ErrorAction SilentlyContinue
    if (-not $javaCmd) { Write-Warn "新环境中未解析到 java（PATH 异常）" } else {
        Write-Ok "java 解析到: $($javaCmd.Source)"
        Write-Ok "java : $(Get-JavaVersion $javaCmd.Source)"
    }
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host " 全部完成" -ForegroundColor Green
if ($SkipEnv) {
    Write-Host " 已安装: $($Majors | ForEach-Object { "$InstallDir\jdk-$_" })" -ForegroundColor Green
} else {
    Write-Host " 已安装并配置环境变量，默认 Java = jdk-$DefaultMajor" -ForegroundColor Green
}
Write-Host " 注意：已打开的终端请重新打开后再使用 java / javac" -ForegroundColor Yellow
Write-Host "==============================================" -ForegroundColor Green
