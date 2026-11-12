#requires -Version 5.1
<#
  启动 OBS（便携模式 + 预置场景）并自动开启虚拟摄像头。
  只负责"把本地视频变成一块摄像头设备"，微信里选设备即可。
#>
[CmdletBinding()]
param(
    [string]$ObsRoot = 'D:\dev\OBS',
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [int]$WaitSeconds = 30
)

$ErrorActionPreference = 'Stop'
$bin = Join-Path $ObsRoot 'bin\64bit'
$exe = Join-Path $bin 'obs64.exe'
if (-not (Test-Path $exe)) { throw "OBS 未安装：$exe（先跑 1-安装OBS.ps1）" }

$cfg = Get-Content (Join-Path $ProjectRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not (Test-Path ([string]$cfg.videoFile))) {
    throw "视频文件不存在：$($cfg.videoFile)`n改 config.json 或双击「4-换视频.bat」"
}

# OBS 异常退出会留下 .sentinel 目录，导致下次启动弹"上次未正常关闭"对话框卡住
$sentinel = Join-Path $ObsRoot 'config\obs-studio\.sentinel'
if (Test-Path $sentinel) { cmd /c "rmdir /s /q `"$sentinel`"" 2>&1 | Out-Null }

$existing = Get-Process obs64 -ErrorAction SilentlyContinue
if ($existing) {
    "OBS 已在运行（pid=$($existing.Id)），先关掉再启动"
    & (Join-Path $PSScriptRoot 'stop-vcam.ps1') -ObsRoot $ObsRoot | Out-Null
    Start-Sleep -Seconds 2
}

$argList = @(
    '--portable',
    '--collection', 'VcamTool',
    '--profile', 'VcamTool',
    '--startvirtualcam',
    '--minimize-to-tray'
)
$p = Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $bin -PassThru
"OBS 已启动 pid=$($p.Id)，等待虚拟摄像头就绪……"

$logDir = Join-Path $ObsRoot 'config\obs-studio\logs'
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$started = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 800
    $log = Get-ChildItem $logDir -Filter '*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $log) { continue }
    try {
        $fs = New-Object System.IO.FileStream($log.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $text = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
    } catch { continue }
    if ($text -match 'Virtual Camera Start') { $started = $true; break }
    if ($text -match 'Failed to start virtual camera|virtual camera.*fail') { break }
}

if ($started) {
    "OK 虚拟摄像头已输出画面（OBS 已缩到托盘，别关它）"
    "   来源视频: $($cfg.videoFile)"
    "   画布    : $($cfg.canvasWidth)x$($cfg.canvasHeight) @ $($cfg.fps)fps"
    "   微信里选摄像头 -> OBS Virtual Camera"
} else {
    "!! 没等到 Virtual Camera Start，看日志排错：$logDir"
    exit 2
}
