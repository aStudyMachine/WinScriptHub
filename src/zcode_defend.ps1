<#
================================================================================
 ZCode 快照防御脚本（继续使用 ZCode 时的防泄露方案）
--------------------------------------------------------------------------------
 原理：快照上传无法用 UI 关闭（据公开披露），因此从文件系统内核层
       拒绝对投料目录 <数据目录>\v2\checkpoints 的写入 —— 快照无法落盘，
       后续向 OSS 的上传自然无从谈起（文章实测：对话/补全/工具调用不受影响，
       失效的只有"检查点回滚/时间线"功能）。

参考链接 : https://www.nodeloc.com/t/topic/109590

 用法：
   .\zcode_defend.ps1 -Action Lock     # 备份并清空投料目录 → 锁死写入（推荐，可回滚）
   .\zcode_defend.ps1 -Action Unlock   # 解锁恢复写入（可回滚操作）
   .\zcode_defend.ps1 -Action Verify   # 验证当前锁定状态与目录内容

   数据目录（.zcode 所在路径）：
    - 未传 -ZcodeRoot 时，脚本会【显式提示你输入】；
    - 直接回车则使用自动检测到的默认候选（检测不到则必须手动输入）；
    - 也可直接指定：.\zcode_defend.ps1 -Action Lock -ZcodeRoot "<你的ZCode数据目录>"

 注意：
   1) Lock 前请【彻底退出 ZCode（含托盘）】，脚本检测到 ZCode 进程在运行会中止；
   2) Lock 会把 checkpoints 内已有内容（本地密文/清单）移动到备份目录
      checkpoints_backup_<时间戳>，确认不再需要后手动删除即可；
   3) Unlock 只恢复目录可写，不会自动删除备份目录；
   4) ZCode 自动更新不会影响本锁定（锁的是数据目录，不是程序文件）。
================================================================================
#>

[CmdletBinding()]
param(
    [ValidateSet('Lock','Unlock','Verify')]
    [string]$Action = 'Verify',
    [string]$ZcodeRoot
)

$ErrorActionPreference = 'Stop'

# ---------- 定位数据目录（显式提醒用户输入） ----------
if (-not $ZcodeRoot) {
    # 仅保留通用默认位置；自定义数据目录请通过 -ZcodeRoot 或交互输入指定
    $candidates = @(
        (Join-Path $env:USERPROFILE '.zcode'),
        (Join-Path $env:LOCALAPPDATA 'ZCode\.zcode')
    ) | Where-Object { Test-Path (Join-Path $_ 'v2') }
    $default = $candidates | Select-Object -First 1
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '  请确认 ZCode 数据目录（.zcode 所在路径）' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    if ($default) {
        Write-Host ("  自动检测到候选：$default") -ForegroundColor Yellow
        Write-Host '  直接回车使用该路径；如不对请手动输入完整路径。' -ForegroundColor DarkGray
    } else {
        Write-Host '  未自动检测到候选，请手动输入完整路径。' -ForegroundColor DarkGray
    }
    $ans = Read-Host '  ZCode 数据目录'
    if ($ans.Trim() -ne '') { $ZcodeRoot = $ans.Trim() } else { $ZcodeRoot = $default }
    Write-Host ''
}
if (-not $ZcodeRoot -or -not (Test-Path (Join-Path $ZcodeRoot 'v2'))) {
    Write-Host ('[错误] 路径无效或未找到 v2 目录：' + $ZcodeRoot) -ForegroundColor Red
    Write-Host '       请确认输入的是 ZCode 数据目录（含 v2 子目录），即 .zcode 所在路径' -ForegroundColor Red
    exit 1
}
$ck = Join-Path $ZcodeRoot 'v2\checkpoints'
Write-Host ("数据目录：$ZcodeRoot" + '（已确认）') -ForegroundColor Cyan
Write-Host "投料目录：$ck" -ForegroundColor Cyan

# ---------- 工具函数 ----------
function Test-Writable($dir) {
    $probe = Join-Path $dir ('.probe_' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($probe, 'probe', (New-Object Text.UTF8Encoding $false))
        Remove-Item $probe -Force
        return $true
    } catch { return $false }
}

function Test-ZCodeRunning {
    $n = @(Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue).Count
    return ($n -gt 0)
}

