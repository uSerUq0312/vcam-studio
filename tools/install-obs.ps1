#requires -Version 5.1
<#
  装 OBS 便携版到 D:\dev\OBS（不写入 C 盘、不装服务、不需要管理员）。
  下载走清华镜像（GitHub 直连在本机只有 0.1MB/s，清华镜像 9 秒下完 213MB）。
#>
[CmdletBinding()]
param(
    [string]$ObsRoot = 'D:\dev\OBS',
    [string]$SetupDir = 'D:\dev\setup',
    [string]$Version = '33.0.1'
)

$ErrorActionPreference = 'Stop'
$zipName = "OBS-Studio-$Version-Windows-x64.zip"
$zipPath = Join-Path $SetupDir $zipName
$url = "https://mirrors.tuna.tsinghua.edu.cn/github-release/obsproject/obs-studio/OBS%20Studio%20$Version/$zipName"

if (Test-Path (Join-Path $ObsRoot 'bin\64bit\obs64.exe')) {
    "OBS 已存在：$ObsRoot"
    return
}

New-Item -ItemType Directory -Force -Path $SetupDir, $ObsRoot | Out-Null

if (-not (Test-Path $zipPath)) {
    "下载 $zipName ……"
    & curl.exe -L --retry 3 --retry-delay 2 -o $zipPath $url
    if ($LASTEXITCODE -ne 0) { throw "下载失败：$url" }
}
"压缩包: $zipPath  " + [math]::Round((Get-Item $zipPath).Length / 1MB, 1) + " MB"

Add-Type -AssemblyName System.IO.Compression.FileSystem
"解压到 $ObsRoot ……"
[System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $ObsRoot)

$exe = Join-Path $ObsRoot 'bin\64bit\obs64.exe'
if (-not (Test-Path $exe)) { throw "解压后没找到 obs64.exe" }
"OK OBS $Version 已就位：$exe"
