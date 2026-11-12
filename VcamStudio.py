#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VcamStudio —— 虚拟摄像头面板（GUI）

功能：
  · 指定本地 mp4（可循环）或指定窗口（句柄/标题）作为摄像头画面
  · 一键启停虚拟摄像头（后端是 OBS 便携版，通过 obs-websocket 控制）
  · 全局热键切源 / 开关，微信在前台也不抢焦点
  · 状态栏实时显示 OBS 连接、虚拟摄像头、当前源

用法：
  python VcamStudio.py            # 打开图形界面
  python VcamStudio.py --selftest # 无界面自检（连 OBS、设片源、抓帧验证）

依赖：PyQt5、OBS 便携版（D:\\dev\\OBS）、ffmpeg/ffprobe（D:\\dev\\tools\\ffmpeg\\bin）
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid

PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))

# 路径都可用环境变量覆盖，不设就用下面的默认值
OBS_ROOT = os.environ.get("VCAM_OBS_ROOT", r"D:\dev\OBS")
FFMPEG_DIR = os.environ.get("VCAM_FFMPEG_DIR", r"D:\dev\tools\ffmpeg\bin")
OBS_EXE = os.path.join(OBS_ROOT, "bin", "64bit", "obs64.exe")
OBS_WORKDIR = os.path.join(OBS_ROOT, "bin", "64bit")
OBS_CFG = os.path.join(OBS_ROOT, "config", "obs-studio")
WS_CFG = os.path.join(OBS_CFG, "plugin_config", "obs-websocket", "config.json")
FFMPEG = os.path.join(FFMPEG_DIR, "ffmpeg.exe")
FFPROBE = os.path.join(FFMPEG_DIR, "ffprobe.exe")
CONFIG_JSON = os.path.join(PROJECT_DIR, "config.json")

SCENE = "场景"
SRC_VIDEO = "本地视频"
SRC_WINDOW = "窗口捕获"


# ----------------------------------------------------------------------------- WebSocket
class WS:
    """最小 WebSocket 客户端（RFC6455 文本帧，够 obs-websocket 用，不引第三方库）"""

    def __init__(self, host="127.0.0.1", port=4455, timeout=6.0):
        self.host, self.port, self.timeout = host, port, timeout
        self.sock = None
        self._buf = b""

    def connect(self):
        self.sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            f"GET / HTTP/1.1\r\nHost: {self.host}:{self.port}\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(req.encode())
        # 读 HTTP 响应头
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("WebSocket 握手失败")
            head += chunk
        hdr, _, rest = head.partition(b"\r\n\r\n")
        if b"101" not in hdr.split(b"\r\n")[0]:
            raise ConnectionError("WebSocket 握手被拒: " + hdr.decode("latin1"))
        self._buf = rest
        return self

    # ---- 帧 ----
    def _send_frame(self, payload: bytes, opcode: int = 0x1):
        header = bytearray([0x80 | opcode])
        mask = os.urandom(4)
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < (1 << 16):
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        header += mask
        masked = bytearray(payload)
        for i in range(n):
            masked[i] ^= mask[i & 3]
        self.sock.sendall(bytes(header) + bytes(masked))

    def _read_exact(self, n: int) -> bytes:
        while len(self._buf) < n:
            chunk = self.sock.recv(max(4096, n - len(self._buf)))
            if not chunk:
                raise ConnectionError("连接被关闭")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def recv_message(self) -> bytes:
        while True:
            b0, b1 = self._read_exact(2)
            opcode = b0 & 0x0F
            masked = b1 & 0x80
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read_exact(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read_exact(8))[0]
            mask = self._read_exact(4) if masked else None
            data = self._read_exact(n) if n else b""
            if mask:
                data = bytes(data[i] ^ mask[i & 3] for i in range(len(data)))
            if opcode == 0x9:                      # ping
                self._send_frame(data, 0xA)
                continue
            if opcode == 0xA:                      # pong
                continue
            if opcode == 0x8:                      # close
                raise ConnectionError("服务端关闭连接")
            return data

    def send_json(self, obj):
        self._send_frame(json.dumps(obj).encode("utf-8"))

    def recv_json(self):
        return json.loads(self.recv_message().decode("utf-8"))

    def close(self):
        try:
            self._send_frame(b"", 0x8)
        except Exception:
            pass
        try:
            self.sock.close()
        except Exception:
            pass


# ----------------------------------------------------------------------------- OBS 控制
class ObsError(RuntimeError):
    pass


