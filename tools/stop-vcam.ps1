#requires -Version 5.1
<#
  停止虚拟摄像头：优雅关闭 OBS（发 WM_CLOSE 让 OBS 自己清理），失败再强杀，
  最后清掉 .sentinel，保证下次启动不弹"未正常关闭"。
#>
[CmdletBinding()]
param([string]$ObsRoot = 'D:\dev\OBS')

$ErrorActionPreference = 'Continue'
$p = Get-Process obs64 -ErrorAction SilentlyContinue
if (-not $p) {
    "OBS 没在运行"
} else {
    "关闭 OBS pid=$($p.Id)……"
    cmd /c "taskkill /PID $($p.Id)" 2>&1 | Out-Null      # 不带 /F：发 WM_CLOSE，让 OBS 正常退出
    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline -and -not $p.HasExited) { Start-Sleep -Milliseconds 400 }
    if (-not $p.HasExited) {
        "优雅关闭超时，强制结束"
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    "OBS 已退出"
}

$sentinel = Join-Path $ObsRoot 'config\obs-studio\.sentinel'
if (Test-Path $sentinel) { cmd /c "rmdir /s /q `"$sentinel`"" 2>&1 | Out-Null }
"虚拟摄像头已停止"
