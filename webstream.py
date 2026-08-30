#!/usr/bin/env python3
"""
Canon PowerShot G7 X Mark II — Remote Studio & Web LiveView
- Живая трансляция видеопотока с сенсора DIGIC 7
- Дистанционный спуск затвора (Сделать снимок и скачать на Mac)
- Управление автофокусом и настройками камеры
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
from urllib.parse import urlparse, parse_qs

CAMERA_IP = "192.168.223.242"
PORT = 8080
PICTURES_DIR = Path.home() / "Pictures" / "Canon_G7X"
PICTURES_DIR.mkdir(parents=True, exist_ok=True)

class FrameBroadcaster:
    def __init__(self):
        self.lock = threading.Lock()
        self.current_frame = None
        self.condition = threading.Condition(self.lock)
        self.running = True
        self.is_paused_for_capture = False
        self.process = None
        self.worker_thread = threading.Thread(target=self._capture_loop, daemon=True)
        self.worker_thread.start()

    def _capture_loop(self):
        while self.running:
            if self.is_paused_for_capture:
                time.sleep(0.1)
                continue

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

                while self.running and not self.is_paused_for_capture and self.process.poll() is None:
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
                time.sleep(0.5)

    def get_frame(self, timeout=1.0):
        with self.condition:
            if self.condition.wait(timeout):
                return self.current_frame
            return None

    def pause_stream(self):
        self.is_paused_for_capture = True
        if self.process:
            try:
                self.process.terminate()
                self.process.wait(timeout=1)
            except Exception:
                pass

    def resume_stream(self):
        self.is_paused_for_capture = False

broadcaster = FrameBroadcaster()

def capture_photo_remote():
    """Спуск затвора камеры и моментальная загрузка на Mac"""
    broadcaster.pause_stream()
    time.sleep(0.3)

    today = time.strftime("%Y-%m-%d")
    target_dir = PICTURES_DIR / today
    target_dir.mkdir(parents=True, exist_ok=True)

    filename_pattern = str(target_dir / "Canon_%Y%m%d_%H%M%S.%C")

    cmd = [
        "/opt/homebrew/bin/gphoto2",
        "--port", f"ptpip:{CAMERA_IP}",
        "--capture-image-and-download",
        "--filename", filename_pattern
    ]
    
    result = {"success": False, "message": ""}
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if proc.returncode == 0:
            result["success"] = True
            result["message"] = "Снимок сохранён в папку " + today
        else:
            result["message"] = proc.stderr.strip() or "Ошибка спуска затвора"
    except Exception as e:
        result["message"] = str(e)
    finally:
        broadcaster.resume_stream()

    return result

def trigger_autofocus():
    """Сфокусировать объектив (полунажатие кнопки спуска)"""
    broadcaster.pause_stream()
    time.sleep(0.2)
    cmd = [
        "/opt/homebrew/bin/gphoto2",
        "--port", f"ptpip:{CAMERA_IP}",
        "--set-config", "autofocusdrive=1"
    ]
    try:
        subprocess.run(cmd, capture_output=True, timeout=5)
    finally:
        broadcaster.resume_stream()
    return {"success": True}

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
            --accent-hover: #1d4ed8;
            --red: #ef4444;
            --red-hover: #dc2626;
            --green: #10b981;
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

        /* Focus Overlay Target */
        .af-target { position: absolute; width: 60px; height: 60px; border: 2px solid rgba(16, 185, 129, 0.7); border-radius: 8px; pointer-events: none; opacity: 0; transition: opacity 0.3s, transform 0.2s; }
        .af-target.active { opacity: 1; transform: scale(0.9); }

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
            background: linear-gradient(135deg, #ef4444 0%, #dc2626 100%); color: #fff; border: 3px solid rgba(255,255,255,0.2);
            padding: 14px 32px; border-radius: 30px; font-size: 16px; font-weight: 800; cursor: pointer;
            display: inline-flex; align-items: center; gap: 10px; box-shadow: 0 6px 20px rgba(239, 68, 68, 0.4);
            transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
        }
        .shutter-btn:hover { transform: scale(1.04); box-shadow: 0 8px 25px rgba(239, 68, 68, 0.6); }
        .shutter-btn:active { transform: scale(0.96); }
        .shutter-btn.loading { opacity: 0.7; pointer-events: none; }

        .btn-af { background: #064e3b; border-color: #059669; color: #a7f3d0; }
        .btn-af:hover { background: #047857; color: #fff; }

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

        <div class="video-box" id="videoBox" onclick="triggerAF()">
            <img id="streamImg" src="/stream.mjpg" alt="Ожидание видеопотока..." />
            <div class="af-target" id="afTarget"></div>
        </div>

        <div class="control-bar">
            <div class="left-controls">
                <button class="btn btn-af" onclick="triggerAF()">🎯 Фокус (AF)</button>
                <button class="btn" onclick="saveQuickSnapshot()">🖼️ Стоп-кадр</button>
            </div>

            <div class="center-controls">
                <button class="shutter-btn" id="shutterBtn" onclick="takeFullPhoto()">
                    <span>📸 СДЕЛАТЬ ФОТО</span>
                </button>
            </div>

            <div class="right-controls">
                <button class="btn" onclick="openFinder()">📂 Папка фото</button>
                <button class="btn" onclick="toggleFullscreen()">⛶ Во весь экран</button>
            </div>
        </div>
    </div>

    <div class="toast" id="toast"></div>

    <script>
        function showToast(text, icon="✅") {
            const toast = document.getElementById('toast');
            toast.innerHTML = `<span>${icon}</span> <span>${text}</span>`;
            toast.classList.add('show');
            setTimeout(() => toast.classList.remove('show'), 3500);
        }

        async function takeFullPhoto() {
            const btn = document.getElementById('shutterBtn');
            btn.classList.add('loading');
            btn.innerHTML = '<span>⏳ Съемка...</span>';
            showToast('Спуск затвора... Сохранение на Mac', '📸');

            try {
                const res = await fetch('/api/capture', { method: 'POST' });
                const data = await res.json();
                if (data.success) {
                    showToast('Снимок успешно сохранен в ~/Pictures/Canon_G7X!', '🎉');
                } else {
                    showToast(data.message || 'Ошибка спуска затвора', '⚠️');
                }
            } catch (e) {
                showToast('Ошибка связи с камерой', '❌');
            } finally {
                btn.classList.remove('loading');
                btn.innerHTML = '<span>📸 СДЕЛАТЬ ФОТО</span>';
                setTimeout(() => {
                    document.getElementById('streamImg').src = '/stream.mjpg?t=' + Date.now();
                }, 800);
            }
        }

        async function triggerAF() {
            const target = document.getElementById('afTarget');
            target.classList.add('active');
            try {
                await fetch('/api/autofocus', { method: 'POST' });
                showToast('Фокус наведен', '🎯');
            } catch (e) {}
            setTimeout(() => target.classList.remove('active'), 1200);
        }

        function saveQuickSnapshot() {
            const img = document.getElementById('streamImg');
            const canvas = document.createElement('canvas');
            canvas.width = img.naturalWidth || 960;
            canvas.height = img.naturalHeight || 640;
            const ctx = canvas.getContext('2d');
            ctx.drawImage(img, 0, 0);
            const a = document.createElement('a');
            a.href = canvas.toDataURL('image/jpeg', 0.95);
            a.download = 'Canon_LiveSnapshot_' + Date.now() + '.jpg';
            a.click();
            showToast('Стоп-кадр сохранен в Загрузки', '💾');
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
                    frame = broadcaster.get_frame(timeout=1.0)
                    if frame:
                        header = b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: " + str(len(frame)).encode() + b"\r\n\r\n"
                        self.wfile.write(header)
                        self.wfile.write(frame)
                        self.wfile.write(b"\r\n")
                    else:
                        time.sleep(0.03)
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path == "/api/capture":
            res = capture_photo_remote()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(res).encode())

        elif self.path == "/api/autofocus":
            res = trigger_autofocus()
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