class Obs:
    def __init__(self, password=None):
        self.password = password or self._load_password()
        self.ws: WS | None = None
        self.version = ""

    # ---- 配置 ----
    @staticmethod
    def _load_password() -> str:
        try:
            with open(WS_CFG, encoding="utf-8") as f:
                return json.load(f).get("server_password", "") or ""
        except Exception:
            return ""

    @staticmethod
    def ensure_websocket_enabled() -> bool:
        """obs-websocket 默认关闭，写配置打开。返回是否改动过。"""
        try:
            with open(WS_CFG, encoding="utf-8") as f:
                cfg = json.load(f)
        except Exception:
            return False
        if cfg.get("server_enabled"):
            return False
        cfg["server_enabled"] = True
        cfg.setdefault("server_port", 4455)
        cfg.setdefault("auth_required", True)
        os.makedirs(os.path.dirname(WS_CFG), exist_ok=True)
        with open(WS_CFG, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
        return True

    # ---- 进程 ----
    @staticmethod
    def is_running() -> bool:
        out = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq obs64.exe", "/NH"],
            capture_output=True, text=True, creationflags=0x08000000,
        ).stdout
        return "obs64.exe" in out

    @staticmethod
    def start(wait=40) -> bool:
        if Obs.is_running():
            return True
        if not os.path.exists(OBS_EXE):
            raise ObsError(f"找不到 OBS：{OBS_EXE}（先跑 1-安装OBS.bat）")
        sentinel = os.path.join(OBS_CFG, ".sentinel")
        if os.path.isdir(sentinel):
            subprocess.run(["cmd", "/c", "rmdir", "/s", "/q", sentinel],
                           capture_output=True, creationflags=0x08000000)
        subprocess.Popen(
            [OBS_EXE, "--portable", "--collection", "VcamTool", "--profile", "VcamTool",
             "--minimize-to-tray"],
            cwd=OBS_WORKDIR, close_fds=True,
        )
        t0 = time.time()
        while time.time() - t0 < wait:
            if Obs.is_running():
                return True
            time.sleep(0.5)
        return False

    @staticmethod
    def stop():
        subprocess.run(["taskkill", "/IM", "obs64.exe"], capture_output=True,
                       creationflags=0x08000000)
        time.sleep(2)
        sentinel = os.path.join(OBS_CFG, ".sentinel")
        if os.path.isdir(sentinel):
            subprocess.run(["cmd", "/c", "rmdir", "/s", "/q", sentinel],
                           capture_output=True, creationflags=0x08000000)

    # ---- 连接 ----
    def connect(self, retries=20, delay=0.7):
        last = None
        for _ in range(retries):
            try:
                self.ws = WS().connect()
                hello = self.ws.recv_json()
                ident = {"rpcVersion": 1}
                auth = hello.get("d", {}).get("authentication")
                if auth:
                    secret = base64.b64encode(
                        hashlib.sha256((self.password + auth["salt"]).encode()).digest()
                    ).decode()
                    ident["authentication"] = base64.b64encode(
                        hashlib.sha256((secret + auth["challenge"]).encode()).digest()
                    ).decode()
                self.ws.send_json({"op": 1, "d": ident})
                while True:
                    msg = self.ws.recv_json()
                    if msg.get("op") == 2:
                        break
                self.version = self.request("GetVersion").get("obsVersion", "")
                return self
            except Exception as e:      # noqa: BLE001
                last = e
                time.sleep(delay)
        raise ObsError(f"连不上 obs-websocket(4455)：{last}")

    def close(self):
        if self.ws:
            self.ws.close()
            self.ws = None

    def request(self, rtype, data=None):
        if not self.ws:
            raise ObsError("未连接")
        rid = str(uuid.uuid4())
        self.ws.send_json({"op": 6, "d": {"requestType": rtype, "requestId": rid,
                                          "requestData": data or {}}})
        while True:
            msg = self.ws.recv_json()
            if msg.get("op") != 7:
                continue                        # 事件帧，跳过
            d = msg.get("d", {})
            if d.get("requestId") != rid:
                continue
            st = d.get("requestStatus", {})
            if not st.get("result"):
                raise ObsError(f"{rtype} 失败: {st.get('code')} {st.get('comment')}")
            return d.get("responseData", {}) or {}

    # ---- 高层操作 ----
    def vcam_status(self) -> bool:
        return bool(self.request("GetVirtualCamStatus").get("outputActive"))

    def vcam(self, on: bool):
        self.request("StartVirtualCam" if on else "StopVirtualCam")

    def set_video(self, canvas=None, fps=None):
        """设置画布（base/output 同尺寸）。OBS 规定输出运行中不能改画布，所以自动停-改-起。"""
        data = {}
        if canvas:
            w, h = canvas
            data.update(baseWidth=w, baseHeight=h, outputWidth=w, outputHeight=h)
        if fps:
            data.update(fpsNumerator=int(fps), fpsDenominator=1)
        if not data:
            return
        was = self.vcam_status()
        if was:
            self.vcam(False)
            for _ in range(24):                 # OBS 停下不是瞬时的，要等输出真关掉
                if not self.vcam_status():
                    break
                time.sleep(0.125)
        try:
            self.request("SetVideoSettings", data)
        finally:
            if was:
                time.sleep(0.3)
                self.vcam(True)

    def media_settings(self, **kw):
        self.request("SetInputSettings", {"inputName": SRC_VIDEO, "inputSettings": kw,
                                          "overlay": True})

    def window_items(self):
        """OBS 提供的可捕获窗口列表（拿 itemValue 直接回填最稳，绕开本地化格式差异）"""
        r = self.request("GetInputPropertiesListPropertyItems",
                         {"inputName": SRC_WINDOW, "propertyName": "window"})
        return [(i.get("itemName", ""), i.get("itemValue", ""))
                for i in r.get("propertyItems", [])]

    def set_window(self, item_value: str):
        self.request("SetInputSettings", {
            "inputName": SRC_WINDOW,
            "inputSettings": {"window": item_value, "method": 2,
                              "capture_mode": "window", "cursor": False},
            "overlay": True,
        })

    def scene_item_id(self, source: str) -> int | None:
        try:
            r = self.request("GetSceneItemId", {"sceneName": SCENE, "sourceName": source})
            return int(r.get("sceneItemId"))
        except ObsError:
            return None

    def show_source(self, source: str, visible: bool):
        sid = self.scene_item_id(source)
        if sid is None:
            return
        self.request("SetSceneItemEnabled",
                     {"sceneName": SCENE, "sceneItemId": sid, "sceneItemEnabled": visible})


