<#
.SYNOPSIS
    盘点 Hyper-V 已删虚拟机残留的 VHDX/AVHDX，确认后移入回收站（带回收站配额预检）
    Inventory VHDX/AVHDX left behind by deleted Hyper-V VMs, then move them to the
    Recycle Bin after confirmation (with a recycle-bin quota pre-check).
.DESCRIPTION
    可直接拷贝到其他 Windows 电脑运行，无需修改。每次运行都会重新读取当前机器的
    回收站配置，按实际配额判断哪些文件能真正进入回收站、哪些会被 Windows 永久删除。

    回收站配额读取顺序：
      1. 当前用户 HKCU\...\Explorer\BitBucket\Volume\{卷GUID}\MaxCapacity（自定义值）
      2. 未设置时按 Windows 默认规则推算：min(卷容量,40GB)*10% + 超出40GB部分*5%
         （已用真实机器数据反向验证，误差 <0.15%）

    文件会被分成三类：
      [直接回收] 回收站剩余空间够，不挤占任何旧文件
      [挤占回收] 单个文件不超上限，但空间不够，会挤掉回收站里最旧的条目
      [永久删除] 单个文件超过该盘回收站上限，Windows 必然永久删除，需输入 NUKE 二次确认

    Portable: copy it to any Windows machine and run it as is. The recycle-bin
    configuration is re-read on every run, so files are always classified by the
    actual quota of the machine the tool is running on.

    Quota is read in this order:
      1. HKCU\...\Explorer\BitBucket\Volume\{volume GUID}\MaxCapacity (custom value)
      2. Otherwise derived from the Windows default rule:
         min(capacity,40GB)*10% + portion above 40GB*5%

    Files fall into three tiers: straight to the Recycle Bin / displaces older
    Recycle Bin entries / permanently deleted (the last one needs NUKE).
.PARAMETER Lang
    界面语言：auto（默认，按系统语言自动选择）/ zh（中文）/ en（English）
    UI language: auto (default, follows the system locale) / zh / en
.NOTES
    需要管理员权限（读取回收站占用、调用 Hyper-V 相关 cmdlet）。
    编码为 UTF-8 with BOM，可在任意语言版本的 Windows 上正常显示中文。
    Requires administrator rights; the source file must stay UTF-8 with BOM.
#>

param(
    [ValidateSet('auto', 'zh', 'en')]
    [string]$Lang = 'auto'
)

# ---------- 语言：auto 时系统界面是中文就用中文，其余一律英文 ----------
if ($Lang -eq 'auto') {
    $uiName = ''
    try { $uiName = [System.Globalization.CultureInfo]::CurrentUICulture.Name } catch { }
    if (-not $uiName) { try { $uiName = $PSUICulture } catch { } }
    if ($uiName -match '^zh') { $Lang = 'zh' } else { $Lang = 'en' }
}

# T '中文' 'English'：按当前语言取值，所有对外文案都经它一层
function T {
    param([string]$Zh, [string]$En)
    if ($script:Lang -eq 'en') { return $En }
    return $Zh
}

# 窗口标题：双击 exe 运行时覆盖掉那一长串路径；ISE 等宿主不支持 RawUI 时忽略
try {
    $title = T '清理 Hyper-V 残留磁盘  v1.1' 'Hyper-V Orphan Disk Cleanup  v1.1'
    $Host.UI.RawUI.WindowTitle = $title
} catch { }

