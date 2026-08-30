#!/usr/bin/env python3
"""
Canon PowerShot G7 X Mark II — Live Video & Webcam Streaming Server
Трансляция живого видеопотока с матрицы камеры по Wi-Fi / USB
"""

import sys
import os
import subprocess
import socket
import threading
import time
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler

HTML_PAGE = """<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Canon G7 X Mark II — Веб-трансляция</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, sans-serif; }
        body { background: #0a0c10; color: #f3f4f6; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 100vh; padding: 20px; }
        .container { max-width: 1000px; width: 100%; display: flex; flex-direction: column; align-items: center; gap: 16px; }
        .header { display: flex; align-items: center; justify-content: space-between; width: 100%; padding: 14px 22px; background: #131722; border-radius: 14px; border: 1px solid #232838; }
        .camera-title { font-size: 18px; font-weight: 700; display: flex; align-items: center; gap: 10px; }
        .live-tag { background: #ef4444; color: #fff; padding: 4px 10px; border-radius: 20px; font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: 0.8px; display: inline-flex; align-items: center; gap: 6px; }
        .live-dot { width: 7px; height: 7px; background: #fff; border-radius: 50%; animation: pulse 1s infinite alternate; }
        @keyframes pulse { from { opacity: 1; } to { opacity: 0.2; } }
        
        .video-box { position: relative; width: 100%; aspect-ratio: 3/2; background: #000; border-radius: 16px; overflow: hidden; border: 1px solid #282e44; display: flex; align-items: center; justify-content: center; box-shadow: 0 20px 50px rgba(0,0,0,0.7); }
        .video-box img { width: 100%; height: 100%; object-fit: contain; }

        .controls { display: flex; gap: 12px; flex-wrap: wrap; justify-content: center; width: 100%; }
        .btn { background: #2563eb; color: #fff; border: none; padding: 12px 22px; border-radius: 10px; font-size: 14px; font-weight: 600; cursor: pointer; display: inline-flex; align-items: center; gap: 8px; transition: all 0.2s ease; }
        .btn:hover { background: #1d4ed8; transform: translateY(-2px); }
        .btn-sec { background: #1e2332; color: #e5e7eb; border: 1px solid #2f364e; }
        .btn-sec:hover { background: #282f44; color: #fff; }
        
        .guide { width: 100%; background: #131722; border: 1px solid #232838; border-radius: 14px; padding: 16px 20px; font-size: 13px; color: #9ca3af; line-height: 1.6; }
        .guide strong { color: #f3f4f6; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="camera-title">
                <span>📷 Canon PowerShot G7 X Mark II</span>
            </div>
            <div class="live-tag"><div class="live-dot"></div> LiveView</div>
        </div>

        <div class="video-box" id="videoBox">
            <img id="streamImg" src="/stream.mjpg" alt="Ожидание видеопотока с камеры..." />
        </div>

        <div class="controls">
            <button class="btn" onclick="toggleFullscreen()">⛶ Во весь экран</button>
            <button class="btn btn-sec" onclick="takeSnapshot()">📸 Сделать стоп-кадр</button>
            <button class="btn btn-sec" onclick="reconnect()">🔄 Переподключить</button>
        </div>

        <div class="guide">
            💡 <strong>Для трансляции видео:</strong> На камере нажмите кнопку <strong>Wi-Fi</strong> на боку → выберите <strong>📱 «Смартфон / Дистанционное управление»</strong>. Камера откроет шторку объектива и начнет живую трансляцию с матрицы DIGIC 7.
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

CAMERA_IP = "192.168.223.242"

class StreamHandler(BaseHTTPRequestHandler):
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
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=spitfd")
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.end_headers()

            cmd = [
                "/opt/homebrew/bin/gphoto2",
                "--port", f"ptpip:{CAMERA_IP}",
                "--capture-movie",
                "--stdout"
            ]
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=10**6)
            try:
                while True:
                    chunk = proc.stdout.read(32768)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            except Exception:
                pass
            finally:
                proc.terminate()
        else:
            self.send_error(404)

def run():
    server = HTTPServer(("0.0.0.0", 8080), StreamHandler)
    print("\n" + "═"*60)
    print("🎥 Canon PowerShot G7 X Mark II — Веб-трансляция / LiveView")
    print(f"📡 IP камеры:       {CAMERA_IP}:15740")
    print("🌐 Веб-плеер:       http://localhost:8080")
    print("🎬 Поток для OBS:   http://localhost:8080/stream.mjpg")
    print("═"*60 + "\n")

    # Open browser automatically
    subprocess.run(["/usr/bin/open", "http://localhost:8080"])

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nОстановка сервера...")
        server.server_close()

if __name__ == "__main__":
    run()
