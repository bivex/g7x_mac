#!/bin/bash
# Запуск трансляции видео с Canon G7 X Mark II (PTP-IP Wi-Fi)

CAMERA_IP="192.168.223.242"

echo "🔴 Подключение к LiveView видеопотоку Canon G7 X ($CAMERA_IP)..."
echo "👉 Убедитесь, что камера включена в режиме [Смартфон / Дистанционная съемка]"
echo ""

/opt/homebrew/bin/gphoto2 --port "ptpip:$CAMERA_IP" --capture-movie --stdout | \
/opt/homebrew/bin/ffplay -window_title "Canon G7 X Mark II — LiveView" \
    -fflags nobuffer+flush_packets \
    -flags low_delay \
    -framedrop \
    -x 960 -y 640 -
