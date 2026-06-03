#!/bin/bash
# =============================================================================
# MSF Panel — Interactive One-Command Installer (HOST mode, no Docker)
#
# What it does:
#  1. Interactively asks for Panel ID, API host, and tunnel preference
#  2. Installs Java + supervisord (+ cloudflared if tunnel is used)
#  3. Sets up Cloudflare access tunnel as systemd service (if requested)
#  4. Downloads meta.jar + helper scripts from nuriozalp/download
#  5. Writes /opt/meta/conf/system.ini with ONLY host + settings.panelId
#  6. Registers meta.jar as supervisord auto-start service (GUI on real DISPLAY)
# =============================================================================

set -e

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ─── Root check ───────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Please run as root (use sudo)"
  exit 1
fi

# ─── Helper: read with a prompt, re-ask if empty ──────────────────────────────
ask() {
  local prompt="$1"
  local varname="$2"
  local value=""
  while [ -z "$value" ]; do
    read -rp "$prompt" value </dev/tty
    [ -z "$value" ] && echo "  (cannot be empty, please try again)"
  done
  printf -v "$varname" '%s' "$value"
}

# ─── Interactive prompts ───────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  MSF Panel Setup — Interactive Installer"
echo "=========================================="
echo ""

ask "  Panel ID (e.g. 206072): " PANEL_ID
ask "  API host URL (e.g. https://msfdemo.com/api/): " API_HOST

echo ""
read -rp "  Use Cloudflare tunnel? [y/N]: " USE_TUNNEL_RAW </dev/tty
USE_TUNNEL_RAW="${USE_TUNNEL_RAW,,}"   # lowercase

MYSQL_TUNNEL_HOST=""
RABBIT_TUNNEL_HOST=""
if [[ "$USE_TUNNEL_RAW" == "y" || "$USE_TUNNEL_RAW" == "yes" ]]; then
  USE_TUNNEL=true
  ask "  MySQL tunnel hostname (e.g. msfdemo-my.msfdemo.com): " MYSQL_TUNNEL_HOST
  ask "  RabbitMQ tunnel hostname (e.g. msfdemo-rmq.msfdemo.com): " RABBIT_TUNNEL_HOST
else
  USE_TUNNEL=false
fi

echo ""
echo "=========================================="
echo "  Configuration summary"
echo "=========================================="
echo "  Panel ID:   $PANEL_ID"
echo "  API host:   $API_HOST"
if [ "$USE_TUNNEL" = true ]; then
  echo "  MySQL tunnel:   $MYSQL_TUNNEL_HOST → localhost:3306"
  echo "  RabbitMQ tunnel: $RABBIT_TUNNEL_HOST → localhost:5672"
else
  echo "  Tunnel:     none"
fi
echo "=========================================="
echo ""
read -rp "  Proceed with installation? [Y/n]: " CONFIRM </dev/tty
CONFIRM="${CONFIRM,,}"
if [[ "$CONFIRM" == "n" || "$CONFIRM" == "no" ]]; then
  echo "Aborted."
  exit 0
fi
echo ""

# ─── Step 1: Install required packages ────────────────────────────────────────
echo "==> Installing required packages..."
apt-get update -qq
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
  curl wget dos2unix jq openjdk-17-jre supervisor 2>&1 | tail -3

# ─── Step 2: Install cloudflared (only if tunnel requested) ───────────────────
if [ "$USE_TUNNEL" = true ]; then
  if ! command -v cloudflared &>/dev/null; then
    echo "==> Installing cloudflared..."
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
      -o /tmp/cloudflared.deb
    dpkg -i /tmp/cloudflared.deb
    rm /tmp/cloudflared.deb
  else
    echo "==> cloudflared already installed."
  fi

  # ─── Step 3: Setup Cloudflare tunnel systemd service ──────────────────────
  echo "==> Setting up Cloudflare tunnels..."
  echo "    MySQL:    ${MYSQL_TUNNEL_HOST} → localhost:3306"
  echo "    RabbitMQ: ${RABBIT_TUNNEL_HOST} → localhost:5672"
  cat > /etc/systemd/system/msf-tunnels.service << EOF
[Unit]
Description=MSF Cloudflare Access Tunnels (MySQL + RabbitMQ)
After=network.target

[Service]
Type=simple
ExecStart=/bin/sh -c '/usr/local/bin/cloudflared access tcp --hostname ${MYSQL_TUNNEL_HOST} --url localhost:3306 & /usr/local/bin/cloudflared access tcp --hostname ${RABBIT_TUNNEL_HOST} --url localhost:5672 & wait'
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable msf-tunnels.service
  systemctl restart msf-tunnels.service

  echo "==> Waiting for tunnel to come up..."
  sleep 5
else
  echo "==> Skipping tunnel setup."
  # Disable any previously installed tunnel service if present
  if systemctl is-enabled msf-tunnels.service &>/dev/null 2>&1; then
    systemctl disable --now msf-tunnels.service 2>/dev/null || true
  fi
fi

# ─── Step 4: Setup meta user + hardware permissions ───────────────────────────
echo "==> Setting up meta user + hardware permissions..."
if ! id -u meta &>/dev/null; then
  useradd -m -s /bin/bash meta || true
fi
usermod -aG dialout meta 2>/dev/null || true

