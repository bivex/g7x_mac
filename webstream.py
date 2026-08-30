#!/usr/bin/env python3
"""
Canon PowerShot G7 X Mark II — Seamless Remote Studio & Web LiveView
- Мгновенная съемка и сохранение фото прямо на Mac в ~/Pictures/Canon_G7X/
- Звук затвора и визуальная вспышка
- Непрерывный живой видеопоток без обрывов
"""

import sys
import os
import subprocess
import socket
import threading
import time
import json
from pathlib import Path
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

CAMERA_IP = "192.168.223.242"
PORT = 8080
PICTURES_DIR = Path.home() / "Pictures" / "Canon_G7X"
PICTURES_DIR.mkdir(parents=True, exist_ok=True)

class FrameBroadcaster:
    def __init__(self):
        self.lock = threading.Lock()
        self.current_frame = None
        self.last_valid_frame = None
        self.condition = threading.Condition(self.lock)
        self.running = True
        self.process = None
        self.worker_thread = threading.Thread(target=self._capture_loop, daemon=True)
        self.worker_thread.start()

    def _capture_loop(self):
        while self.running:
            cmd = [
                "/opt/homebrew/bin/gphoto2",
                "--port", f"ptpip:{CAMERA_IP}",
                "--capture-movie",
                "--stdout"
            ]
            try:
                self.process = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    bufsize=10**6
                )
                
                buffer = bytearray()
                soi = b'\xff\xd8'
                eoi = b'\xff\xd9'

                while self.running and self.process.poll() is None:
                    chunk = self.process.stdout.read(16384)
                    if not chunk:
                        break
                    buffer.extend(chunk)

                    while True:
                        start = buffer.find(soi)
                        if start == -1:
                            if len(buffer) > 100000:
                                buffer.clear()
                            break
                        end = buffer.find(eoi, start + 2)
                        if end == -1:
                            if start > 0:
                                del buffer[:start]
                            break
                        
                        frame = bytes(buffer[start:end+2])
                        del buffer[:end+2]

                        with self.condition:
                            self.current_frame = frame
                            self.last_valid_frame = frame
                            self.condition.notify_all()

            except Exception:
                time.sleep(1)
            finally:
                if self.process:
                    try:
                        self.process.terminate()
                        self.process.wait(timeout=1)
                    except Exception:
                        pass
                time.sleep(1.0)

    def get_frame(self, timeout=0.5):
        with self.condition:
            if self.condition.wait(timeout):
                return self.current_frame
            return self.last_valid_frame

broadcaster = FrameBroadcaster()

def save_current_frame_as_photo():
    """Сохранение высококачественного снимка напрямую в ~/Pictures/Canon_G7X/"""
    frame = broadcaster.get_frame(timeout=1.0)
    if not frame:
        return {"success": False, "message": "Нет видеопотока с камеры"}

    today = time.strftime("%Y-%m-%d")
    target_dir = PICTURES_DIR / today
    target_dir.mkdir(parents=True, exist_ok=True)

    timestamp = time.strftime("%Y%m%d_%H%M%S")
    filename = f"Canon_{timestamp}.jpg"
    file_path = target_dir / filename

    try:
        with open(file_path, "wb") as f:
            f.write(frame)
        
        file_size_kb = len(frame) / 1024
        return {
            "success": True,
            "message": f"Снимок сохранён: {filename} ({file_size_kb:.0f} KB)",
            "filename": filename,
            "path": str(file_path),
            "folder": today
        }
    except Exception as e:
        return {"success": False, "message": str(e)}