# ---------- 窗口布局：尺寸 120x40 / 缓冲 3000 行 / 屏幕居中 ----------
# 四条限制，顺序弄反就白设：
#   1. SetWindowSize 会连带把缓冲区重置成窗口大小 -> 必须「先窗口、后缓冲」
#   2. 窗口不能小于当前窗口 -> 否则 SetBufferSize 直接抛异常
#   3. 小屏幕开不到 120x40 -> 按实际可容纳值自动缩小，不报错
#   4. 屏幕居中只能走 Win32：SetConsoleWindowInfo 控制的是「窗口在缓冲区里的视口」，
#      缓冲区宽 = 窗口宽时横向位置锁定为 0，永远居不了中
function Center-ConsoleWindow {
    try {
        if (-not ([System.Management.Automation.PSTypeName]'HvoConsoleWin').Type) {
            $cs = @'
using System;
using System.Runtime.InteropServices;
public class HvoConsoleWin {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
}
'@
            Add-Type -TypeDefinition $cs -ErrorAction Stop
        }

        $h = [HvoConsoleWin]::GetConsoleWindow()
        if ($h -eq [IntPtr]::Zero) { return }

        $r = New-Object HvoConsoleWin+RECT
        if (-not [HvoConsoleWin]::GetWindowRect($h, [ref]$r)) { return }

        $sw = [HvoConsoleWin]::GetSystemMetrics(0)   # SM_CXSCREEN 主屏宽（像素）
        $sh = [HvoConsoleWin]::GetSystemMetrics(1)   # SM_CYSCREEN 主屏高（像素）
        if ($sw -le 0 -or $sh -le 0) { return }

        $ww = $r.Right - $r.Left
        $wh = $r.Bottom - $r.Top
        $x = [int][Math]::Floor(($sw - $ww) / 2)
        $y = [int][Math]::Floor(($sh - $wh) / 2)
        if ($x -lt 0) { $x = 0 }
        if ($y -lt 0) { $y = 0 }

        # SWP_NOSIZE(0x01) | SWP_NOZORDER(0x04)：只挪位置，不动大小与层级
        [void][HvoConsoleWin]::SetWindowPos($h, [IntPtr]::Zero, $x, $y, 0, 0, 0x01 -bor 0x04)
    } catch {
        # 无控制台窗口（输出被重定向）、Add-Type 被策略禁用时静默跳过
    }
}

function Set-ConsoleLayout {
    param(
        [int]$Width = 120,
        [int]$Height = 40,
        [int]$BufferHeight = 3000,
        [switch]$Center
    )
    try {
        # LargestWindowWidth 在部分 Win11 版本/虚拟显示驱动下返回像素宽度而非列数
        # （本机实测 1904，而 Height 正常返回 62 行），据此判别单位后换算
        $maxCols = [Console]::LargestWindowWidth
        $maxRows = [Console]::LargestWindowHeight
        if ($maxCols -gt 1000) { $maxCols = [int][Math]::Floor($maxCols / 8) }   # 16px 字高，等宽字宽约 8px
        if ($maxRows -gt 250)  { $maxRows = [int][Math]::Floor($maxRows / 16) }
        if ($maxCols -lt 40) { $maxCols = 40 }
        if ($maxRows -lt 12) { $maxRows = 12 }

        $w = [Math]::Min($Width,  $maxCols)
        $h = [Math]::Min($Height, $maxRows)
        if ($w -lt [Console]::WindowWidth)  { $w = [Console]::WindowWidth }
        if ($h -lt [Console]::WindowHeight) { $h = [Console]::WindowHeight }

        [Console]::SetWindowSize($w, $h)
        [Console]::SetBufferSize($w, [Math]::Max($BufferHeight, $h))

        if ($Center) { Center-ConsoleWindow }
    } catch {
        # 宿主不支持、窗口已最大化、输出被重定向时静默跳过，不影响主流程
    }
}

Set-ConsoleLayout -Width 120 -Height 40 -BufferHeight 3000 -Center

# ---------- 0. 基础函数 ----------
function Wait-Exit {
    param([string]$Message = '')
    if (-not $Message) { $Message = T '按任意键退出...' 'Press any key to exit...' }
    Write-Host "`n$Message" -ForegroundColor Yellow
    try {
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } catch {
        $null = Read-Host
    }
}

trap {
    $m = T "`n脚本出错: $_" "`nScript error: $_"
    Write-Host $m -ForegroundColor Red
    Wait-Exit
    break
}

$BitBucketRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume'

