#requires -Version 5.1
<#
  Media Foundation 端到端采集测试 —— 复刻微信 4.x（Weixin.dll 里能查到 MFEnumDeviceSources）
  枚举摄像头的完整调用链：
      MFEnumDeviceSources -> IMFActivate::ActivateObject -> MFCreateSourceReaderFromMediaSource -> ReadSample

  对每个枚举到的设备抓一帧存成 BMP，从而回答一个关键问题：
  微信走 MF 时，到底能不能看到 OBS 注册的虚拟摄像头？
#>
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path $PSScriptRoot '..\_mf-test')
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$cs = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class MFProbe
{
    [DllImport("mfplat.dll", ExactSpelling = true)] public static extern int MFStartup(int version, int flags);
    [DllImport("mfplat.dll", ExactSpelling = true)] public static extern int MFShutdown();
    [DllImport("mfplat.dll", ExactSpelling = true)] public static extern int MFCreateAttributes(out IMFAttributes pp, int cInitialSize);
    [DllImport("mf.dll", ExactSpelling = true)] public static extern int MFEnumDeviceSources(IMFAttributes pAttributes, out IntPtr pppDevices, out int pcDevices);
    [DllImport("mfreadwrite.dll", ExactSpelling = true)] public static extern int MFCreateSourceReaderFromMediaSource(IMFMediaSource pSource, IMFAttributes pAttributes, out IMFSourceReader ppReader);

    [ComImport, Guid("2cd2d921-c447-44a7-a13c-4adabfc247e3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFAttributes
    {
        [PreserveSig] int GetItem(ref Guid key, IntPtr pValue);
        [PreserveSig] int GetItemType(ref Guid key, out int pType);
        [PreserveSig] int CompareItem(ref Guid key, IntPtr value, out bool pbResult);
        [PreserveSig] int Compare(IMFAttributes pTheirs, int matchType, out bool pbResult);
        [PreserveSig] int GetUINT32(ref Guid key, out int punValue);
        [PreserveSig] int GetUINT64(ref Guid key, out long punValue);
        [PreserveSig] int GetDouble(ref Guid key, out double pfValue);
        [PreserveSig] int GetGUID(ref Guid key, out Guid pguidValue);
        [PreserveSig] int GetStringLength(ref Guid key, out int pcchLength);
        [PreserveSig] int GetString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] StringBuilder pwszValue, int cchBufSize, IntPtr pcchLength);
        [PreserveSig] int GetAllocatedString(ref Guid key, out IntPtr ppwszValue, out int pcchLength);
        [PreserveSig] int GetBlobSize(ref Guid key, out int pcbBlobSize);
        [PreserveSig] int GetBlob(ref Guid key, IntPtr pBlob, int cbBufSize, IntPtr pcbBlobSize);
        [PreserveSig] int GetAllocatedBlob(ref Guid key, out IntPtr ppBuf, out int pcbSize);
        [PreserveSig] int GetUnknown(ref Guid key, ref Guid riid, out IntPtr ppv);
        [PreserveSig] int SetItem(ref Guid key, IntPtr value);
        [PreserveSig] int DeleteItem(ref Guid key);
        [PreserveSig] int DeleteAllItems();
        [PreserveSig] int SetUINT32(ref Guid key, int unValue);
        [PreserveSig] int SetUINT64(ref Guid key, long unValue);
        [PreserveSig] int SetDouble(ref Guid key, double fValue);
        [PreserveSig] int SetGUID(ref Guid key, ref Guid guidValue);
        [PreserveSig] int SetString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] string wszValue);
        [PreserveSig] int SetBlob(ref Guid key, IntPtr pBuf, int cbBufSize);
        [PreserveSig] int SetUnknown(ref Guid key, [MarshalAs(UnmanagedType.IUnknown)] object pUnk);
        [PreserveSig] int LockStore();
        [PreserveSig] int UnlockStore();
        [PreserveSig] int GetCount(out int pcItems);
        [PreserveSig] int GetItemByIndex(int unIndex, out Guid pguidKey, IntPtr pValue);
        [PreserveSig] int CopyAllItems(IMFAttributes pDest);
    }

    [ComImport, Guid("7fee9e9a-4a89-47a6-899c-b6a53a70fb67"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFActivate : IMFAttributes
    {
        [PreserveSig] int ActivateObject(ref Guid riid, out IntPtr ppv);
        [PreserveSig] int ShutdownObject();
        [PreserveSig] int DetachObject();
    }

    [ComImport, Guid("279a808d-aec7-40c8-9c6b-a6b492c78a66"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFMediaSource
    {
        [PreserveSig] int GetCharacteristics(out int pdwCharacteristics);
        [PreserveSig] int CreatePresentationDescriptor(out IntPtr ppPresentationDescriptor);
        [PreserveSig] int Start(IntPtr pPresentationDescriptor, IntPtr pguidTimeFormat, IntPtr pvarStartPosition);
        [PreserveSig] int Stop();
        [PreserveSig] int Pause();
        [PreserveSig] int Shutdown();
    }

    [ComImport, Guid("70ae66f2-c809-4e4f-8915-bdcb406b7993"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFSourceReader
    {
        [PreserveSig] int GetStreamSelection(int dwStreamIndex, out int pfSelected);
        [PreserveSig] int SetStreamSelection(int dwStreamIndex, bool fSelected);
        [PreserveSig] int GetNativeMediaType(int dwStreamIndex, int dwMediaTypeIndex, out IntPtr ppMediaType);
        [PreserveSig] int GetCurrentMediaType(int dwStreamIndex, out IntPtr ppMediaType);
        [PreserveSig] int SetCurrentMediaType(int dwStreamIndex, IntPtr pdwReserved, IMFAttributes pMediaType);
        [PreserveSig] int SetCurrentPosition(ref Guid guidTimeFormat, IntPtr pvarPosition);
        [PreserveSig] int ReadSample(int dwStreamIndex, int dwControlFlags, out int pdwActualStreamIndex, out int pdwStreamFlags, out long pllTimestamp, out IntPtr ppSample);
        [PreserveSig] int Flush(int dwStreamIndex);
        [PreserveSig] int GetServiceForStream(int dwStreamIndex, ref Guid guidService, ref Guid riid, out IntPtr ppvObject);
        [PreserveSig] int GetPresentationAttribute(int dwStreamIndex, ref Guid guidAttribute, out IntPtr ppvarAttribute);
    }

    [ComImport, Guid("c40a00f2-b93a-4d80-ae8c-5a1c634f58e4"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFSample
    {
        [PreserveSig] int GetSampleFlags(out int pdwSampleFlags);
        [PreserveSig] int SetSampleFlags(int dwSampleFlags);
        [PreserveSig] int GetSampleTime(out long phnsSampleTime);
        [PreserveSig] int SetSampleTime(long hnsSampleTime);
        [PreserveSig] int GetSampleDuration(out long phnsSampleDuration);
        [PreserveSig] int SetSampleDuration(long hnsSampleDuration);
        [PreserveSig] int GetBufferCount(out int pdwBufferCount);
        [PreserveSig] int GetBufferByIndex(int dwIndex, out IMFMediaBuffer ppBuffer);
        [PreserveSig] int ConvertToContiguousBuffer(out IMFMediaBuffer ppBuffer);
        [PreserveSig] int AddBuffer(IMFMediaBuffer pBuffer);
        [PreserveSig] int RemoveBufferByIndex(int dwIndex);
        [PreserveSig] int RemoveAllBuffers();
        [PreserveSig] int GetTotalLength(out int pcbTotalLength);
        [PreserveSig] int CopyToBuffer(IMFMediaBuffer pBuffer, IntPtr pcbData, int cbData);
    }

    [ComImport, Guid("045fa593-8799-42b8-bc8d-8968c6453507"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFMediaBuffer
    {
        [PreserveSig] int Lock(out IntPtr ppbBuffer, out int pcbMaxLength, out int pcbCurrentLength);
        [PreserveSig] int Unlock();
        [PreserveSig] int GetCurrentLength(out int pcbCurrentLength);
        [PreserveSig] int SetCurrentLength(int cbCurrentLength);
        [PreserveSig] int GetMaxLength(out int pcbMaxLength);
    }

    static readonly Guid MF_MT_MAJOR_TYPE = new Guid("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    static readonly Guid MF_MT_SUBTYPE    = new Guid("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    static readonly Guid MF_MT_FRAME_SIZE = new Guid("1652c33d-d6b2-4012-b834-72030849a37d");
    static readonly Guid MEDIATYPE_Video  = new Guid("73646976-0000-0010-8000-00AA00389B71");
    static readonly Guid MFVideoFormat_RGB32 = new Guid("00000016-0000-0010-8000-00AA00389B71");
    static readonly Guid IID_IMFMediaSource = new Guid("279a808d-aec7-40c8-9c6b-a6b492c78a66");
    static readonly Guid MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME = new Guid("60d0e559-52f8-4fa2-bce8-acdbecce34ec");
    static readonly Guid MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE = new Guid("c60ac5fe-252a-478f-a0ef-bc8fa5f7cad3");
    static readonly Guid MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID = new Guid("8ac3587a-4ae7-42d8-99e0-0a6013eef90f");
    const int MF_SOURCE_READER_FIRST_VIDEO_STREAM = unchecked((int)0xFFFFFFFC);

    public static string[] Run(string outDir)
    {
        var log = new List<string>();
        int hr = MFStartup(0x00020070, 0);
        if (hr != 0) { log.Add("MFStartup failed 0x" + hr.ToString("X8")); return log.ToArray(); }
        try
        {
            IMFAttributes attrs;
            MFCreateAttributes(out attrs, 1);
            Guid k = MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, v = MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID;
            attrs.SetGUID(ref k, ref v);

            IntPtr arr; int count;
            hr = MFEnumDeviceSources(attrs, out arr, out count);
            if (hr != 0) { log.Add("MFEnumDeviceSources failed 0x" + hr.ToString("X8")); return log.ToArray(); }
            log.Add("MFEnumDeviceSources 返回 " + count + " 个设备");

            for (int i = 0; i < count; i++)
            {
                IntPtr pUnk = Marshal.ReadIntPtr(arr, i * IntPtr.Size);
                object o = Marshal.GetObjectForIUnknown(pUnk);
                var act = (IMFActivate)o;

                string name = "(no name)";
                var sb = new StringBuilder(512);
                Guid kf = MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME;
                try { if (act.GetString(ref kf, sb, 512, IntPtr.Zero) == 0) name = sb.ToString(); } catch { }

                log.Add("[" + i + "] " + name);
                try
                {
                    Guid iid = IID_IMFMediaSource;
                    IntPtr pSrc;
                    hr = act.ActivateObject(ref iid, out pSrc);
                    if (hr != 0) { log.Add("    ActivateObject 0x" + hr.ToString("X8")); Marshal.Release(pUnk); continue; }
                    var src = (IMFMediaSource)Marshal.GetObjectForIUnknown(pSrc);

                    IMFSourceReader reader;
                    hr = MFCreateSourceReaderFromMediaSource(src, null, out reader);
                    if (hr != 0) { log.Add("    MFCreateSourceReaderFromMediaSource 0x" + hr.ToString("X8")); Marshal.Release(pSrc); Marshal.Release(pUnk); continue; }

                    IMFAttributes mt;
                    MFCreateAttributes(out mt, 1);
                    Guid kmt = MF_MT_MAJOR_TYPE, vmt = MEDIATYPE_Video;
                    mt.SetGUID(ref kmt, ref vmt);
                    Guid kst = MF_MT_SUBTYPE, vst = MFVideoFormat_RGB32;
                    mt.SetGUID(ref kst, ref vst);
                    hr = reader.SetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, IntPtr.Zero, mt);
                    if (hr != 0) { log.Add("    SetCurrentMediaType(RGB32) 0x" + hr.ToString("X8")); Marshal.Release(pSrc); Marshal.Release(pUnk); continue; }

                    int w = 0, h = 0;
                    IntPtr pMt;
                    if (reader.GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, out pMt) == 0 && pMt != IntPtr.Zero)
                    {
                        var cmt = (IMFAttributes)Marshal.GetObjectForIUnknown(pMt);
                        long fs;
                        Guid kfs = MF_MT_FRAME_SIZE;
                        if (cmt.GetUINT64(ref kfs, out fs) == 0) { w = (int)(fs >> 32); h = (int)(fs & 0xFFFFFFFF); }
                        Marshal.Release(pMt);
                    }

                    int idx, flags; long ts; IntPtr pSample;
                    hr = reader.ReadSample(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, out idx, out flags, out ts, out pSample);
                    if (hr != 0 || pSample == IntPtr.Zero) { log.Add("    ReadSample hr=0x" + hr.ToString("X8") + " sample=" + (pSample == IntPtr.Zero ? "null" : "ok")); Marshal.Release(pSrc); Marshal.Release(pUnk); continue; }

                    var sample = (IMFSample)Marshal.GetObjectForIUnknown(pSample);
                    IMFMediaBuffer buf;
                    if (sample.ConvertToContiguousBuffer(out buf) == 0)
                    {
                        IntPtr pData; int maxLen, curLen;
                        if (buf.Lock(out pData, out maxLen, out curLen) == 0)
                        {
                            if (w <= 0 || h <= 0) { w = 1280; h = 720; }
                            byte[] data = new byte[curLen];
                            Marshal.Copy(pData, data, 0, curLen);
                            buf.Unlock();
                            string bmp = Path.Combine(outDir, "dev" + i + "_" + w + "x" + h + ".bmp");
                            WriteBmp(bmp, data, w, h);
                            log.Add("    抓帧成功 " + w + "x" + h + " bytes=" + curLen + " -> " + Path.GetFileName(bmp));
                        }
                        Marshal.Release(Marshal.GetIUnknownForObject(buf));
                    }
                    Marshal.Release(pSample);
                    Marshal.Release(pSrc);
                }
                catch (Exception ex) { log.Add("    异常: " + ex.Message); }
                Marshal.Release(pUnk);
            }
        }
        finally { MFShutdown(); }
        return log.ToArray();
    }

    static void WriteBmp(string path, byte[] data, int w, int h)
    {
        int stride = w * 4;
        int rowBytes = Math.Min(stride, data.Length);
        using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write))
        using (var bw = new BinaryWriter(fs))
        {
            int imgSize = stride * h;
            bw.Write((byte)'B'); bw.Write((byte)'M');
            bw.Write(54 + imgSize); bw.Write(0);
            bw.Write(54);
            bw.Write(40); bw.Write(w); bw.Write(h);
            bw.Write((short)1); bw.Write((short)32);
            bw.Write(0); bw.Write(imgSize);
            bw.Write(2835); bw.Write(2835);
            bw.Write(0); bw.Write(0);
            byte[] row = new byte[stride];
            for (int y = h - 1; y >= 0; y--)
            {
                Array.Clear(row, 0, stride);
                int off = y * stride;
                if (off + stride <= data.Length) Array.Copy(data, off, row, 0, stride);
                bw.Write(row);
            }
        }
    }
}
'@

Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop
[MFProbe]::Run($OutDir) | ForEach-Object { $_ }
"--- 输出目录 ---"
Get-ChildItem $OutDir | ForEach-Object { $_.FullName + "  " + $_.Length + "B" }
