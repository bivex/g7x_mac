#!/usr/bin/env python3
"""
Canon PowerShot G7 X Mark II — High-Performance LiveView Streaming Server
Трансляция живого видеопотока с матрицы камеры по Wi-Fi / USB
"""

import sys
import os
import subprocess
import socket
import threading
import time
import select
from http.server import HTTPServer, BaseHTTPRequestHandler

HTML_PAGE = """<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Canon G7 X Mark II — Live Stream</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, sans-serif; }
        body { background: #0b0d13; color: #f3f4f6; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 100vh; padding: 20px; }
        .container { max-width: 1080px; width: 100%; display: flex; flex-direction: column; align-items: center; gap: 18px; }
        .header { display: flex; align-items: center; justify-content: space-between; width: 100%; padding: 12px 20px; background: #151822; border-radius: 14px; border: 1px solid #232736; box-shadow: 0 4px 20px rgba(0,0,0,0.3); }
        .title-group { display: flex; align-items: center; gap: 12px; }
        .camera-name { font-size: 19px; font-weight: 700; letter-spacing: -0.3px; }
        .live-badge { background: #ef4444; color: #fff; padding: 4px 10px; border-radius: 20px; font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: 0.8px; display: flex; align-items: center; gap: 6px; }
        .live-dot { width: 7px; height: 7px; background: #fff; border-radius: 50%; animation: blink 1s infinite alternate; }
        @keyframes blink { from { opacity: 1; } to { opacity: 0.3; } }
        .video-wrapper { position: relative; width: 100%; aspect-ratio: 3/2; background: #000; border-radius: 16px; overflow: hidden; box-shadow: 0 20px 50px rgba(0,0,0,0.7); display: flex; align-items: center; justify-content: center; border: 1px solid #282c3f; }
        .video-wrapper img { width: 100%; height: 100%; object-fit: contain; }
        .controls { display: flex; gap: 14px; width: 100%; justify-content: center; flex-wrap: wrap; }
        .btn { background: #3b82f6; color: #fff; border: none; padding: 12px 24px; border-radius: 10px; font-size: 14px; font-weight: 600; cursor: pointer; transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1); display: flex; align-items: center; gap: 8px; box-shadow: 0 4px 12px rgba(59, 130, 246, 0.3); }
        .btn:hover { background: #2563eb; transform: translateY(-2px); box-shadow: 0 6px 16px rgba(59, 130, 246, 0.4); }
        .btn-secondary { background: #1e2230; color: #d1d5db; box-shadow: none; border: 1px solid #2e344a; }
        .btn-secondary:hover { background: #282d40; color: #fff; border-color: #3b425e; }
        .stats-bar { display: flex; gap: 20px; font-size: 13px; color: #9ca3af; }
        .stat-item { display: flex; align-items: center; gap: 6px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="title-group">
                <div class="camera-name">📷 Canon PowerShot G7 X Mark II</div>
                <div class="live-badge"><div class="live-dot"></div>LiveView</div>
            </div>
            <div class="stats-bar">
                <div class="stat-item"><span>📡 PTP-IP Wi-Fi Поток</span></div>
                <div class="stat-item"><span>⚡ DIGIC 7 Sensor</span></div>
            </div>
        </div>

        <div class="video-wrapper" id="videoWrapper">
            <img id="liveStream" src="/stream.mjpg" alt="Canon Live Stream" />
        </div>

        <div class="controls">
            <button class="btn" onclick="toggleFullscreen()">⛶ Во весь экран</button>
            <button class="btn btn-secondary" onclick="takeSnapshot()">📸 Сохранить стоп-кадр</button>
            <button class="btn btn-secondary" onclick="reconnectStream()">🔄 Переподключить</button>
        </div>
    </div>

    <script>
        function toggleFullscreen() {
            const wrapper = document.getElementById('videoWrapper');
            if (!document.fullscreenElement) {
                wrapper.requestFullscreen().catch(err => alert(err.message));
            } else {
                document.exitFullscreen();
            }
        }
        function takeSnapshot() {
            const img = document.getElementById('liveStream');
            const canvas = document.createElement('canvas');
            canvas.width = img.naturalWidth || 960;
            canvas.height = img.naturalHeight || 640;
            const ctx = canvas.getContext('2d');
            ctx.drawImage(img, 0, 0);
            const a = document.createElement('a');
            a.href = canvas.toDataURL('image/jpeg', 0.95);
            a.download = 'Canon_G7X_Snapshot_' + new Date().toISOString().replace(/[:.]/g, '-') + '.jpg';
            a.click();
        }
        function reconnectStream() {
            const img = document.getElementById('liveStream');
            img.src = '/stream.mjpg?t=' + Date.now();
        }
    </script>
</body>
</html>
"""

def scan_camera_ip():
    # Fast check of known IP
    for ip in ["192.168.223.242", "192.168.1.1", "192.168.0.1"]:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(0.3)
            if s.connect_ex((ip, 15740)) == 0:
                s.close()
                return ip
            s.close()
        except:
            pass
    return "192.168.223.242"

class CameraStreamManager:
    def __init__(self, ip=None):
        self.ip = ip or scan_camera_ip()
        self.process = None

    def get_stream(self):
        cmd = [
            "/opt/homebrew/bin/gphoto2",
            "--port", f"ptpip:{self.ip}",
            "--capture-movie",
            "--stdout"
        ]
        self.process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            bufsize=10**6
        )
        return self.process.stdout

class HTTPHandler(BaseHTTPRequestHandler):
    manager = None

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(HTML_PAGE.encode("utf-8"))
        elif self.path.startswith("/stream.mjpg"):
            self.send_response(200)
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=spitfd")
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.end_headers()

            stream = HTTPHandler.manager.get_stream()
            try:
                while True:
                    data = stream.read(32768)
                    if not data:
                        break
                    self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                if HTTPHandler.manager.process:
                    HTTPHandler.manager.process.terminate()
        else:
            self.send_error(404)

def run():
    ip = sys.argv[1] if len(sys.argv) > 1 else scan_camera_ip()
    HTTPHandler.manager = CameraStreamManager(ip=ip)
    
    server = HTTPServer(("0.0.0.0", 8080), HTTPHandler)
    print("\n" + "═"*55)
    print("🎥 Canon PowerShot G7 X Mark II — LiveView Stream")
    print(f"📡 Целевой IP камеры: {ip}:15740")
    print("🌐 Веб-интерфейс стрима: http://localhost:8080")
    print("🎬 URL для OBS / VLC:     http://localhost:8080/stream.mjpg")
    print("═"*55 + "\n")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nОстановка сервера...")
        server.server_close()

if __name__ == "__main__":
    run()