# 是否管理员：非管理员读不到回收站占用，只能按文件大小判断
function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList $id
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# 读取某盘回收站策略：容量上限 + 是否被设置为直接删除
function Get-RecyclePolicy {
    param([string]$DriveLetter)   # 形如 "D:"

    $srcUnknown = T '未知' 'unknown'

    $result = [PSCustomObject]@{
        Drive        = $DriveLetter
        MaxBytes     = [int64]0
        MaxSource    = $srcUnknown
        NukeOnDelete = 0
        HasFolder    = $false
        FixedDisk    = $false
        IsVolume     = $false
    }

    $vol = Get-CimInstance Win32_Volume -Filter "DriveLetter='$DriveLetter'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $vol) { return $result }      # 网络路径 / 非卷路径

    $result.IsVolume  = $true
    $result.FixedDisk = ($vol.DriveType -eq 3)
    $result.HasFolder = (Test-Path -LiteralPath "$DriveLetter\`$Recycle.Bin")

    $guid = $null
    if ($vol.DeviceID -match '\{(.+)\}') { $guid = '{' + $matches[1] + '}' }

    if ($guid) {
        $key = Join-Path $BitBucketRoot $guid
        if (Test-Path $key) {
            $pp = Get-ItemProperty $key -ErrorAction SilentlyContinue
            if ($pp.MaxCapacity) {
                $result.MaxBytes  = [int64]$pp.MaxCapacity * 1MB
                $result.MaxSource = T '自定义' 'custom'
            }
            if ($null -ne $pp.NukeOnDelete) { $result.NukeOnDelete = [int]$pp.NukeOnDelete }
        }
    }

    if ($result.MaxBytes -le 0) {
        # Windows 默认规则：前 40GB 取 10%，超出部分取 5%（无 5% 封顶）
        $capMB   = [double]($vol.Capacity / 1MB)
        $first   = [math]::Min($capMB, 40960) * 0.10
        $rest    = [math]::Max(0, $capMB - 40960) * 0.05
        $result.MaxBytes  = [int64](($first + $rest) * 1MB)
        $result.MaxSource = T '默认推算' 'derived'
    }

    return $result
}

# 枚举某盘回收站内文件：路径 -> 字节数
function Get-RecycleFileMap {
    param([string]$DriveLetter)
    $map = @{}
    $rb  = "$DriveLetter\`$Recycle.Bin"
    if (Test-Path -LiteralPath $rb) {
        Get-ChildItem -LiteralPath $rb -Recurse -Force -File -ErrorAction SilentlyContinue |
        ForEach-Object { $map[$_.FullName] = $_.Length }
    }
    return $map
}

function Get-RecycleUsedBytes {
    param([string]$DriveLetter)
    $m = Get-RecycleFileMap $DriveLetter
    if ($m.Count -eq 0) { return [int64]0 }
    return [int64](($m.Values | Measure-Object -Sum).Sum)
}

function Format-Size {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N0} MB" -f ($Bytes / 1MB)) }
    return ("{0:N0} KB" -f ($Bytes / 1KB))
}

# 表头随语言切换：内部属性名保持中文，展示时用 Name/Expression 重命名列
function Show-OrphanTable {
    param(
        [object[]]$Items,
        [string[]]$Columns
    )
    $props = @()
    foreach ($col in $Columns) {
        switch ($col) {
            'No'        { $props += @{ Name = (T '序号' '#');         Expression = { $_.序号 } } }
            'Risk'      { $props += @{ Name = (T '风险' 'Risk');      Expression = { $_.风险 } } }
            'Type'      { $props += @{ Name = (T '类型' 'Type');      Expression = { $_.类型 } } }
            'SizeGB'    { $props += @{ Name = (T '大小GB' 'Size GB'); Expression = { $_.大小GB } } }
            'Drive'     { $props += @{ Name = (T '盘符' 'Drive');     Expression = { $_.盘符 } } }
            'LastWrite' { $props += @{ Name = (T '最后写入' 'Last write'); Expression = { $_.最后写入 } } }
            'Path'      { $props += @{ Name = (T '路径' 'Path');      Expression = { $_.路径 } } }
        }
    }
    $Items | Select-Object -Property $props | Format-Table -AutoSize -Wrap
}

# ---------- 0.5 运行环境自检 ----------
Write-Host (T "`n[0/5] 运行环境自检..." "`n[0/5] Environment self-check...") -ForegroundColor Cyan

if ($Lang -eq 'en') {
    Write-Host '  UI language: English (auto-detected; use -Lang zh to switch)' -ForegroundColor Gray
} else {
    Write-Host '  界面语言: 中文（自动检测；可用 -Lang en 切换）' -ForegroundColor Gray
}

$IsAdmin = Test-IsAdmin
if ($IsAdmin) {
    Write-Host (T '  权限: 管理员（可读取回收站占用）' '  Rights: administrator (recycle-bin usage readable)') -ForegroundColor Gray
} else {
    $m = T '  权限: 非管理员 —— 读不到回收站已占用量，只能按文件大小判断，建议右键以管理员身份运行' '  Rights: not administrator - recycle-bin usage is unreadable, decisions fall back to file size. Run elevated instead.'
    Write-Host $m -ForegroundColor Yellow
}

