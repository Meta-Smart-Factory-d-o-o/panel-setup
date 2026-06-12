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

# ─── Remote-access tools (optional) ────────────────────────────────────────────
echo ""
read -rp "  Install RustDesk (remote access)? [y/N]: " INSTALL_RUSTDESK_RAW </dev/tty
INSTALL_RUSTDESK_RAW="${INSTALL_RUSTDESK_RAW,,}"
if [[ "$INSTALL_RUSTDESK_RAW" == "y" || "$INSTALL_RUSTDESK_RAW" == "yes" ]]; then
  INSTALL_RUSTDESK=true
else
  INSTALL_RUSTDESK=false
fi

read -rp "  Install AnyDesk (remote access)? [y/N]: " INSTALL_ANYDESK_RAW </dev/tty
INSTALL_ANYDESK_RAW="${INSTALL_ANYDESK_RAW,,}"
if [[ "$INSTALL_ANYDESK_RAW" == "y" || "$INSTALL_ANYDESK_RAW" == "yes" ]]; then
  INSTALL_ANYDESK=true
else
  INSTALL_ANYDESK=false
fi

# ─── PLC integration (optional) ────────────────────────────────────────────────
read -rp "  Does this panel talk to a PLC? (installs Python + pycomm3/snap7) [y/N]: " INSTALL_PLC_RAW </dev/tty
INSTALL_PLC_RAW="${INSTALL_PLC_RAW,,}"
if [[ "$INSTALL_PLC_RAW" == "y" || "$INSTALL_PLC_RAW" == "yes" ]]; then
  INSTALL_PLC=true
else
  INSTALL_PLC=false
fi

# ─── MQTT broker (optional) ─────────────────────────────────────────────────────
read -rp "  Install Mosquitto MQTT broker? [y/N]: " INSTALL_MQTT_RAW </dev/tty
INSTALL_MQTT_RAW="${INSTALL_MQTT_RAW,,}"
if [[ "$INSTALL_MQTT_RAW" == "y" || "$INSTALL_MQTT_RAW" == "yes" ]]; then
  INSTALL_MQTT=true
else
  INSTALL_MQTT=false
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
echo "  RustDesk:   $([ "$INSTALL_RUSTDESK" = true ] && echo "yes" || echo "no")"
echo "  AnyDesk:    $([ "$INSTALL_ANYDESK" = true ] && echo "yes" || echo "no")"
echo "  PLC (Python): $([ "$INSTALL_PLC" = true ] && echo "yes" || echo "no")"
echo "  Mosquitto:  $([ "$INSTALL_MQTT" = true ] && echo "yes" || echo "no")"
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
# Tolerate broken/stale third-party apt sources (e.g. a leftover anydesk repo) —
# a single bad Release file must not abort the whole installer.
apt-get update -qq || {
  echo "  WARN: 'apt-get update' reported errors (likely a broken third-party repo)."
  echo "        Continuing — required packages are pulled from the base Ubuntu repos."
}
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

# ─── Step 3b: Install remote-access tools (optional) ──────────────────────────
if [ "$INSTALL_RUSTDESK" = true ]; then
  if command -v rustdesk &>/dev/null; then
    echo "==> RustDesk already installed."
  else
    echo "==> Installing RustDesk..."
    RD_DEB=$(wget -qO- "https://api.github.com/repos/rustdesk/rustdesk/releases/latest" \
      | jq -r '.assets[].browser_download_url' | grep -E 'x86_64\.deb$' | head -1)
    if [ -n "$RD_DEB" ]; then
      wget -q -O /tmp/rustdesk.deb "$RD_DEB"
      apt-get install -y /tmp/rustdesk.deb 2>&1 | tail -2 || dpkg -i /tmp/rustdesk.deb || true
      rm -f /tmp/rustdesk.deb
    else
      echo "  WARN: could not find a RustDesk x86_64 .deb in the latest release"
    fi
  fi
fi

