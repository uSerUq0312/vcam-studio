#requires -Version 5.1
<#
  依据 config.json 生成 OBS 便携版（--portable）的 Profile 与场景集合。
  只改 D:\dev\OBS\config 下的两个文件，不碰用户自己装的其他 OBS。
#>
[CmdletBinding()]
param(
    [string]$ObsRoot = 'D:\dev\OBS',
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 没有 utf8NoBOM，用 .NET 直接写无 BOM UTF-8（OBS 的 JSON 解析器不吃 BOM）
function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

$cfgPath = Join-Path $ProjectRoot 'config.json'
if (-not (Test-Path $cfgPath)) { throw "找不到 config.json: $cfgPath" }
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

$video = [string]$cfg.videoFile
if (-not (Test-Path $video)) { throw "config.json 里的 videoFile 不存在: $video" }
# OBS 内部用正斜杠更稳，且避免每次重建产生差异
$videoFwd = ($video -replace '\\', '/')

$W = [int]$cfg.canvasWidth
$H = [int]$cfg.canvasHeight
$fps = [int]$cfg.fps
if ($W -le 0 -or $H -le 0) { throw 'canvasWidth / canvasHeight 非法' }

$profName = 'VcamTool'
$sceneName = 'VcamTool'
$cfgRoot = Join-Path $ObsRoot 'config\obs-studio'
$profDir = Join-Path $cfgRoot "basic\profiles\$profName"
$sceneDir = Join-Path $cfgRoot 'basic\scenes'
New-Item -ItemType Directory -Force -Path $profDir, $sceneDir | Out-Null

# ---------- 1. Profile (basic.ini)：画布/输出分辨率、帧率 ----------
$basicIni = @"
[General]
Name=$profName

[Output]
Mode=Simple
FilenameFormatting=%CCYY-%MM-%DD %hh-%mm-%ss
DelayEnable=false
DelaySec=20
DelayPreserve=true
Reconnect=true
RetryDelay=2
MaxRetries=25
BindIP=default
IPFamily=IPv4+IPv6
NewSocketLoopEnable=false
LowLatencyEnable=false

[SimpleOutput]
RecFormat2=hybrid_mp4
VBitrate=6000
ABitrate=160
UseAdvanced=false
Preset=veryfast
NVENCPreset2=p5
RecQuality=Stream
RecRB=false
RecRBTime=20
RecRBSize=512
RecAudioEncoder=aac
RecTracks=1

[Video]
BaseCX=$W
BaseCY=$H
OutputCX=$W
OutputCY=$H
FPSType=0
FPSCommon=$fps
FPSInt=$fps
FPSNum=$fps
FPSDen=1
ScaleType=bicubic
ColorFormat=NV12
ColorSpace=709
ColorRange=Partial
SdrWhiteLevel=300
HdrNominalPeakLevel=1000

[Audio]
MonitoringDeviceId=default
MonitoringDeviceName=default
SampleRate=48000
ChannelSetup=Stereo
MeterDecayRate=23.53
PeakMeterType=0
"@
Write-Utf8NoBom -Path (Join-Path $profDir 'basic.ini') -Text $basicIni

# ---------- 2. 场景集合：一个媒体源，铺满画布，循环播放 ----------
$srcUuid = [guid]::NewGuid().ToString()
$sceneUuid = [guid]::NewGuid().ToString()

$mediaSource = [ordered]@{
    prev_ver              = 553648129
    name                  = '本地视频'
    uuid                  = $srcUuid
    id                    = 'ffmpeg_source'
    versioned_id          = 'ffmpeg_source'
    settings              = [ordered]@{
        is_local_file        = $true
        local_file           = $videoFwd
        looping              = $true
        restart_on_activate  = $true
        close_when_inactive  = $false
        clear_on_media_end   = $true
        hw_decode            = $true
        speed_percent        = 100
    }
    mixers                = 255
    sync                  = 0
    flags                 = 0
    volume                = 0.0
    balance               = 0.5
    enabled               = $true
    muted                 = [bool]$cfg.muteAudio
    'push-to-mute'        = $false
    'push-to-mute-delay'  = 0
    'push-to-talk'        = $false
    'push-to-talk-delay'  = 0
    hotkeys               = [ordered]@{
        'libobs.mute'        = @()
        'libobs.unmute'      = @()
        'libobs.monitor-on'  = @()
        'libobs.monitor-off' = @()
        'libobs.push-to-mute'   = @()
        'libobs.push-to-talk'   = @()
    }
    deinterlace_mode      = 0
    deinterlace_field_order = 0
    monitoring_type       = 0
    monitoring_enabled    = $false
    private_settings      = @{}
}

# 窗口捕获源：GUI 面板里选窗口后由 obs-websocket 改设置 + 切可见性，默认隐藏
$windowUuid = [guid]::NewGuid().ToString()
$windowSource = [ordered]@{
    prev_ver              = 553648129
    name                  = '窗口捕获'
    uuid                  = $windowUuid
    id                    = 'window_capture'
    versioned_id          = 'window_capture'
    settings              = [ordered]@{
        method       = 2
        capture_mode = 'window'
        window       = ''
        cursor       = $false
        client_area  = $false
        force_sdr    = $false
    }
    mixers                = 0
    sync                  = 0
    flags                 = 0
    volume                = 1.0
    balance               = 0.5
    enabled               = $true
    muted                 = $true
    'push-to-mute'        = $false
    'push-to-mute-delay'  = 0
    'push-to-talk'        = $false
    'push-to-talk-delay'  = 0
    hotkeys               = @{}
    deinterlace_mode      = 0
    deinterlace_field_order = 0
    monitoring_type       = 0
    monitoring_enabled    = $false
    private_settings      = @{}
}

# 场景项：bounds_type=2（缩放到内边框），align=5（居中），保证任意比例视频不出镜不拉伸
$sceneItem = [ordered]@{
    name               = '本地视频'
    source_uuid        = $srcUuid
    visible            = $true
    locked             = $false
    rot                = 0.0
    pos                = [ordered]@{ x = 0.0; y = 0.0 }
    scale              = [ordered]@{ x = 1.0; y = 1.0 }
    align              = 5
    bounds_type        = 2
    bounds_align       = 0
    bounds             = [ordered]@{ x = [double]$W; y = [double]$H }
    crop_left          = 0
    crop_top           = 0
    crop_right         = 0
    crop_bottom        = 0
    id                 = 1
    group_item_backup  = $false
    scale_filter       = 'disable'
    blend_method       = 'default'
    blend_type         = 'normal'
    show_transition    = [ordered]@{ duration = 0 }
    hide_transition    = [ordered]@{ duration = 0 }
    private_settings   = @{}
}

$windowItem = ($sceneItem | ConvertTo-Json -Depth 8) | ConvertFrom-Json
$windowItem.name = '窗口捕获'
$windowItem.source_uuid = $windowUuid
$windowItem.visible = $false
$windowItem.id = 2

$sceneSource = [ordered]@{
    prev_ver                = 553648129
    name                    = '场景'
    uuid                    = $sceneUuid
    id                      = 'scene'
    versioned_id            = 'scene'
    settings                = [ordered]@{
        id_counter     = 2
        custom_size    = $false
        items          = @($sceneItem, $windowItem)
    }
    mixers                  = 0
    sync                    = 0
    flags                   = 0
    volume                  = 1.0
    balance                 = 0.5
    enabled                 = $true
    muted                   = $false
    'push-to-mute'          = $false
    'push-to-mute-delay'    = 0
    'push-to-talk'          = $false
    'push-to-talk-delay'    = 0
    hotkeys                 = [ordered]@{ 'OBSBasic.SelectScene' = @() }
    deinterlace_mode        = 0
    deinterlace_field_order = 0
    monitoring_type         = 0
    monitoring_enabled      = $false
    canvas_uuid             = '6c69626f-6273-4c00-9d88-c5136d61696e'
    private_settings        = @{}
}

$collection = [ordered]@{
    name                  = $sceneName
    sources               = @($sceneSource, $mediaSource, $windowSource)
    groups                = @()
    scene_order           = @([ordered]@{ name = '场景' })
    current_scene         = '场景'
    current_program_scene = '场景'
    canvases              = @()
    current_transition    = '直接切换'
    transition_duration   = 300
    transitions           = @()
    quick_transitions     = @(
        [ordered]@{ name = '直接切换'; duration = 300; hotkeys = @(); id = 1; fade_to_black = $false }
    )
    saved_projectors      = @()
    preview_locked        = $false
    scaling_enabled       = $false
    scaling_level         = 0
    scaling_off_x         = 0.0
    scaling_off_y         = 0.0
    modules               = [ordered]@{
        'scripts-tool'       = @()
        'auto-scene-switcher' = [ordered]@{ interval = 300; non_matching_scene = ''; switch_if_not_matching = $false; active = $false; switches = @() }
        captions             = [ordered]@{ source = ''; enabled = $false; lang_id = 2052; provider = 'mssapi' }
    }
    version               = 2
}

$json = $collection | ConvertTo-Json -Depth 32
Write-Utf8NoBom -Path (Join-Path $sceneDir "$sceneName.json") -Text $json

"OK  profile : $profDir"
"OK  scene   : $(Join-Path $sceneDir "$sceneName.json")"
"OK  video   : $video"
"OK  canvas  : ${W}x${H} @ ${fps}fps"