$hasHyperV = $false
try { $null = Get-Command Get-VM -ErrorAction Stop; $hasHyperV = $true } catch { }

if ($hasHyperV) {
    Write-Host (T '  Hyper-V 模块: 已安装' '  Hyper-V module: installed') -ForegroundColor Gray
} else {
    $m = T '  Hyper-V 模块: 未安装 —— 无法识别正在被虚拟机使用的磁盘' '  Hyper-V module: not installed - disks in use by virtual machines cannot be identified'
    Write-Host $m -ForegroundColor Yellow
    $m = T '  继续扫描可能误删使用中的磁盘，风险很高。仍要继续请输入 CONTINUE' '  Continuing may delete a disk that is in use. Type CONTINUE to proceed anyway'
    $goOn = Read-Host $m
    if ($goOn -ne 'CONTINUE') {
        Write-Host (T '已退出。' 'Aborted.') -ForegroundColor Gray
        Wait-Exit
        return
    }
}

# ---------- 1. 收集当前已占用的磁盘路径 ----------
Write-Host (T "`n[1/5] 正在收集当前 Hyper-V 正在使用的磁盘..." "`n[1/5] Collecting disks currently in use by Hyper-V...") -ForegroundColor Cyan

$inUsePaths = @{}

if ($hasHyperV) {
    Get-VM -ErrorAction SilentlyContinue | ForEach-Object {
        $_ | Get-VMHardDiskDrive -ErrorAction SilentlyContinue | ForEach-Object {
            $inUsePaths[$_.Path] = 'VM硬盘'
        }
        $_ | Get-VMSnapshot -ErrorAction SilentlyContinue | ForEach-Object {
            $_.HardDrives | ForEach-Object {
                try { Get-VHD $_.Path -ErrorAction Stop | ForEach-Object { $inUsePaths[$_.Path] = '快照' } }
                catch { }
            }
        }
    }

    Get-VM -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Get-VHD -VMId $_.VMId -ErrorAction Stop | ForEach-Object {
                $inUsePaths[$_.Path] = 'VHD盘'
                if ($_.ParentPath) { $inUsePaths[$_.ParentPath] = 'VHD父盘' }
            }
        } catch { }
    }
}

$m = T "  当前占用的磁盘: $($inUsePaths.Keys.Count) 条" "  Disks in use: $($inUsePaths.Keys.Count)"
Write-Host $m -ForegroundColor Gray

# ---------- 2. 确定扫描路径 ----------
Write-Host (T "`n[2/5] 确定扫描目录..." "`n[2/5] Determining scan paths...") -ForegroundColor Cyan

$scanPaths = @()
if ($hasHyperV) {
    try { $hd = (Get-VMHost).VirtualHardDiskPath } catch { $hd = $null }
    if ($hd) { $scanPaths += $hd }
}
$scanPaths += "$env:ProgramData\Microsoft\Windows\Hyper-V"
$scanPaths += "$env:PUBLIC\Documents\Hyper-V\Virtual Hard Disks"

$scanPaths = $scanPaths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

$m = T "`n如需额外扫描其他盘符/路径（如 D:\VMs），多个路径用逗号分隔，回车跳过" "`nExtra paths to scan (e.g. D:\VMs), comma-separated, Enter to skip"
$extra = Read-Host $m
if ($extra.Trim()) {
    $extra -split ',' | ForEach-Object {
        $p = $_.Trim()
        if (Test-Path $p) { $scanPaths += $p }
        else {
            $m2 = T "  跳过不存在的路径: $p" "  Skipped, path does not exist: $p"
            Write-Host $m2 -ForegroundColor Yellow
        }
    }
}

if ($scanPaths.Count -eq 0) {
    Write-Host (T '  没有任何可扫描目录，退出。' '  No scannable directory, aborting.') -ForegroundColor Yellow
    Wait-Exit
    return
}

Write-Host (T '  扫描目录:' '  Scan paths:') -ForegroundColor Gray
$scanPaths | ForEach-Object { Write-Host "   - $_" -ForegroundColor Gray }

