#Requires -Version 5.1
<#
.SYNOPSIS
    把 Clean-HyperVOrphans.ps1 编译成单文件 exe
.DESCRIPTION
    用 ps2exe 打包，内嵌图标与 requireAdministrator 清单（双击自动提权）。
    源码必须保持 UTF-8 with BOM，否则 ps2exe 会按 ANSI 读取，中文全变乱码。
.EXAMPLE
    .\build.ps1
.EXAMPLE
    .\build.ps1 -Version 1.0.7.0
#>
[CmdletBinding()]
param(
    [string]$Version = '1.0.7.0',
    [string]$OutputFile = 'Clean-HyperVOrphans.exe'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $root 'Clean-HyperVOrphans.ps1'
$ico  = Join-Path $root 'assets\hvo_icon.ico'
$out  = Join-Path $root $OutputFile

if (-not (Test-Path -LiteralPath $src)) { throw "找不到源脚本: $src" }
if (-not (Test-Path -LiteralPath $ico)) { throw "找不到图标: $ico" }

# ---- 1. 语法校验 ----
$err = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$err)
if ($err.Count -gt 0) {
    $err | ForEach-Object { Write-Host ("  行{0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) -ForegroundColor Red }
    throw "源脚本存在 $($err.Count) 处语法错误，已中止"
}
Write-Host '语法校验: 通过' -ForegroundColor Green

# ---- 2. 编码修正：必须 UTF-8 with BOM ----
$bytes = [System.IO.File]::ReadAllBytes($src)
$hasBom = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
if (-not $hasBom) {
    $text = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($src, $text, [System.Text.UTF8Encoding]::new($true))
    Write-Host 'BOM 缺失，已补回（无 BOM 会被 ps2exe 按 ANSI 读取，中文必乱）' -ForegroundColor Yellow
}

# ---- 3. 载入 ps2exe ----
if (-not (Get-Module -ListAvailable ps2exe)) {
    throw '未安装 ps2exe。请先执行: Install-Module ps2exe -Scope CurrentUser'
}
Import-Module ps2exe -Force

# ---- 4. 编译 ----
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }

try {
    Invoke-PS2EXE -inputFile $src -outputFile $out -requireAdmin -iconFile $ico `
        -title '清理 Hyper-V 残留磁盘' `
        -description '扫描并清理 Hyper-V 已删虚拟机残留的 VHDX/AVHDX；删除前校验回收站配额，可区分可直接回收与会被永久删除的文件' `
        -product 'Clean-HyperVOrphans' -company 'neverno' -version $Version | Out-Null
} catch {
    # ps2exe 收尾清理临时文件时可能抛错，此时 exe 通常已正常写出
    Write-Host "编译尾段异常（多为清理临时文件所致）: $($_.Exception.Message)" -ForegroundColor DarkYellow
}

# ---- 5. 校验产物 ----
if (-not (Test-Path -LiteralPath $out)) { throw '编译失败，未生成 exe' }

$exe = Get-Item -LiteralPath $out
$b = [System.IO.File]::ReadAllBytes($out)
$txt = [System.Text.Encoding]::UTF8.GetString($b)

$checks = [ordered]@{
    'MZ 头'              = ([System.Text.Encoding]::ASCII.GetString($b[0..1]) -eq 'MZ')
    '自动提权清单'        = $txt.Contains('requireAdministrator')
    '脚本正文已嵌入'      = $txt.Contains('回收站容量预检')
    '全选功能'            = $txt.Contains('输入 ALL 全选')
}
Write-Host "`n校验结果:" -ForegroundColor Cyan
foreach ($k in $checks.Keys) {
    $mark = if ($checks[$k]) { 'OK  ' } else { 'FAIL' }
    $color = if ($checks[$k]) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}" -f $mark, $k) -ForegroundColor $color
}

Write-Host ("`n完成: {0}  ({1:N0} 字节, v{2})" -f $exe.Name, $exe.Length, $Version) -ForegroundColor Green
