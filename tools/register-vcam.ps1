#requires -Version 5.1
<#
  免管理员注册 OBS 虚拟摄像头（DirectShow 视频输入设备）。
  原理：把滤镜 CLSID 与设备类目实例写进 HKCU\Software\Classes（HKCR 的每用户合并视图），
        64 位进程枚举摄像头时会读到，全程不需要提升权限。
  对应官方做法是 core\win-dshow\data\virtualcam-install.bat（要管理员，写 HKLM）。
#>
[CmdletBinding()]
param(
    [string]$ObsRoot = 'D:\dev\OBS',
    [string]$DeviceName = 'OBS Virtual Camera',
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'

$FilterClsid = '{A3FCE0F5-3493-419F-958A-ABA1250EC20B}'   # OBS Virtual Camera 滤镜 CLSID
$VideoInputCategory = '{860BB310-5D01-11D0-BD3B-00A0C911CE86}'  # CLSID_VideoInputDeviceCategory

$dll64 = Join-Path $ObsRoot 'core\win-dshow\data\obs-virtualcam-module64.dll'
$dll32 = Join-Path $ObsRoot 'core\win-dshow\data\obs-virtualcam-module32.dll'
if (-not (Test-Path $dll64)) { throw "找不到 $dll64 ，OBS 目录不对？" }

$clsRoot = "HKCU:\Software\Classes\CLSID\$FilterClsid"
$catRoot = "HKCU:\Software\Classes\CLSID\$VideoInputCategory\Instance\$FilterClsid"

if ($Unregister) {
    Remove-Item $catRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $clsRoot -Recurse -Force -ErrorAction SilentlyContinue
    "已注销（HKCU）：$DeviceName"
    return
}

# 1) 滤镜自身：InprocServer32 指向 DLL
New-Item -Path "$clsRoot\InprocServer32" -Force | Out-Null
Set-ItemProperty -Path "$clsRoot\InprocServer32" -Name '(default)' -Value $dll64
Set-ItemProperty -Path "$clsRoot\InprocServer32" -Name 'ThreadingModel' -Value 'Both'
Set-ItemProperty -Path $clsRoot -Name '(default)' -Value 'OBS Virtual Camera Filter'

# 2) 挂到视频输入设备类目，才会出现在摄像头列表里
New-Item -Path $catRoot -Force | Out-Null
Set-ItemProperty -Path $catRoot -Name '(default)' -Value $DeviceName
Set-ItemProperty -Path $catRoot -Name 'CLSID' -Value $FilterClsid
Set-ItemProperty -Path $catRoot -Name 'FriendlyName' -Value $DeviceName

# 3) 32 位进程（老的 32 位程序）走 WOW6432Node，可选
if (Test-Path $dll32) {
    $clsRoot32 = "HKCU:\Software\Classes\WOW6432Node\CLSID\$FilterClsid"
    $catRoot32 = "HKCU:\Software\Classes\WOW6432Node\CLSID\$VideoInputCategory\Instance\$FilterClsid"
    New-Item -Path "$clsRoot32\InprocServer32" -Force | Out-Null
    Set-ItemProperty -Path "$clsRoot32\InprocServer32" -Name '(default)' -Value $dll32
    Set-ItemProperty -Path "$clsRoot32\InprocServer32" -Name 'ThreadingModel' -Value 'Both'
    New-Item -Path $catRoot32 -Force | Out-Null
    Set-ItemProperty -Path $catRoot32 -Name '(default)' -Value $DeviceName
    Set-ItemProperty -Path $catRoot32 -Name 'CLSID' -Value $FilterClsid
    Set-ItemProperty -Path $catRoot32 -Name 'FriendlyName' -Value $DeviceName
}

"已注册（HKCU，无需管理员）：$DeviceName"
"  CLSID  : $FilterClsid"
"  DLL    : $dll64"