# ---------- 3. 扫描并比对孤儿文件 ----------
Write-Host (T "`n[3/5] 扫描 VHDX/AVHDX 文件..." "`n[3/5] Scanning VHDX/AVHDX files...") -ForegroundColor Cyan

$candidates = @()
$idx = 0

foreach ($base in $scanPaths) {
    Get-ChildItem -Path $base -Include *.vhdx,*.avhdx -Recurse -Force -ErrorAction SilentlyContinue |
    ForEach-Object {
        $full = $_.FullName
        $isInUse = $false
        foreach ($key in $inUsePaths.Keys) {
            if ($key -eq $full) { $isInUse = $true; break }
        }
        if ($isInUse) { return }

        $idx++
        $risk = T '[安全]' '[Safe]'
        $reason = T '无 VM 关联' 'no VM reference'

        if ($_.Extension -eq '.avhdx') {
            $risk = T '[谨慎]' '[Caution]'
            try {
                $vhd = Get-VHD $full -ErrorAction Stop
                if ($vhd.ParentPath) {
                    $reason = T "存在父盘，请核对: $($vhd.ParentPath)" "has a parent disk, verify: $($vhd.ParentPath)"
                } else {
                    $reason = T '孤立差分盘，可能残留差异数据' 'isolated differencing disk, may still hold unmerged data'
                }
            } catch {
                $reason = T '无法读取 VHD 信息，建议再次核对' 'cannot read VHD info, verify manually'
            }
        }

        $candidates += [PSCustomObject]@{
            序号     = $idx
            风险     = $risk
            类型     = $_.Extension.TrimStart('.')
            大小GB   = [math]::Round($_.Length / 1GB, 2)
            字节     = [int64]$_.Length
            盘符     = (Split-Path $full -Qualifier)
            最后写入 = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            路径     = $full
            原因     = $reason
        }
    }
}

# ---------- 4. 展示清单 ----------
Write-Host (T "`n[4/5] 清单如下" "`n[4/5] Orphan list") -ForegroundColor Cyan
if ($candidates.Count -eq 0) {
    $m = T '  未发现孤儿 VHDX/AVHDX 文件，空间可能被其他对象占用。' '  No orphan VHDX/AVHDX found; the space may be held by something else.'
    Write-Host $m -ForegroundColor Green
    Wait-Exit
    return
}

Show-OrphanTable -Items $candidates -Columns 'No', 'Risk', 'Type', 'SizeGB', 'Drive', 'LastWrite', 'Path'

$m = T "`n请输入要清理的文件序号（支持 1,3,5 或 1-4；输入 ALL 全选；输入 N 取消）: " "`nFiles to clean (3, 1,3,5 or 1-4; input ALL to select everything; N to cancel): "
Write-Host $m -ForegroundColor Yellow -NoNewline
$userInput = ([string](Read-Host)).Trim()

if ($userInput -eq '' -or $userInput -eq 'N') {
    Write-Host (T '已取消' 'Cancelled.') -ForegroundColor Gray
    Wait-Exit
    return
}

if ($userInput -eq 'ALL' -or $userInput -eq '全选' -or $userInput -eq '全部') {
    $todo = $candidates
    $m = T "  已全选：$($todo.Count) 个文件" "  All selected: $($todo.Count) file(s)"
    Write-Host $m -ForegroundColor Cyan
} else {
    $selectedIndexes = @()
    $userInput -split ',' | ForEach-Object {
        $part = $_.Trim()
        if ($part -match '^(\d+)-(\d+)$') {
            ($matches[1]..$matches[2]) | ForEach-Object { $selectedIndexes += [int]$_ }
        } elseif ($part -match '^\d+$') {
            $selectedIndexes += [int]$part
        }
    }

    $todo = $candidates | Where-Object { $selectedIndexes -contains $_.序号 }
}

if (-not $todo -or $todo.Count -eq 0) {
    Write-Host (T '没有匹配到有效序号，退出。' 'No valid selection, aborting.') -ForegroundColor Gray
    Wait-Exit
    return
}

# ---------- 5. 回收站配额预检（每台电脑上现场重新计算） ----------
Write-Host (T "`n[5/5] 回收站容量预检（按本机实际配置计算）..." "`n[5/5] Recycle-bin capacity pre-check (computed from this machine's settings)...") -ForegroundColor Cyan

$policyCache = @{}
$usedCache   = @{}

