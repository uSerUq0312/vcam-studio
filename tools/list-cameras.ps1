#requires -Version 5.1
<#
  用 Media Foundation 的原生枚举接口（MFEnumDeviceSources）列出摄像头设备。
  微信 4.x 的 VoipEngine.dll 里能查到 MFStartup，采集走 MF，所以这份列表最接近微信看到的结果。
  同时给出 DirectShow 枚举结果做对照。
#>
[CmdletBinding()]
param([switch]$DirectShowOnly)

if (-not $DirectShowOnly) {
    $cs = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class MFCam
{
    [DllImport("mfplat.dll", ExactSpelling = true)]
    public static extern int MFStartup(int version, int flags);
    [DllImport("mfplat.dll", ExactSpelling = true)]
    public static extern int MFShutdown();
    [DllImport("mfplat.dll", ExactSpelling = true)]
    public static extern int MFCreateAttributes(out IMFAttributes pp, int cInitialSize);
    // 注意：MFEnumDeviceSources 在 mf.dll，不在 mfplat.dll（MSG 说 mfplat 是错的，实测 mfplat 里没有这个导出）
    [DllImport("mf.dll", ExactSpelling = true)]
    public static extern int MFEnumDeviceSources(IMFAttributes pAttributes, out IntPtr pppDevices, out int pcDevices);

    [ComImport, Guid("2cd2d921-c447-44a7-a13c-4adabfc247e3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFAttributes
    {
        int GetItem(ref Guid key, IntPtr pValue);
        int GetItemType(ref Guid key, out int pType);
        int CompareItem(ref Guid key, IntPtr value, out bool pbResult);
        int Compare(IMFAttributes pTheirs, int matchType, out bool pbResult);
        int GetUINT32(ref Guid key, out int punValue);
        int GetUINT64(ref Guid key, out long punValue);
        int GetDouble(ref Guid key, out double pfValue);
        int GetGUID(ref Guid key, out Guid pguidValue);
        int GetStringLength(ref Guid key, out int pcchLength);
        int GetString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] StringBuilder pwszValue, int cchBufSize, IntPtr pcchLength);
        int GetAllocatedString(ref Guid key, out IntPtr ppwszValue, out int pcchLength);
        int GetBlobSize(ref Guid key, out int pcbBlobSize);
        int GetBlob(ref Guid key, IntPtr pBlob, int cbBufSize, IntPtr pcbBlobSize);
        int GetAllocatedBlob(ref Guid key, out IntPtr ppBuf, out int pcbSize);
        int GetUnknown(ref Guid key, ref Guid riid, out IntPtr ppv);
        int SetItem(ref Guid key, IntPtr value);
        int DeleteItem(ref Guid key);
        int DeleteAllItems();
        int SetUINT32(ref Guid key, int unValue);
        int SetUINT64(ref Guid key, long unValue);
        int SetDouble(ref Guid key, double fValue);
        int SetGUID(ref Guid key, ref Guid guidValue);
        int SetString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] string wszValue);
        int SetBlob(ref Guid key, IntPtr pBuf, int cbBufSize);
        int SetUnknown(ref Guid key, [MarshalAs(UnmanagedType.IUnknown)] object pUnk);
        int LockStore();
        int UnlockStore();
        int GetCount(out int pcItems);
        int GetItemByIndex(int unIndex, out Guid pguidKey, IntPtr pValue);
        int CopyAllItems(IMFAttributes pDest);
    }

    public static string[] List(string srcTypeGuid, string vidcapGuid, string friendlyGuid, int videoServiceVersion)
    {
        var list = new List<string>();
        int hr = MFStartup(videoServiceVersion, 0);
        if (hr != 0) { list.Add("MFStartup failed hr=0x" + hr.ToString("X8")); return list.ToArray(); }
        try
        {
            IMFAttributes attrs;
            hr = MFCreateAttributes(out attrs, 1);
            if (hr != 0) { list.Add("MFCreateAttributes failed hr=0x" + hr.ToString("X8")); return list.ToArray(); }

            Guid kType = new Guid(srcTypeGuid);
            Guid vType = new Guid(vidcapGuid);
            hr = attrs.SetGUID(ref kType, ref vType);
            if (hr != 0) { list.Add("SetGUID failed hr=0x" + hr.ToString("X8")); return list.ToArray(); }

            IntPtr devices;
            int count;
            hr = MFEnumDeviceSources(attrs, out devices, out count);
            if (hr != 0) { list.Add("MFEnumDeviceSources failed hr=0x" + hr.ToString("X8")); return list.ToArray(); }

            list.Add("MF 枚举到 " + count + " 个视频采集设备：");
            Guid kFriendly = new Guid(friendlyGuid);
            for (int i = 0; i < count; i++)
            {
                IntPtr pActivate = Marshal.ReadIntPtr(devices, i * IntPtr.Size);
                object o = Marshal.GetObjectForIUnknown(pActivate);
                var a = (IMFAttributes)o;
                var sb = new StringBuilder(512);
                string name;
                try
                {
                    a.GetString(ref kFriendly, sb, sb.Capacity, IntPtr.Zero);
                    name = sb.ToString();
                }
                catch (Exception ex)
                {
                    int code = Marshal.GetHRForException(ex);
                    name = "<no friendly name hr=0x" + code.ToString("X8") + ">";
                }
                list.Add("  [" + i + "] " + name);
                Marshal.Release(pActivate);
            }
            int n2;
            attrs.GetCount(out n2);
        }
        finally { MFShutdown(); }
        return list.ToArray();
    }
}
'@
    try {
        Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop
        # MF_VERSION for Win10/11 = 0x00020070 ; 若失败退回 0x00020000
        $out = [MFCam]::List('c60ac5fe-252a-478f-a0ef-bc8fa5f7cad3',
                             '8ac3587a-4ae7-42d8-99e0-0a6013eef90f',
                             '60d0e559-52f8-4fa2-bce8-acdbecce34ec', 0x00020070)
        if ($out[0] -like 'MFStartup failed*') {
            $out = [MFCam]::List('c60ac5fe-252a-478f-a0ef-bc8fa5f7cad3',
                                 '8ac3587a-4ae7-42d8-99e0-0a6013eef90f',
                                 '60d0e559-52f8-4fa2-bce8-acdbecce34ec', 0x00020000)
        }
        $out | ForEach-Object { $_ }
    } catch {
        "MF 枚举失败（编译或运行错误）：" + $_.Exception.Message
    }
}

"--- DirectShow 枚举（供对照）---"
$ff = 'D:\dev\tools\ffmpeg\bin\ffmpeg.exe'
if (Test-Path $ff) {
    & $ff -hide_banner -list_devices true -f dshow -i dummy 2>&1 |
        Where-Object { $_ -match '" \(' } |
        ForEach-Object { ($_ -replace '^\[[^\]]*\]\s*', '') }
} else {
    'ffmpeg 不在 D:\dev\tools\ffmpeg\bin\ffmpeg.exe'
}