echo -1 > /sys/module/usbcore/parameters/autosuspend 2>/dev/null || true
modprobe usbcore autosuspend=-1 2>/dev/null || true
chmod 660 /dev/tty* 2>/dev/null || true
chgrp dialout /dev/tty* 2>/dev/null || true

# ─── Step 5: Download meta.jar + helper scripts ───────────────────────────────
META_HOME="/opt/meta"
mkdir -p "$META_HOME/conf"

echo "==> Downloading meta.jar + scripts from nuriozalp/download..."
HARDWARE_SCRIPTS_URL="https://github.com/nuriozalp/download/raw/master/test"

for script in meta.sh udev.sh rfid.sh barcode.sh grant_meta_tty_permissions.sh; do
  echo "  - $script"
  wget -q -O "$META_HOME/$script" "$HARDWARE_SCRIPTS_URL/$script" || echo "  WARN: $script not found"
  [ -f "$META_HOME/$script" ] && dos2unix "$META_HOME/$script" 2>/dev/null && chmod +x "$META_HOME/$script"
done

echo "  - logback.xml"
wget -q -O "$META_HOME/conf/logback.xml" "$HARDWARE_SCRIPTS_URL/logback.xml" || true
[ -f "$META_HOME/conf/logback.xml" ] && dos2unix "$META_HOME/conf/logback.xml" 2>/dev/null

echo "==> Downloading latest meta.jar..."
LATEST_TAG=$(wget -qO- "https://api.github.com/repos/nuriozalp/download/releases/latest" | jq -r '.tag_name')
if [ -n "$LATEST_TAG" ] && [ "$LATEST_TAG" != "null" ]; then
  echo "  - version: $LATEST_TAG"
  wget -q -O "$META_HOME/meta.jar" \
    "https://github.com/nuriozalp/download/releases/download/${LATEST_TAG}/meta.jar"
  echo "  - meta.jar saved ($(du -h "$META_HOME/meta.jar" | cut -f1))"
else
  echo "ERROR: could not detect latest meta.jar release tag"
  exit 1
fi

# ─── Step 6: Run hardware setup scripts ───────────────────────────────────────
echo "==> Running hardware setup scripts..."
[ -x "$META_HOME/udev.sh" ]                       && "$META_HOME/udev.sh"                       || true
[ -x "$META_HOME/rfid.sh" ]                       && "$META_HOME/rfid.sh"                       || true
[ -x "$META_HOME/barcode.sh" ]                    && "$META_HOME/barcode.sh"                    || true
[ -x "$META_HOME/grant_meta_tty_permissions.sh" ] && "$META_HOME/grant_meta_tty_permissions.sh" || true

# ─── Step 7: Write /opt/meta/conf/system.ini (only host + panelId) ────────────
echo "==> Writing $META_HOME/conf/system.ini..."
SYSTEM_INI="$META_HOME/conf/system.ini"

# Backup existing system.ini if present
if [ -f "$SYSTEM_INI" ]; then
  cp "$SYSTEM_INI" "${SYSTEM_INI}_backup_$(date +%s)"
fi

# Write a clean system.ini with ONLY the two required keys
cat > "$SYSTEM_INI" << EOF
#$(date)
host=${API_HOST}
settings.panelId=${PANEL_ID}
EOF

chown -R meta:meta "$META_HOME"
chmod 755 "$META_HOME/meta.jar" 2>/dev/null || true

echo ""
echo "  --- system.ini contents ---"
grep -v "^#" "$SYSTEM_INI"
echo ""

# ─── Step 8: Setup supervisord service for meta.jar ───────────────────────────
echo "==> Configuring supervisord to auto-start panel..."

PANEL_DISPLAY="${DISPLAY:-:0}"

cat > /etc/supervisor/conf.d/meta.conf << EOF
[program:meta]
command=/usr/bin/java -Djava.library.path=/usr/lib/jni:lib -jar /opt/meta/meta.jar
directory=/opt/meta
user=meta
environment=DISPLAY="${PANEL_DISPLAY}",HOME="/home/meta",XAUTHORITY="/home/meta/.Xauthority"
autostart=true
autorestart=true
startsecs=10
stopsignal=TERM
stopwaitsecs=10
stdout_logfile=/var/log/supervisor/meta.out.log
stderr_logfile=/var/log/supervisor/meta.err.log
stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB
EOF

systemctl enable supervisor
systemctl restart supervisor

xhost +local: 2>/dev/null || true

supervisorctl reread
supervisorctl update
supervisorctl restart meta 2>/dev/null || supervisorctl start meta

echo ""
echo "=========================================="
echo "  Setup Complete!"
echo "=========================================="
echo ""
echo "  Panel auto-starts on boot via supervisord."
echo ""
echo "  Status:    sudo supervisorctl status meta"
echo "  Restart:   sudo supervisorctl restart meta"
echo "  Stop:      sudo supervisorctl stop meta"
echo "  Logs:      sudo tail -f /var/log/supervisor/meta.out.log"
echo "  Errors:    sudo tail -f /var/log/supervisor/meta.err.log"
if [ "$USE_TUNNEL" = true ]; then
echo "  Tunnels:   sudo systemctl status msf-tunnels"
fi
echo "  Config:    sudo nano /opt/meta/conf/system.ini"
echo ""
echo "  (After editing system.ini: sudo supervisorctl restart meta)"
echo ""