# 分级用内部代号：A=直接回收 B=挤占回收 C=永久删除，显示时才翻译
foreach ($f in $todo) {
    $d = $f.盘符
    if (-not $policyCache.ContainsKey($d)) { $policyCache[$d] = Get-RecyclePolicy $d }
    if (-not $usedCache.ContainsKey($d)) {
        if ($IsAdmin) { $usedCache[$d] = Get-RecycleUsedBytes $d }
        else          { $usedCache[$d] = [int64]0 }
    }

    $pol = $policyCache[$d]
    $tier = 'A'
    $note = ''

    if (-not $pol.IsVolume) {
        $tier = 'C'
        $note = T '不是本地卷（网络路径或其他），无法进入回收站' 'not a local volume (network path or other), cannot enter the Recycle Bin'
    }
    elseif (-not $pol.FixedDisk) {
        $tier = 'C'
        $note = T '非固定磁盘（可移动/U盘），不支持回收站' 'not a fixed disk (removable/USB drive), Recycle Bin unsupported'
    }
    elseif ($pol.NukeOnDelete -eq 1) {
        $tier = 'C'
        $note = T '该盘回收站已被设置为「删除时不移动到回收站」' 'this volume is set to delete files without using the Recycle Bin'
    }
    elseif (-not $pol.HasFolder) {
        $tier = 'C'
        $note = T '该盘没有 $Recycle.Bin 目录' 'this volume has no $Recycle.Bin folder'
    }
    elseif ($f.字节 -gt $pol.MaxBytes) {
        $tier = 'C'
        $lim = Format-Size $pol.MaxBytes
        $note = T "单个文件大于该盘回收站上限 $lim，Windows 必然永久删除" "file is larger than this volume's Recycle Bin limit $lim; Windows will delete it permanently"
    }
    elseif (($usedCache[$d] + $f.字节) -gt $pol.MaxBytes) {
        $tier = 'B'
        $evict = Format-Size ($usedCache[$d] + $f.字节 - $pol.MaxBytes)
        $note = T "空间不足，将挤掉回收站中最旧的约 $evict" "not enough space; about $evict of the oldest Recycle Bin entries will be pushed out"
    }

    $f | Add-Member -NotePropertyName 分级 -NotePropertyValue $tier -Force
    $f | Add-Member -NotePropertyName 说明 -NotePropertyValue $note -Force
    $f | Add-Member -NotePropertyName 上限 -NotePropertyValue $pol.MaxBytes -Force

    $usedCache[$d] = $usedCache[$d] + $f.字节
}

Write-Host (T "`n本机回收站配置：" "`nRecycle-bin configuration on this machine:") -ForegroundColor Gray
$fmtVol = T "   {0}  上限 {1}（{2}）  已占 {3}" "   {0}  limit {1} ({2})  used {3}"
$fmtNonVol = T "   {0}  非本地卷，不支持回收站" "   {0}  not a local volume, Recycle Bin unsupported"
$policyCache.Keys | Sort-Object | ForEach-Object {
    $p = $policyCache[$_]
    if ($p.IsVolume) {
        if ($IsAdmin) { $u = Format-Size (Get-RecycleUsedBytes $_) } else { $u = T '未知(需管理员)' 'unknown (needs admin)' }
        Write-Host ($fmtVol -f $_, (Format-Size $p.MaxBytes), $p.MaxSource, $u) -ForegroundColor Gray
    } else {
        Write-Host ($fmtNonVol -f $_) -ForegroundColor Gray
    }
}

$tierA = @($todo | Where-Object { $_.分级 -eq 'A' })
$tierB = @($todo | Where-Object { $_.分级 -eq 'B' })
$tierC = @($todo | Where-Object { $_.分级 -eq 'C' })

if ($tierA.Count -gt 0) {
    Write-Host (T "`n可直接进回收站（可随时还原）：" "`nStraight to the Recycle Bin (restorable at any time):") -ForegroundColor Green
    Show-OrphanTable -Items $tierA -Columns 'No', 'Risk', 'SizeGB', 'Drive', 'Path'
}

if ($tierB.Count -gt 0) {
    Write-Host (T "`n可进回收站，但会挤掉回收站里最旧的条目：" "`nWill go to the Recycle Bin, but pushes out the oldest entries:") -ForegroundColor Yellow
    foreach ($f in $tierB) {
        Write-Host "   [$($f.序号)] $($f.路径)" -ForegroundColor Yellow
        Write-Host "          $($f.说明)" -ForegroundColor DarkYellow
    }
}

