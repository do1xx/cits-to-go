#!/bin/sh
# Installiert die CITS-to-go-Bridge auf einem Raspberry Pi (Raspberry Pi OS / Debian).
# Aufruf im entpackten Ordner:  sudo ./install.sh  [pfad/zur/cits-bridge.env]
set -e
[ "$(id -u)" = 0 ] || { echo "Bitte mit sudo ausführen"; exit 1; }
ENV_SRC="${1:-cits-bridge.env}"
apt-get install -y python3-venv >/dev/null
id cits >/dev/null 2>&1 || useradd --system --no-create-home --groups dialout cits
install -d /opt/cits-bridge
install -m 644 cits_bridge.py requirements.txt /opt/cits-bridge/
[ -x /opt/cits-bridge/venv/bin/python ] || python3 -m venv /opt/cits-bridge/venv
/opt/cits-bridge/venv/bin/pip install -q -r /opt/cits-bridge/requirements.txt
if [ -f "$ENV_SRC" ]; then install -m 640 -o root -g cits "$ENV_SRC" /etc/cits-bridge.env
elif [ ! -f /etc/cits-bridge.env ]; then install -m 640 -o root -g cits cits-bridge.env.example /etc/cits-bridge.env
  echo "Bitte /etc/cits-bridge.env anpassen und dann: sudo systemctl restart cits-bridge"; fi
install -m 644 cits-bridge.service /etc/systemd/system/cits-bridge.service
systemctl daemon-reload
systemctl enable --now cits-bridge
sleep 3
systemctl --no-pager --lines=8 status cits-bridge || true
echo "Log verfolgen: journalctl -u cits-bridge -f"
