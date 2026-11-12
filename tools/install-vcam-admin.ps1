#requires -Version 5.1
<#
  把 OBS 虚拟摄像头注册成"机器级"DirectShow 视频输入设备（HKLM）。
  必须机器级：实测 Media Foundation 的 MFEnumDeviceSources 只认 HKLM 下的设备类目注册，
  写 HKCU 的虚拟摄像头 DShow 应用能看到、微信这类走 MF 的应用看不到。

  会自动请求管理员权限（UAC 点"是"）。
#>
[CmdletBinding()]
param([string]$ObsRoot = 'D:\dev\OBS')

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    "需要管理员权限，正在弹出 UAC……"
    $psi = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ObsRoot `"$ObsRoot`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $psi -Verb RunAs
    return
}

$dll64 = Join-Path $ObsRoot 'core\win-dshow\data\obs-virtualcam-module64.dll'
$dll32 = Join-Path $ObsRoot 'core\win-dshow\data\obs-virtualcam-module32.dll'
if (-not (Test-Path $dll64)) { throw "找不到 $dll64" }

$FilterClsid = '{A3FCE0F5-3493-419F-958A-ABA1250EC20B}'
$VideoInputCategory = '{860BB310-5D01-11D0-BD3B-00A0C911CE86}'

"注册 64 位虚拟摄像头……"
Start-Process regsvr32.exe -ArgumentList "/i /s `"$dll64`"" -Wait -NoNewWindow
if (Test-Path $dll32) {
    "注册 32 位虚拟摄像头……"
    Start-Process regsvr32.exe -ArgumentList "/i /s `"$dll32`"" -Wait -NoNewWindow
}

$ok64 = Test-Path "HKLM:\SOFTWARE\Classes\CLSID\$FilterClsid\InprocServer32"
$okCat = Test-Path "HKLM:\SOFTWARE\Classes\CLSID\$VideoInputCategory\Instance\$FilterClsid"
"HKLM CLSID      : $ok64"
"HKLM 设备类目实例: $okCat"

if (-not $okCat) {
    # regsvr32 没写类目实例时，手工补一条（机器级）
    $cat = "HKLM:\SOFTWARE\Classes\CLSID\$VideoInputCategory\Instance\$FilterClsid"
    New-Item -Path $cat -Force | Out-Null
    Set-ItemProperty -Path $cat -Name '(default)' -Value 'OBS Virtual Camera'
    Set-ItemProperty -Path $cat -Name 'CLSID'     -Value $FilterClsid
    Set-ItemProperty -Path $cat -Name 'FriendlyName' -Value 'OBS Virtual Camera'
    "已手工补齐机器级设备类目实例"
}

if ($ok64) { "OK 机器级注册完成：OBS Virtual Camera 现在对 DirectShow 和 Media Foundation 都可见" }
else { "注册失败，请确认 OBS 目录正确且 UAC 已通过" }