if ($tierC.Count -gt 0) {
    Write-Host (T "`n执行即永久删除、无法还原：" "`nDeleted permanently on execution, not recoverable:") -ForegroundColor Red
    $fmtSize = T "          大小 {0} GB，{1}" "          size {0} GB, {1}"
    foreach ($f in $tierC) {
        Write-Host "   [$($f.序号)] $($f.路径)" -ForegroundColor Red
        Write-Host ($fmtSize -f $f.大小GB, $f.说明) -ForegroundColor DarkYellow
    }
}

$recyclable = @($tierA + $tierB)

if ($recyclable.Count -eq 0 -and $tierC.Count -eq 0) {
    Wait-Exit
    return
}

# ---- 确认一：进回收站的部分 ----
$c1 = ''
if ($recyclable.Count -gt 0) {
    $m = T "`n确认把上面 $($recyclable.Count) 个文件移入回收站？输入 YES 继续，其他键跳过" "`nMove the $($recyclable.Count) file(s) above to the Recycle Bin? Type YES to continue, any other key skips"
    $c1 = Read-Host $m
}

# ---- 确认二：永久删除的部分 ----
$nuke = $false
if ($tierC.Count -gt 0) {
    $m = T "确认永久删除上面 $($tierC.Count) 个文件？输入 NUKE 继续，其他键跳过" "Permanently delete the $($tierC.Count) file(s) above? Type NUKE to continue, any other key skips"
    $c2 = Read-Host $m
    if ($c2 -eq 'NUKE') { $nuke = $true }
}

if ($c1 -ne 'YES' -and -not $nuke) {
    Write-Host (T '已取消，未做任何删除。' 'Cancelled, nothing was deleted.') -ForegroundColor Gray
    Wait-Exit
    return
}

try {
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
} catch {
    $m = T "`n无法加载 Microsoft.VisualBasic，无法调用删除 API，已中止。" "`nCannot load Microsoft.VisualBasic, the delete API is unavailable. Aborted."
    Write-Host $m -ForegroundColor Red
    Wait-Exit
    return
}

function Invoke-DeleteOne {
    param([string]$Path)
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
        $Path,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
    )
}

$okRecycle = 0
$warnNuke  = 0
$failList  = @()

# ---- 回收站部分：逐个删并核对是否真的进了回收站 ----
if ($c1 -eq 'YES' -and $recyclable.Count -gt 0) {
    Write-Host (T "`n正在移入回收站..." "`nMoving to the Recycle Bin...") -ForegroundColor Cyan

    $mapCache = @{}
    foreach ($f in $recyclable) {
        $d = $f.盘符
        # 同盘复用上一次的快照，避免反复枚举大回收站
        if (-not $mapCache.ContainsKey($d)) { $mapCache[$d] = Get-RecycleFileMap $d }
        $before = $mapCache[$d]

        try {
            Invoke-DeleteOne $f.路径
        } catch {
            $failList += (T "$($f.路径)  ->  调用失败: $_" "$($f.路径)  ->  call failed: $_")
            Write-Host (T "  失败: $($f.路径)" "  FAILED: $($f.路径)") -ForegroundColor Red
            Write-Host "    $_" -ForegroundColor Gray
            continue
        }

        if (Test-Path -LiteralPath $f.路径) {
            $failList += (T "$($f.路径)  ->  删除后文件仍存在（被占用或无权限）" "$($f.路径)  ->  file still exists after delete (locked or access denied)")
            Write-Host (T "  失败: 文件仍存在，可能被 vmms 占用  $($f.路径)" "  FAILED: file still exists, possibly locked by vmms  $($f.路径)") -ForegroundColor Red
            continue
        }

        # 核对：回收站里是否真的多出一个同大小的 $R 数据文件
        $after = Get-RecycleFileMap $d
        $mapCache[$d] = $after
        $hit = $false
        foreach ($k in $after.Keys) {
            if (-not $before.ContainsKey($k) -and $after[$k] -eq $f.字节 -and (Split-Path $k -Leaf) -like '$R*') {
                $hit = $true
                break
            }
        }

        if (-not $IsAdmin) {
            # 非管理员读不全回收站目录，核对会误报，这里只按文件是否消失判断
            $okRecycle++
            Write-Host (T "  已删除（非管理员，无法核对回收站副本）: $($f.路径)" "  Deleted (non-admin, Recycle Bin copy not verifiable): $($f.路径)") -ForegroundColor Yellow
        } elseif ($hit) {
            $okRecycle++
            Write-Host (T "  已进回收站: $($f.路径)" "  In the Recycle Bin: $($f.路径)") -ForegroundColor Green
        } else {
            $warnNuke++
            $failList += (T "$($f.路径)  ->  已被删除，但回收站中未找到副本（实际是永久删除）" "$($f.路径)  ->  deleted, but no copy found in the Recycle Bin (that is a permanent delete)")
            Write-Host (T '  警告: 文件已消失但回收站里没有，实际是永久删除！' '  WARNING: the file is gone but it is not in the Recycle Bin - that is a permanent delete!') -ForegroundColor Red
            Write-Host "         $($f.路径)" -ForegroundColor Red
        }
    }
}

