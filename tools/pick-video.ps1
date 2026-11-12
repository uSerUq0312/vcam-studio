#requires -Version 5.1
<#
  换片源：弹文件选择框 -> 用 ffprobe 读分辨率自动定画布 -> 写 config.json -> 重建 OBS 场景 -> 重启虚拟摄像头。
  双击「4-换视频.bat」就是跑这个。
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Ffprobe = 'D:\dev\tools\ffmpeg\bin\ffprobe.exe'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$dlg = New-Object System.Windows.Forms.OpenFileDialog
$dlg.Title = '选一个要播放的本地视频（会循环播放）'
$dlg.Filter = '视频文件|*.mp4;*.mkv;*.mov;*.avi;*.webm;*.flv;*.wmv;*.m4v;*.ts|所有文件|*.*'
$dlg.CheckFileExists = $true
if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { "已取消"; return }

$video = $dlg.FileName
"选中: $video"

# 读分辨率，按视频比例定画布，避免竖屏视频被塞进 16:9 里两头黑边
$w = 1280; $h = 720; $fps = 30
if (Test-Path $Ffprobe) {
    $raw = & $Ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=p=0 $video 2>$null
    if ($raw) {
        $parts = ($raw -split ',')
        $vw = [int]$parts[0]; $vh = [int]$parts[1]
        if ($vw -gt 0 -and $vh -gt 0) {
            $scale = [Math]::Min(1.0, 1280.0 / [Math]::Max($vw, $vh))
            $w = [int]([Math]::Round($vw * $scale / 2) * 2)
            $h = [int]([Math]::Round($vh * $scale / 2) * 2)
        }
        if ($parts[2] -match '^(\d+)/(\d+)$') {
            $num = [double]$Matches[1]; $den = [double]$Matches[2]
            if ($den -gt 0) { $fps = [int][Math]::Round($num / $den) }
            if ($fps -lt 5 -or $fps -gt 60) { $fps = 30 }
        }
    }
}

$cfg = [ordered]@{
    videoFile    = $video
    canvasWidth  = $w
    canvasHeight = $h
    fps          = $fps
    muteAudio    = $true
}
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $ProjectRoot 'config.json'), ($cfg | ConvertTo-Json), $enc)
"画布: ${w}x${h} @ ${fps}fps"

& (Join-Path $PSScriptRoot 'build-scene.ps1') -ProjectRoot $ProjectRoot

$obs = Get-Process obs64 -ErrorAction SilentlyContinue
if ($obs) {
    "重启虚拟摄像头以生效……"
    & (Join-Path $PSScriptRoot 'start-vcam.ps1') -ProjectRoot $ProjectRoot
    if ($LASTEXITCODE -ne 0) { }
} else {
    "配置已更新，下次双击「2-启动虚拟摄像头.bat」就是新视频"
}
