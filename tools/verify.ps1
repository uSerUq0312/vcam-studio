#requires -Version 5.1
<#
  自检：注册状态 -> 设备枚举 -> 从虚拟摄像头抓一帧。
  抓不到帧 = 微信里也一定看不到画面，先按这里的信息排错。
#>
[CmdletBinding()]
param(
    [string]$ObsRoot = 'D:\dev\OBS',
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Ffmpeg = 'D:\dev\tools\ffmpeg\bin\ffmpeg.exe'
)

$ErrorActionPreference = 'Continue'
$FilterClsid = '{A3FCE0F5-3493-419F-958A-ABA1250EC20B}'
$Cat = '{860BB310-5D01-11D0-BD3B-00A0C911CE86}'

"===== 1. 注册状态 ====="
$hklm = Test-Path "HKLM:\SOFTWARE\Classes\CLSID\$Cat\Instance\$FilterClsid"
$hkcu = Test-Path "HKCU:\Software\Classes\CLSID\$Cat\Instance\$FilterClsid"
"机器级 HKLM（微信/MF 需要）: " + $(if ($hklm) { '已注册' } else { '未注册 -> 跑「2-注册虚拟摄像头(管理员).bat」' })
"用户级 HKCU（DShow 应用）  : " + $(if ($hkcu) { '已注册' } else { '未注册' })

"===== 2. OBS 进程 ====="
$p = Get-Process obs64 -ErrorAction SilentlyContinue
"OBS: " + $(if ($p) { "运行中 pid=$($p.Id)" } else { '未运行 -> 跑「3-启动虚拟摄像头.bat」' })

"===== 3. DirectShow 设备列表 ====="
if (Test-Path $Ffmpeg) {
    & $Ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 |
        Where-Object { $_ -match '" \(' } |
        ForEach-Object { '  ' + ($_ -replace '^\[[^\]]*\]\s*', '') }
} else { '  ffmpeg 缺失：' + $Ffmpeg }

"===== 4. 抓帧 ====="
$png = Join-Path $ProjectRoot '_selftest.png'
Remove-Item $png -Force -ErrorAction SilentlyContinue
if (-not $p) {
    "  OBS 没运行，跳过（虚拟摄像头没有画面源）"
} else {
    & $Ffmpeg -hide_banner -loglevel error -y -f dshow -rtbufsize 256M -i 'video=OBS Virtual Camera' -frames:v 1 -update 1 $png 2>&1 |
        ForEach-Object { '  ' + $_ }
    if (Test-Path $png) {
        $dim = & $Ffmpeg -hide_banner -i $png 2>&1 | Select-String 'Stream.*Video' | Select-Object -First 1
        "  OK 抓到一帧 -> $png"
        "     " + ($dim -replace '^\s+', '')
    } else {
        "  抓帧失败：设备在但没数据流，检查 OBS 是否真的开了虚拟摄像头"
    }
}

"===== 结论 ====="
if ($hklm -and $p -and (Test-Path $png)) {
    "一切就绪：微信 视频通话 -> 摄像头选「OBS Virtual Camera」即可"
} else {
    "按上面标红的两步补齐：先机器级注册，再启动虚拟摄像头"
}