if [ "$INSTALL_ANYDESK" = true ]; then
  if command -v anydesk &>/dev/null; then
    echo "==> AnyDesk already installed."
  else
    echo "==> Installing AnyDesk..."
    install -m 0755 -d /etc/apt/keyrings
    wget -qO- https://keys.anydesk.com/repos/DEB-GPG-KEY \
      | gpg --dearmor -o /etc/apt/keyrings/anydesk.gpg 2>/dev/null || true
    echo "deb [signed-by=/etc/apt/keyrings/anydesk.gpg] http://deb.anydesk.com/ all main" \
      > /etc/apt/sources.list.d/anydesk-stable.list
    apt-get update -qq 2>/dev/null || true
    apt-get install -y anydesk 2>&1 | tail -2 || echo "  WARN: AnyDesk apt install failed"
  fi
fi

# ─── Step 3c: Install Mosquitto MQTT broker (optional) ────────────────────────
if [ "$INSTALL_MQTT" = true ]; then
  if command -v mosquitto &>/dev/null; then
    echo "==> Mosquitto already installed."
  else
    echo "==> Installing Mosquitto MQTT broker..."
    apt-get install -y mosquitto mosquitto-clients 2>&1 | tail -2 || \
      echo "  WARN: Mosquitto apt install failed"
  fi
  systemctl enable mosquitto 2>/dev/null || true
  systemctl restart mosquitto 2>/dev/null || true
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

# ─── Step 5b: Setup Python venv + PLC packages (only if panel uses a PLC) ──────
if [ "$INSTALL_PLC" = true ]; then
  echo "==> Setting up Python venv for PLC integration..."
  PLC_VENV="$META_HOME/plc-venv"

  # Python toolchain (only needed when a PLC is present)
  apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    python3 python3-venv python3-pip software-properties-common 2>&1 | tail -2

  if [ ! -d "$PLC_VENV" ]; then
    python3 -m venv "$PLC_VENV"
  fi

  # Install the native snap7 shared library (libsnap7). Modern python-snap7 (>=1.x)
  # bundles it in the wheel, but older releases load it from the system — so we
  # install it from the snap7 PPA to be safe. Non-fatal if the PPA is unavailable.
  if ! ldconfig -p 2>/dev/null | grep -q libsnap7; then
    echo "==> Installing native libsnap7..."
    add-apt-repository -y ppa:gijzelaerr/snap7 2>/dev/null || true
    apt-get update -qq 2>/dev/null || true
    apt-get install -y libsnap7-1 libsnap7-dev 2>&1 | tail -2 || \
      echo "  WARN: libsnap7 apt install failed — relying on the wheel-bundled lib"
  fi

  # Upgrade pip and install the PLC client libraries used by the integration scripts:
  #   pycomm3       → Allen-Bradley / Rockwell Logix PLCs (LogixDriver)
  #   python-snap7  → Siemens S7 PLCs (snap7 client; ships the native lib in the wheel)
  "$PLC_VENV/bin/pip" install --upgrade pip 2>&1 | tail -1
  "$PLC_VENV/bin/pip" install pycomm3 python-snap7 2>&1 | tail -3

  echo "  - venv python: $("$PLC_VENV/bin/python" --version 2>&1)"
  echo "  - installed:   $("$PLC_VENV/bin/pip" list 2>/dev/null | grep -iE 'pycomm3|snap7' | tr '\n' ' ')"
else
  echo "==> No PLC — skipping Python/PLC package setup."
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

# Wait for supervisord's control socket to come up before talking to it.
# Right after 'systemctl restart', supervisorctl can race the daemon and fail
# with: FileNotFoundError ... supervisor/xmlrpc.py (socket not created yet).
echo "==> Waiting for supervisord socket..."
for i in $(seq 1 15); do
  if supervisorctl status &>/dev/null; then
    break
  fi
  sleep 1
done

supervisorctl reread || true
supervisorctl update || true
supervisorctl restart meta 2>/dev/null || supervisorctl start meta || true

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