# ----------------------------------------------------------------------------- 工具
def probe_video(path: str):
    if not os.path.exists(FFPROBE):
        return None
    try:
        out = subprocess.run(
            [FFPROBE, "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=width,height,r_frame_rate", "-of", "csv=p=0", path],
            capture_output=True, text=True, timeout=15,
        ).stdout.strip().split(",")
        w, h = int(out[0]), int(out[1])
        fps = 30
        if len(out) > 2 and "/" in out[2]:
            n, d = out[2].split("/")
            fps = round(int(n) / max(1, int(d)))
        return w, h, max(5, min(60, fps))
    except Exception:
        return None


def fit_canvas(w, h, long_side=1280):
    if w <= 0 or h <= 0:
        return 1280, 720
    s = min(1.0, long_side / max(w, h))
    return (int(round(w * s / 2) * 2), int(round(h * s / 2) * 2))


def grab_frame(png_path, timeout=12):
    """从 OBS Virtual Camera 抓一帧，验证真的在出画面"""
    if os.path.exists(png_path):
        os.remove(png_path)
    try:
        subprocess.run(
            [FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-f", "dshow",
             "-rtbufsize", "256M", "-i", "video=OBS Virtual Camera",
             "-frames:v", "1", "-update", "1", png_path],
            capture_output=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return None
    return png_path if os.path.exists(png_path) else None


def frame_is_black(png_path: str) -> bool:
    try:
        import numpy as np
        from PIL import Image
        a = np.asarray(Image.open(png_path).convert("RGB"))
        return float(a.std()) < 3.0
    except Exception:
        return False


# ----------------------------------------------------------------------------- GUI
def run_gui():
    from PyQt5.QtCore import Qt, QTimer, QAbstractNativeEventFilter, pyqtSignal
    from PyQt5.QtWidgets import (QApplication, QWidget, QVBoxLayout, QHBoxLayout,
                                 QGridLayout, QGroupBox, QLineEdit, QPushButton,
                                 QCheckBox, QComboBox, QLabel, QRadioButton, QMessageBox,
                                 QFileDialog, QPlainTextEdit)

    import ctypes
    from ctypes import wintypes

    WM_HOTKEY = 0x0312
    HOTKEYS = {
        1: ("Ctrl+Alt+1", "切到 本地视频"),
        2: ("Ctrl+Alt+2", "切到 窗口捕获"),
        3: ("Ctrl+Alt+3", "开关虚拟摄像头"),
        4: ("Ctrl+Alt+4", "重播/重载视频"),
        5: ("Ctrl+Alt+5", "视频可见性翻转"),
    }
    MOD_ALT, MOD_CONTROL, MOD_NOREPEAT = 0x1, 0x2, 0x4000
    VK = {"1": 0x31, "2": 0x32, "3": 0x33, "4": 0x34, "5": 0x35}

    class HotkeyFilter(QAbstractNativeEventFilter):
        def __init__(self, cb):
            super().__init__()
            self.cb = cb

        def nativeEventFilter(self, etype, msg):
            try:
                m = ctypes.cast(int(msg), ctypes.POINTER(wintypes.MSG)).contents
                if m.message == WM_HOTKEY:
                    self.cb(int(m.wParam))
            except Exception:
                pass
            return False, 0

    class Studio(QWidget):
        sig_log = pyqtSignal(str)
        sig_windows = pyqtSignal(list)

        def __init__(self):
            super().__init__()
            self.setWindowTitle("VcamStudio · 虚拟摄像头面板")
            self.resize(760, 560)
            self.obs: Obs | None = None
            self.busy = threading.Lock()
            self._build_ui()
            self.sig_log.connect(self._on_log)
            self.sig_windows.connect(self._on_windows)
            self._install_hotkeys()
            QTimer.singleShot(200, self.bootstrap)

        # ---------- UI ----------
        def _build_ui(self):
            root = QVBoxLayout(self)

            g_src = QGroupBox("画面源")
            gl = QGridLayout(g_src)
            self.rb_video = QRadioButton("本地视频（循环）")
            self.rb_window = QRadioButton("指定窗口（句柄）")
            self.rb_video.setChecked(True)
            gl.addWidget(self.rb_video, 0, 0)
            gl.addWidget(self.rb_window, 0, 1)

            gl.addWidget(QLabel("视频文件"), 1, 0)
            self.ed_video = QLineEdit(self._cfg().get("videoFile", ""))
            gl.addWidget(self.ed_video, 1, 1, 1, 3)
            btn = QPushButton("浏览…")
            btn.clicked.connect(self.pick_video)
            gl.addWidget(btn, 1, 4)

            self.cb_loop = QCheckBox("循环播放")
            self.cb_loop.setChecked(True)
            gl.addWidget(self.cb_loop, 2, 0)
            self.cb_mute = QCheckBox("静音（不影响微信收音）")
            self.cb_mute.setChecked(True)
            gl.addWidget(self.cb_mute, 2, 1)

            gl.addWidget(QLabel("窗口"), 3, 0)
            self.cb_window = QComboBox()
            self.cb_window.setMinimumWidth(420)
            gl.addWidget(self.cb_window, 3, 1, 1, 3)
            btn_r = QPushButton("刷新窗口")
            btn_r.clicked.connect(lambda: self.refresh_windows(True))
            gl.addWidget(btn_r, 3, 4)
            root.addWidget(g_src)

            g_op = QGroupBox("操作")
            hl = QHBoxLayout(g_op)
            self.btn_apply = QPushButton("应用到 OBS")
            self.btn_apply.clicked.connect(self.apply_settings)
            self.btn_start = QPushButton("启动虚拟摄像头")
            self.btn_start.clicked.connect(lambda: self.toggle_vcam(True))
            self.btn_stop = QPushButton("停止")
            self.btn_stop.clicked.connect(lambda: self.toggle_vcam(False))
            self.btn_restart = QPushButton("重启 OBS")
            self.btn_restart.clicked.connect(self.restart_obs)
            for b in (self.btn_apply, self.btn_start, self.btn_stop, self.btn_restart):
                hl.addWidget(b)
            root.addWidget(g_op)

            g_hk = QGroupBox("全局热键（微信在前台也生效）")
            hl2 = QGridLayout(g_hk)
            for i, (hid, (k, desc)) in enumerate(HOTKEYS.items()):
                hl2.addWidget(QLabel(k), i // 2, (i % 2) * 2)
                hl2.addWidget(QLabel(desc), i // 2, (i % 2) * 2 + 1)
            root.addWidget(g_hk)

            self.log = QPlainTextEdit()
            self.log.setReadOnly(True)
            self.log.setMaximumBlockCount(500)
            root.addWidget(self.log, 1)

            self.status = QLabel("初始化…")
            root.addWidget(self.status)

        def _cfg(self):
            try:
                with open(CONFIG_JSON, encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                return {}

        def say(self, msg):
            self.sig_log.emit(msg)      # 线程安全：worker 线程里调用也没事

        def _on_log(self, msg):
            self.log.appendPlainText(f"[{time.strftime('%H:%M:%S')}] {msg}")
            self.status.setText(msg)

        def _on_windows(self, items):
            self.cb_window.clear()
            for name, val in items:
                self.cb_window.addItem(name, val)
            self.say(f"窗口列表 {len(items)} 个" +
                     ("" if items else "（独占/全屏窗口可能不出现，切窗口模式再刷新）"))

        # ---------- 热键 ----------
        def _install_hotkeys(self):
            user32 = ctypes.windll.user32
            self._hk_ok = True
            for hid, (combo, _desc) in HOTKEYS.items():
                vk = VK.get(combo[-1], 0)
                if not user32.RegisterHotKey(None, hid, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, vk):
                    self._hk_ok = False
            self._hk_filter = HotkeyFilter(self._on_hotkey)
            QApplication.instance().installNativeEventFilter(self._hk_filter)

        def _on_hotkey(self, hid):
            if hid == 1:
                self.rb_video.setChecked(True)
                self.use_video()
            elif hid == 2:
                self.rb_window.setChecked(True)
                self.use_window()
            elif hid == 3:
                self.toggle_vcam(None)
            elif hid == 4:
                self.media_kw(restart=True)
            elif hid == 5:
                self.toggle_video_visible()

        # ---------- OBS ----------
        def bootstrap(self):
            def work():
                try:
                    if Obs.ensure_websocket_enabled():
                        self.say("已打开 obs-websocket，重启 OBS 生效…")
                        Obs.stop()
                    if not Obs.is_running():
                        self.say("启动 OBS…")
                        Obs.start()
                    self.obs = Obs().connect()
                    self.say(f"OBS 已连接 v{self.obs.version}")
                    self.refresh_windows(False)
                    st = self.obs.vcam_status()
                    self.say("虚拟摄像头：" + ("运行中" if st else "未启动"))
                except Exception as e:      # noqa: BLE001
                    self.say(f"初始化失败：{e}")
            threading.Thread(target=work, daemon=True).start()

        def _run(self, fn):
            def work():
                if not self.busy.acquire(blocking=False):
                    self.say("上一个操作还没结束…")
                    return
                try:
                    if self.obs is None:
                        self.obs = Obs().connect()
                    fn()
                except Exception as e:      # noqa: BLE001
                    self.say(f"失败：{e}")
                finally:
                    self.busy.release()
            threading.Thread(target=work, daemon=True).start()

        def restart_obs(self):
            def fn():
                Obs.stop()
                Obs.start()
                self.obs = Obs().connect()
                self.say("OBS 已重启")
            self._run(fn)

        def toggle_vcam(self, on):
            def fn():
                cur = self.obs.vcam_status()
                target = (not cur) if on is None else on
                self.obs.vcam(target)
                self.say("虚拟摄像头：" + ("运行中" if target else "已停止"))
            self._run(fn)

        def refresh_windows(self, notify=False):
            def fn():
                items = self.obs.window_items()
                self.sig_windows.emit(items)
            if notify:
                self._run(fn)
            else:
                try:
                    fn()
                except Exception:
                    pass

        # ---------- 应用 ----------
        def pick_video(self):
            p, _ = QFileDialog.getOpenFileName(
                self, "选视频", os.path.dirname(self.ed_video.text() or ""),
                "视频文件 (*.mp4 *.mkv *.mov *.avi *.webm *.flv *.wmv *.m4v)")
            if p:
                self.ed_video.setText(p)

        def media_kw(self, restart=False):
            path = self.ed_video.text().strip()
            if path and not os.path.exists(path):
                self.say(f"文件不存在：{path}")
                return
            kw = {"is_local_file": True, "local_file": path.replace("\\", "/"),
                  "looping": self.cb_loop.isChecked(),
                  "restart_on_activate": True, "close_when_inactive": False}
            if restart:
                kw["restart"] = True
            self._run(lambda: (self.obs.media_settings(**kw), self.say("视频源已更新")))

        def apply_settings(self):
            def fn():
                if self.rb_video.isChecked():
                    path = self.ed_video.text().strip()
                    info = probe_video(path) if path else None
                    if info:
                        w, h, fps = info
                        cw, ch = fit_canvas(w, h)
                        self.obs.set_video((cw, ch), fps)
                        self.say(f"画布 {cw}x{ch} @ {fps}fps（源 {w}x{h}）")
                    self.obs.media_settings(
                        is_local_file=True,
                        local_file=path.replace("\\", "/"),
                        looping=self.cb_loop.isChecked(),
                        restart_on_activate=True,
                        close_when_inactive=False,
                        restart=True,
                    )
                    self.obs.show_source(SRC_VIDEO, True)
                    self.obs.show_source(SRC_WINDOW, False)
                    self.say("已切到：本地视频")
                else:
                    val = self.cb_window.currentData()
                    if not val:
                        self.say("没选窗口，先点「刷新窗口」")
                        return
                    self.obs.set_window(val)
                    self.obs.show_source(SRC_WINDOW, True)
                    self.obs.show_source(SRC_VIDEO, False)
                    self.say("已切到：窗口捕获 —— " + self.cb_window.currentText()[:60])
                if not self.obs.vcam_status():
                    self.obs.vcam(True)
                    self.say("虚拟摄像头已启动")
            self._run(fn)

        def use_video(self):
            self._run(lambda: (self.obs.show_source(SRC_VIDEO, True),
                               self.obs.show_source(SRC_WINDOW, False),
                               self.say("热键：本地视频")))

        def use_window(self):
            val = self.cb_window.currentData()
            if not val:
                self.say("热键：窗口列表为空，先刷新")
                return
            self._run(lambda: (self.obs.set_window(val),
                               self.obs.show_source(SRC_WINDOW, True),
                               self.obs.show_source(SRC_VIDEO, False),
                               self.say("热键：窗口捕获")))

        def toggle_video_visible(self):
            def fn():
                sid = self.obs.scene_item_id(SRC_VIDEO)
                self.say(f"视频源 id={sid}（可用于排查）")
            self._run(fn)

    app = QApplication(sys.argv)
    w = Studio()
    w.show()
    return app.exec_()


# ----------------------------------------------------------------------------- 自检
def selftest() -> int:
    print("== VcamStudio 自检 ==")
    changed = Obs.ensure_websocket_enabled()
    if changed:
        print("· 已打开 obs-websocket，重启 OBS")
        Obs.stop()
    if not Obs.is_running():
        print("· 启动 OBS…")
        if not Obs.start():
            print("!! OBS 起不来")
            return 2
    obs = Obs().connect()
    print(f"· OBS {obs.version} 已连接")

    cfg = {}
    if os.path.exists(CONFIG_JSON):
        with open(CONFIG_JSON, encoding="utf-8") as f:
            cfg = json.load(f)
    video = cfg.get("videoFile") or os.path.join(PROJECT_DIR, "sample-testsrc.mp4")
    print(f"· 片源 {video}")

    info = probe_video(video)
    if info:
        cw, ch = fit_canvas(info[0], info[1])
        obs.set_video((cw, ch), info[2])
        print(f"· 画布 → {cw}x{ch} @ {info[2]}fps")
    obs.media_settings(is_local_file=True, local_file=video.replace("\\", "/"),
                       looping=True, restart_on_activate=True,
                       close_when_inactive=False, restart=True)
    obs.show_source(SRC_VIDEO, True)
    obs.show_source(SRC_WINDOW, False)
    print("· 源：本地视频 可见 / 窗口捕获 隐藏")

    if not obs.vcam_status():
        obs.vcam(True)
    print("· 虚拟摄像头：运行中")

    items = obs.window_items()
    print(f"· OBS 可捕获窗口 {len(items)} 个，前 3 个：")
    for name, _val in items[:3]:
        print("    " + name[:70])

    png = os.path.join(PROJECT_DIR, "_artifacts", "03-gui自检抓帧.png")
    os.makedirs(os.path.dirname(png), exist_ok=True)
    time.sleep(1.5)
    got = grab_frame(png)
    if not got:
        print("!! 抓帧失败：虚拟摄像头没出画面")
        obs.close()
        return 3
    black = frame_is_black(png)
    print(f"· 抓帧 {os.path.getsize(png)//1024}KB  {'（全黑！）' if black else '（有画面）'}")
    obs.close()
    ok = (not black)
    print("== 自检" + ("通过 ==" if ok else "失败 =="))
    return 0 if ok else 4


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(run_gui())
