#!/usr/bin/env python3
"""
Canon G7 X Mark II — Web Live Stream Server
Трансляция видео с камеры по Wi-Fi в браузер (http://localhost:8080)
"""

import sys
import subprocess
import socket
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler

HTML_PAGE = """<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Canon G7 X Mark II — LiveView Stream</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, sans-serif; }
        body { background: #0f1117; color: #fff; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 100vh; padding: 20px; }
        .container { max-width: 960px; width: 100%; display: flex; flex-direction: column; align-items: center; gap: 16px; }
        .header { display: flex; align-items: center; justify-content: space-between; width: 100%; padding: 8px 16px; background: #1a1d26; border-radius: 12px; }
        .title { display: flex; align-items: center; gap: 10px; font-size: 18px; font-weight: 600; }
        .badge { background: #e53935; color: #fff; padding: 3px 10px; border-radius: 20px; font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px; animation: pulse 1.5s infinite; }
        @keyframes pulse { 0% { opacity: 1; } 50% { opacity: 0.5; } 100% { opacity: 1; } }
        .video-box { position: relative; width: 100%; aspect-ratio: 3/2; background: #000; border-radius: 14px; overflow: hidden; box-shadow: 0 10px 40px rgba(0,0,0,0.6); display: flex; align-items: center; justify-content: center; border: 1px solid #2a2e3d; }
        .video-box img { width: 100%; height: 100%; object-fit: contain; }
        .controls { display: flex; gap: 12px; width: 100%; justify-content: center; }
        .btn { background: #2563eb; color: #fff; border: none; padding: 10px 20px; border-radius: 8px; font-size: 14px; font-weight: 600; cursor: pointer; transition: all 0.2s; display: flex; align-items: center; gap: 8px; }
        .btn:hover { background: #1d4ed8; transform: translateY(-1px); }
        .btn-secondary { background: #2a2e3d; }
        .btn-secondary:hover { background: #374151; }
        .status { font-size: 13px; color: #9ca3af; text-align: center; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="title">
                <span>📷 Canon PowerShot G7 X Mark II</span>
                <span class="badge">Live</span>
            </div>
            <div class="status" id="ip-display">Wi-Fi PTP-IP Поток</div>
        </div>

        <div class="video-box" id="videobox">
            <img id="stream" src="/stream.mjpg" alt="Canon LiveView Stream" />
        </div>

        <div class="controls">
            <button class="btn" onclick="toggleFullscreen()">⛶ Во весь экран</button>
            <button class="btn btn-secondary" onclick="saveSnapshot()">📸 Сохранить стоп-кадр</button>
            <button class="btn btn-secondary" onclick="location.reload()">🔄 Перезагрузить</button>
        </div>
    </div>

    <script>
        function toggleFullscreen() {
            const box = document.getElementById('videobox');
            if (!document.fullscreenElement) {
                box.requestFullscreen().catch(err => alert(err.message));
            } else {
                document.exitFullscreen();
            }
        }
        function saveSnapshot() {
            const img = document.getElementById('stream');
            const canvas = document.createElement('canvas');
            canvas.width = img.naturalWidth || 640;
            canvas.height = img.naturalHeight || 480;
            const ctx = canvas.getContext('2d');
            ctx.drawImage(img, 0, 0);
            const a = document.createElement('a');
            a.href = canvas.toDataURL('image/jpeg');
            a.download = 'Canon_Snapshot_' + new Date().toISOString().replace(/[:.]/g, '-') + '.jpg';
            a.click();
        }
    </script>
</body>
</html>
"""

class CameraStreamer:
    def __init__(self, camera_ip=None):
        self.camera_ip = camera_ip or self.find_camera()
        self.gphoto_process = None

    def find_camera(self):
        # Check known IP
        return "192.168.223.242"

    def start_stream(self):
        if not self.camera_ip:
            print("❌ Камера не найдена в сети.")
            sys.exit(1)
        
        print(f"🔴 Подключение к Canon G7X ({self.camera_ip})...")
        cmd = [
            "/opt/homebrew/bin/gphoto2",
            "--port", f"ptpip:{self.camera_ip}",
            "--capture-movie",
            "--stdout"
        ]
        self.gphoto_process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            bufsize=10**6
        )
        return self.gphoto_process.stdout

class StreamHandler(BaseHTTPRequestHandler):
    streamer = None

    def do_GET(self):
        if self.path == "/" or self.path == "/index.html":
            self.send_response(200)
            self.send_header("Content-type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(HTML_PAGE.encode("utf-8"))
        elif self.path == "/stream.mjpg":
            self.send_response(200)
            self.send_header("Content-type", "multipart/x-mixed-replace; boundary=spitfd")
            self.end_headers()
            try:
                stream_pipe = StreamHandler.streamer.start_stream()
                while True:
                    chunk = stream_pipe.read(1024 * 64)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self.send_error(404)

def run_server(port=8080, ip=None):
    StreamHandler.streamer = CameraStreamer(camera_ip=ip)
    server = HTTPServer(("0.0.0.0", port), StreamHandler)
    print(f"\n🚀 Веб-сервер запущен:")
    print(f"   👉 http://localhost:{port}")
    print(f"   👉 http://127.0.0.1:{port}\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nОстановка сервера...")
        server.server_close()

if __name__ == "__main__":
    ip_arg = sys.argv[1] if len(sys.argv) > 1 else "192.168.223.242"
    run_server(port=8080, ip=ip_arg)
