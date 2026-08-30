#!/usr/bin/env python3
"""
Canon PowerShot G7 X Mark II — High-Performance Browser LiveView Streamer
Трансляция живого видеопотока с матрицы камеры прямо в браузер (HTML5)
"""

import sys
import os
import subprocess
import socket
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

CAMERA_IP = "192.168.223.242"
PORT = 8080

class FrameBroadcaster:
    def __init__(self):
        self.lock = threading.Lock()
        self.current_frame = None
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
                soi = b'\xff\xd8'  # Start of JPEG
                eoi = b'\xff\xd9'  # End of JPEG

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
                            self.condition.notify_all()

            except Exception as e:
                time.sleep(1)
            finally:
                if self.process:
                    try:
                        self.process.terminate()
                    except Exception:
                        pass
                time.sleep(1.5)

    def get_frame(self, timeout=2.0):
        with self.condition:
            if self.condition.wait(timeout):
                return self.current_frame
            return None

broadcaster = FrameBroadcaster()

HTML_PAGE = """<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Canon G7 X Mark II — Live Stream</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, sans-serif; }
        body { background: #08090d; color: #f3f4f6; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 100vh; padding: 20px; }
        .container { max-width: 1080px; width: 100%; display: flex; flex-direction: column; align-items: center; gap: 16px; }
        .header { display: flex; align-items: center; justify-content: space-between; width: 100%; padding: 14px 24px; background: #12151f; border-radius: 14px; border: 1px solid #212638; box-shadow: 0 4px 20px rgba(0,0,0,0.4); }
        .camera-title { font-size: 19px; font-weight: 700; display: flex; align-items: center; gap: 10px; }
        .live-badge { background: #ef4444; color: #fff; padding: 5px 12px; border-radius: 20px; font-size: 12px; font-weight: 800; text-transform: uppercase; letter-spacing: 0.8px; display: inline-flex; align-items: center; gap: 6px; }
        .live-dot { width: 8px; height: 8px; background: #fff; border-radius: 50%; animation: pulse 1s infinite alternate; }
        @keyframes pulse { from { opacity: 1; } to { opacity: 0.3; } }
        
        .video-box { position: relative; width: 100%; aspect-ratio: 3/2; background: #000; border-radius: 16px; overflow: hidden; border: 1px solid #282e44; display: flex; align-items: center; justify-content: center; box-shadow: 0 20px 60px rgba(0,0,0,0.8); }
        .video-box img { width: 100%; height: 100%; object-fit: contain; }

        .controls { display: flex; gap: 12px; flex-wrap: wrap; justify-content: center; width: 100%; }
        .btn { background: #2563eb; color: #fff; border: none; padding: 12px 24px; border-radius: 10px; font-size: 14px; font-weight: 600; cursor: pointer; display: inline-flex; align-items: center; gap: 8px; transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1); box-shadow: 0 4px 12px rgba(37,99,235,0.3); }
        .btn:hover { background: #1d4ed8; transform: translateY(-2px); box-shadow: 0 6px 18px rgba(37,99,235,0.4); }
        .btn-sec { background: #1a1e2b; color: #e5e7eb; border: 1px solid #2b3248; box-shadow: none; }
        .btn-sec:hover { background: #242a3c; color: #fff; }
        
        .guide { width: 100%; background: #12151f; border: 1px solid #212638; border-radius: 14px; padding: 14px 20px; font-size: 13px; color: #9ca3af; display: flex; justify-content: space-between; align-items: center; }
        .guide strong { color: #f3f4f6; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="camera-title">
                <span>📷 Canon PowerShot G7 X Mark II</span>
            </div>
            <div class="live-badge"><div class="live-dot"></div> LiveView</div>
        </div>

        <div class="video-box" id="videoBox">
            <img id="streamImg" src="/stream.mjpg" alt="Подключение к видеопотоку..." />
        </div>

        <div class="controls">
            <button class="btn" onclick="toggleFullscreen()">⛶ Во весь экран</button>
            <button class="btn btn-sec" onclick="takeSnapshot()">📸 Сделать стоп-кадр</button>
            <button class="btn btn-sec" onclick="reconnect()">🔄 Переподключить</button>
        </div>

        <div class="guide">
            <div>💡 <strong>LiveView в браузере:</strong> На камере нажмите кнопку <strong>Wi-Fi</strong> → выберите <strong>📱 «Смартфон»</strong>.</div>
            <div style="font-size: 12px; color: #6b7280;">Поток для OBS: <code>http://localhost:8080/stream.mjpg</code></div>
        </div>
    </div>

    <script>
        function toggleFullscreen() {
            const box = document.getElementById('videoBox');
            if (!document.fullscreenElement) {
                box.requestFullscreen().catch(err => alert(err.message));
            } else {
                document.exitFullscreen();
            }
        }
        function reconnect() {
            document.getElementById('streamImg').src = '/stream.mjpg?t=' + Date.now();
        }
        function takeSnapshot() {
            const img = document.getElementById('streamImg');
            const canvas = document.createElement('canvas');
            canvas.width = img.naturalWidth || 960;
            canvas.height = img.naturalHeight || 640;
            const ctx = canvas.getContext('2d');
            ctx.drawImage(img, 0, 0);
            const a = document.createElement('a');
            a.href = canvas.toDataURL('image/jpeg', 0.95);
            a.download = 'Canon_G7X_Snapshot_' + Date.now() + '.jpg';
            a.click();
        }
    </script>
</body>
</html>
"""

class LiveStreamHandler(BaseHTTPRequestHandler):
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

def run():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), LiveStreamHandler)
    print("\n" + "═"*60)
    print("🎥 Canon PowerShot G7 X Mark II — Браузерная видеотрансляция")
    print(f"📡 IP камеры:       {CAMERA_IP}:15740")
    print("🌐 Откройте в браузере: http://localhost:8080")
    print("🎬 Ссылка для OBS:     http://localhost:8080/stream.mjpg")
    print("═"*60 + "\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        broadcaster.running = False
        server.server_close()

if __name__ == "__main__":
    run()