# ---------- Lock ----------
if ($Action -eq 'Lock') {
    if (Test-ZCodeRunning) {
        Write-Host '[中止] 检测到 ZCode 正在运行。请先彻底退出 ZCode（含托盘图标），再重新执行 Lock。' -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path $ck)) {
        New-Item -ItemType Directory -Path $ck -Force | Out-Null
        Write-Host '[信息] checkpoints 目录不存在，已创建（用于设置 ACL）。' -ForegroundColor Yellow
    }
    # 备份已有投料内容（移动而非删除，可恢复）
    $items = @(Get-ChildItem $ck -Force -ErrorAction SilentlyContinue)
    if ($items.Count -gt 0) {
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        $bak = Join-Path (Split-Path $ck -Parent) "checkpoints_backup_$ts"
        New-Item -ItemType Directory -Path $bak -Force | Out-Null
        Get-ChildItem $ck -Force | Move-Item -Destination $bak -Force
        Write-Host "[信息] 原投料内容已移动到备份：$bak" -ForegroundColor Yellow
        Write-Host "      （含本地密文/清单；确认不再需要后手动删除该目录即可）" -ForegroundColor DarkGray
    } else {
        Write-Host '[信息] checkpoints 为空，无需备份。' -ForegroundColor DarkGray
    }
    # 设置 ACL：只读、拒绝一切写入/追加/改属性（deny 优先于 grant）
    & icacls $ck /inheritance:r /grant "${env:USERNAME}:(OI)(CI)(RX)" /deny "${env:USERNAME}:(OI)(CI)(WD,AD,WEA,WA)" | Out-Null
    # 验证
    $w = Test-Writable $ck
    if ($w) {
        Write-Host '[失败] 目录仍可写，锁定未生效，请检查 ACL。' -ForegroundColor Red
        exit 1
    }
    Write-Host '[完成] 投料目录已锁死（拒绝写入）。' -ForegroundColor Green
    Write-Host '       ZCode 可正常使用；对话/补全/工具调用不受影响，快照将无法生成与上传。' -ForegroundColor Green
    Write-Host '       验证命令：.\zcode_defend.ps1 -Action Verify' -ForegroundColor DarkGray
}

# ---------- Unlock ----------
if ($Action -eq 'Unlock') {
    if (-not (Test-Path $ck)) {
        Write-Host '[错误] checkpoints 目录不存在，无需解锁。' -ForegroundColor Red
        exit 1
    }
    & icacls $ck /remove:d "${env:USERNAME}" | Out-Null
    & icacls $ck /remove:g "${env:USERNAME}" | Out-Null
    & icacls $ck /reset | Out-Null
    $w = Test-Writable $ck
    if (-not $w) {
        Write-Host '[失败] 目录仍不可写，解锁未生效。' -ForegroundColor Red
        exit 1
    }
    Write-Host '[完成] 投料目录已恢复可写（检查点/时间线功能恢复）。' -ForegroundColor Green
    Write-Host '       注意：备份目录 checkpoints_backup_* 未自动删除，确认不需要后手动清理。' -ForegroundColor Yellow
}

# ---------- Verify ----------
if ($Action -eq 'Verify') {
    if (-not (Test-Path $ck)) {
        Write-Host '[结果] checkpoints 目录不存在 —— 未锁定，且无投料痕迹。' -ForegroundColor Yellow
        exit 0
    }
    $w = Test-Writable $ck
    if ($w) {
        Write-Host '[结果] 目录【可写】—— 未锁定。快照投料可正常落盘。' -ForegroundColor Red
    } else {
        Write-Host '[结果] 目录【已锁定】（拒绝写入）—— 快照无法落盘/上传。' -ForegroundColor Green
    }
    $items = @(Get-ChildItem $ck -Force -ErrorAction SilentlyContinue)
    Write-Host ("[结果] checkpoints 当前内容：{0} 项" -f $items.Count)
    $items | Select-Object -First 10 | ForEach-Object { Write-Host "       - $($_.Name) ($(if ($_.PSIsContainer) {'目录'} else {$_.Length}))" }
    if ($items.Count -gt 10) { Write-Host "       ... 共 $($items.Count) 项" }
    if (-not $w) {
        Write-Host '[建议] 保持锁定，定期用 zcode_self_check.ps1 复查 checkpoints 是否持续为空。' -ForegroundColor DarkGray
    }
}