HTML_PAGE = """<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Canon G7 X Mark II — Студия съемки</title>
    <style>
        :root {
            --bg: #07090e;
            --panel: #11141e;
            --border: #1f2535;
            --accent: #2563eb;
            --red: #ef4444;
            --text: #f3f4f6;
            --text-dim: #9ca3af;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, sans-serif; }
        body { background: var(--bg); color: var(--text); min-height: 100vh; display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 20px; }
        
        .studio-container { max-width: 1040px; width: 100%; display: flex; flex-direction: column; gap: 16px; }

        /* Header */
        .header { display: flex; align-items: center; justify-content: space-between; padding: 14px 24px; background: var(--panel); border: 1px solid var(--border); border-radius: 16px; box-shadow: 0 4px 20px rgba(0,0,0,0.4); }
        .camera-name { font-size: 19px; font-weight: 700; display: flex; align-items: center; gap: 10px; }
        .live-badge { background: var(--red); color: #fff; padding: 4px 12px; border-radius: 20px; font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: 0.8px; display: inline-flex; align-items: center; gap: 6px; }
        .live-dot { width: 7px; height: 7px; background: #fff; border-radius: 50%; animation: blink 1s infinite alternate; }
        @keyframes blink { from { opacity: 1; } to { opacity: 0.3; } }

        /* Video Frame */
        .video-box { position: relative; width: 100%; aspect-ratio: 3/2; background: #000; border-radius: 18px; overflow: hidden; border: 1px solid var(--border); display: flex; align-items: center; justify-content: center; box-shadow: 0 25px 60px rgba(0,0,0,0.8); }
        .video-box img { width: 100%; height: 100%; object-fit: contain; }

        /* Shutter Flash Animation */
        .shutter-flash {
            position: absolute; inset: 0; background: #fff; opacity: 0; pointer-events: none;
            transition: opacity 0.15s ease-out; z-index: 10;
        }
        .shutter-flash.flash { opacity: 0.9; transition: opacity 0.05s ease-in; }

        /* Shooting Control Bar */
        .control-bar {
            display: flex; align-items: center; justify-content: space-between; gap: 14px;
            background: var(--panel); border: 1px solid var(--border); border-radius: 16px; padding: 14px 24px; flex-wrap: wrap;
        }
        .left-controls, .right-controls { display: flex; align-items: center; gap: 12px; }
        .center-controls { display: flex; align-items: center; gap: 16px; }

        /* Buttons */
        .btn {
            background: #1a1f2c; color: var(--text); border: 1px solid #283044; padding: 10px 18px; border-radius: 10px;
            font-size: 13px; font-weight: 600; cursor: pointer; display: inline-flex; align-items: center; gap: 8px;
            transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
        }
        .btn:hover { background: #242b3d; border-color: #38435e; transform: translateY(-1px); }
        .btn:active { transform: translateY(1px); }

        /* Shutter Trigger Button */
        .shutter-btn {
            background: linear-gradient(135deg, #ef4444 0%, #dc2626 100%); color: #fff; border: 3px solid rgba(255,255,255,0.25);
            padding: 14px 34px; border-radius: 30px; font-size: 16px; font-weight: 800; cursor: pointer;
            display: inline-flex; align-items: center; gap: 10px; box-shadow: 0 6px 20px rgba(239, 68, 68, 0.4);
            transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
        }
        .shutter-btn:hover { transform: scale(1.04); box-shadow: 0 8px 25px rgba(239, 68, 68, 0.6); }
        .shutter-btn:active { transform: scale(0.96); }

        /* Toast Notifications */
        .toast {
            position: fixed; bottom: 30px; left: 50%; transform: translateX(-50%) translateY(100px);
            background: rgba(17, 20, 30, 0.95); backdrop-filter: blur(20px); border: 1px solid var(--border);
            color: #fff; padding: 14px 28px; border-radius: 30px; font-size: 14px; font-weight: 600;
            display: flex; align-items: center; gap: 10px; box-shadow: 0 10px 30px rgba(0,0,0,0.6);
            opacity: 0; transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1); z-index: 1000;
        }
        .toast.show { transform: translateX(-50%) translateY(0); opacity: 1; }
    </style>
</head>
<body>
    <div class="studio-container">
        <div class="header">
            <div class="camera-name">
                <span>📷 Canon PowerShot G7 X Mark II</span>
            </div>
            <div style="display: flex; align-items: center; gap: 12px;">
                <div class="live-badge"><div class="live-dot"></div> LiveView</div>
            </div>
        </div>

        <div class="video-box" id="videoBox">
            <img id="streamImg" src="/stream.mjpg" alt="Ожидание видеопотока с камеры..." />
            <div class="shutter-flash" id="shutterFlash"></div>
        </div>

        <div class="control-bar">
            <div class="left-controls">
                <button class="btn" onclick="openFinder()">📂 Папка фото</button>
            </div>

            <div class="center-controls">
                <button class="shutter-btn" id="shutterBtn" onclick="takePhoto()">
                    <span>📸 СДЕЛАТЬ ФОТО</span>
                </button>
            </div>

            <div class="right-controls">
                <button class="btn" onclick="toggleFullscreen()">⛶ Во весь экран</button>
            </div>
        </div>
    </div>

    <div class="toast" id="toast"></div>

    <script>
        function playShutterSound() {
            try {
                const ctx = new (window.AudioContext || window.webkitAudioContext)();
                const osc = ctx.createOscillator();
                const gain = ctx.createGain();
                osc.connect(gain);
                gain.connect(ctx.destination);
                osc.frequency.setValueAtTime(800, ctx.currentTime);
                osc.frequency.exponentialRampToValueAtTime(100, ctx.currentTime + 0.08);
                gain.gain.setValueAtTime(0.3, ctx.currentTime);
                gain.gain.exponentialRampToValueAtTime(0.01, ctx.currentTime + 0.08);
                osc.start(ctx.currentTime);
                osc.stop(ctx.currentTime + 0.08);
            } catch (e) {}
        }

        function showToast(text, icon="✅") {
            const toast = document.getElementById('toast');
            toast.innerHTML = `<span>${icon}</span> <span>${text}</span>`;
            toast.classList.add('show');
            setTimeout(() => toast.classList.remove('show'), 3500);
        }

        async function takePhoto() {
            playShutterSound();
            const flash = document.getElementById('shutterFlash');
            flash.classList.add('flash');
            setTimeout(() => flash.classList.remove('flash'), 100);

            try {
                const res = await fetch('/api/capture', { method: 'POST' });
                const data = await res.json();
                if (data.success) {
                    showToast(data.message, '🎉');
                } else {
                    showToast(data.message || 'Ошибка сохранения', '⚠️');
                }
            } catch (e) {
                showToast('Ошибка связи', '❌');
            }
        }

        function openFinder() {
            fetch('/api/open_folder', { method: 'POST' });
            showToast('Папка Canon_G7X открыта в Finder', '📂');
        }

        function toggleFullscreen() {
            const box = document.getElementById('videoBox');
            if (!document.fullscreenElement) {
                box.requestFullscreen().catch(err => alert(err.message));
            } else {
                document.exitFullscreen();
            }
        }
    </script>
</body>
</html>
"""

class RemoteStudioHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(HTML_PAGE.encode("utf-8"))

        elif self.path.startswith("/stream.mjpg"):
            self.send_response(200)
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.end_headers()

            try:
                while True:
                    frame = broadcaster.get_frame(timeout=0.5)
                    if frame:
                        header = b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: " + str(len(frame)).encode() + b"\r\n\r\n"
                        self.wfile.write(header)
                        self.wfile.write(frame)
                        self.wfile.write(b"\r\n")
                    else:
                        time.sleep(0.04)
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path == "/api/capture":
            res = save_current_frame_as_photo()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(res).encode())

        elif self.path == "/api/open_folder":
            subprocess.run(["/usr/bin/open", str(PICTURES_DIR)])
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"success":true}')
        else:
            self.send_error(404)

def run():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), RemoteStudioHandler)
    print("\n" + "═"*60)
    print("📸 Canon PowerShot G7 X Mark II — Студия съемки и LiveView")
    print(f"📡 IP камеры:       {CAMERA_IP}:15740")
    print("🌐 Веб-пульт:       http://localhost:8080")
    print("═"*60 + "\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        broadcaster.running = False
        server.server_close()

if __name__ == "__main__":
    run()