# ---- 永久删除部分 ----
if ($nuke -and $tierC.Count -gt 0) {
    Write-Host (T "`n正在永久删除..." "`nDeleting permanently...") -ForegroundColor Cyan
    foreach ($f in $tierC) {
        try {
            Invoke-DeleteOne $f.路径
            if (Test-Path -LiteralPath $f.路径) {
                $failList += (T "$($f.路径)  ->  删除后文件仍存在" "$($f.路径)  ->  file still exists after delete")
                Write-Host (T "  失败: $($f.路径)" "  FAILED: $($f.路径)") -ForegroundColor Red
            } else {
                Write-Host (T "  已永久删除: $($f.路径)" "  Permanently deleted: $($f.路径)") -ForegroundColor Yellow
            }
        } catch {
            $failList += (T "$($f.路径)  ->  $_" "$($f.路径)  ->  $_")
            Write-Host (T "  失败: $($f.路径)" "  FAILED: $($f.路径)") -ForegroundColor Red
            Write-Host "    $_" -ForegroundColor Gray
        }
    }
}

# ---------- 汇总 ----------
Write-Host (T "`n===== 结果 =====" "`n===== Result =====") -ForegroundColor Cyan
Write-Host (T "  进入回收站（可还原）: $okRecycle 个" "  In the Recycle Bin (restorable): $okRecycle") -ForegroundColor Green
if ($warnNuke -gt 0) {
    Write-Host (T "  已删除但未进回收站: $warnNuke 个" "  Deleted but not in the Recycle Bin: $warnNuke") -ForegroundColor Red
}
if ($nuke) {
    Write-Host (T "  永久删除: $($tierC.Count) 个" "  Permanently deleted: $($tierC.Count)") -ForegroundColor Yellow
}
if ($recyclable.Count -gt 0 -and $c1 -ne 'YES') {
    Write-Host (T "  跳过（未确认回收）: $($recyclable.Count) 个" "  Skipped (recycling not confirmed): $($recyclable.Count)") -ForegroundColor Gray
}
if ($tierC.Count -gt 0 -and -not $nuke) {
    Write-Host (T "  跳过（未确认永久删除）: $($tierC.Count) 个" "  Skipped (permanent delete not confirmed): $($tierC.Count)") -ForegroundColor Gray
}

if ($failList.Count -gt 0) {
    Write-Host (T "`n问题清单：" "`nIssues:") -ForegroundColor Yellow
    $failList | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    $m = T "`n常见原因：文件被 vmms 占用，可先 net stop vmms 后重跑；也可用 Handle64.exe 查占用进程。" "`nCommon cause: the file is locked by vmms. Run 'net stop vmms' and retry, or use Handle64.exe to find the process holding it."
    Write-Host $m -ForegroundColor Gray
}

$m = T "`n想让大文件也能进回收站：右键回收站 → 属性 → 选中该盘 → 自定义大小，调到不小于最大文件体积。" "`nTo let large files reach the Recycle Bin: right-click the Recycle Bin > Properties > select the drive > Custom size, and set it to at least the largest file size."
Write-Host $m -ForegroundColor Cyan

$m = T '全部完成，按任意键退出...' 'Done. Press any key to exit...'
Wait-Exit $m
