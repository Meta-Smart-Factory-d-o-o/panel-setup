#!/bin/bash
# =============================================================================
# MSF Panel — One-Command Installer (uses dass-desktop image)
#
# This installer:
#  1. Installs Docker + cloudflared (if missing)
#  2. Sets up Cloudflare access tunnels for MySQL + RabbitMQ
#  3. Creates /opt/meta-panel/.env with DASS_* env vars (override system.ini)
#  4. Logs in to GHCR (private image)
#  5. Pulls ghcr.io/meta-smart-factory-d-o-o/dass-desktop:latest
#  6. Starts the container
#
# Override pattern (handled by dass-desktop entrypoint):
#   DASS_<key with __ instead of .>=value  →  <key>=value in system.ini
#   Example: DASS_mysql__datasource__password=secret
#            → mysql.datasource.password=secret
# =============================================================================

set -e

# --- Required (panel-specific) ---
CLIENT=""
WORKSTATION_ID=""
PANEL_ID=""
CUSTOMER_NAME=""

# --- MySQL (can be updated later via .env) ---
MYSQL_HOST=""
MYSQL_PORT="3306"
MYSQL_DB=""
MYSQL_USER="root"
MYSQL_PASSWORD=""

# --- RabbitMQ (defaults work for most clients) ---
RABBIT_HOST=""
RABBIT_PORT="5672"
RABBIT_USER="dass"
RABBIT_PASSWORD=""

# --- GHCR (image is private) ---
GHCR_USER=""
GHCR_TOKEN=""

REPO_OWNER="meta-smart-factory-d-o-o"
REPO_NAME="panel-setup"
RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main"

# --- Parse args ---
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --client) CLIENT="$2"; shift ;;
    --workstation-id) WORKSTATION_ID="$2"; shift ;;
    --panel-id) PANEL_ID="$2"; shift ;;
    --customer) CUSTOMER_NAME="$2"; shift ;;
    --mysql-host) MYSQL_HOST="$2"; shift ;;
    --mysql-port) MYSQL_PORT="$2"; shift ;;
    --mysql-db) MYSQL_DB="$2"; shift ;;
    --mysql-user) MYSQL_USER="$2"; shift ;;
    --mysql-password) MYSQL_PASSWORD="$2"; shift ;;
    --rabbit-host) RABBIT_HOST="$2"; shift ;;
    --rabbit-port) RABBIT_PORT="$2"; shift ;;
    --rabbit-user) RABBIT_USER="$2"; shift ;;
    --rabbit-password) RABBIT_PASSWORD="$2"; shift ;;
    --ghcr-user) GHCR_USER="$2"; shift ;;
    --ghcr-token) GHCR_TOKEN="$2"; shift ;;
    -h|--help)
      cat << EOF
MSF Panel Installer

Required:
  --client <name>           Client name (norma|simsek|mc4|msfdemo)
                            'msfdemo' = MSF 209 test server (direct IP, no tunnel)
  --workstation-id <id>     Unique workstation ID
  --panel-id <id>           Unique panel ID
  --mysql-db <name>         MySQL database name
  --mysql-password <pwd>    MySQL password
  --rabbit-password <pwd>   RabbitMQ password
  --ghcr-user <user>        GitHub username
  --ghcr-token <token>      GitHub Personal Access Token (read:packages scope)

Optional:
  --customer <name>         Default: same as --client
  --mysql-host <host>       Default: localhost (Cloudflare tunnel)
  --mysql-port <port>       Default: 3306
  --mysql-user <user>       Default: root
  --rabbit-host <host>      Default: localhost (Cloudflare tunnel)
  --rabbit-port <port>      Default: 5672
  --rabbit-user <user>      Default: dass

All values can be updated later by editing /opt/meta-panel/.env then:
  cd /opt/meta-panel && docker compose up -d
EOF
      exit 0
      ;;
    *) echo "Unknown parameter: $1"; echo "Run with --help for usage"; exit 1 ;;
  esac
  shift
done

# --- Interactive prompts for missing required values ---
[ -z "$CLIENT" ]          && read -p "Client (norma/simsek/mc4): " CLIENT
[ -z "$WORKSTATION_ID" ]  && read -p "Workstation ID: " WORKSTATION_ID
if [ -z "$PANEL_ID" ]; then
  read -p "Panel ID [$WORKSTATION_ID]: " PANEL_ID
  PANEL_ID=${PANEL_ID:-$WORKSTATION_ID}
fi
[ -z "$MYSQL_DB" ]        && read -p "MySQL database name: " MYSQL_DB
[ -z "$MYSQL_PASSWORD" ]  && { read -sp "MySQL password: " MYSQL_PASSWORD; echo; }
[ -z "$RABBIT_PASSWORD" ] && { read -sp "RabbitMQ password: " RABBIT_PASSWORD; echo; }
[ -z "$GHCR_USER" ]       && read -p "GitHub username: " GHCR_USER
[ -z "$GHCR_TOKEN" ]      && { read -sp "GitHub PAT (read:packages): " GHCR_TOKEN; echo; }
[ -z "$CUSTOMER_NAME" ]   && CUSTOMER_NAME=$CLIENT

# --- Client → tunnel hostname mapping ---
# Production clients use Cloudflare tunnels to reach their MySQL/RabbitMQ.
# 'msfdemo' is NOT a real customer — it is MSF's own test/demo server (209.250.235.243)
# used for QA, demos, and validating new features before rolling out to real clients.
USE_TUNNELS="true"
case "$CLIENT" in
  norma)
    MYSQL_TUNNEL_HOST="norma-mysql.msfdemo.com"
    RABBIT_TUNNEL_HOST="norma-rabbitmq.msfdemo.com"
    ;;
  simsek)
    MYSQL_TUNNEL_HOST="simsek-mysql.msfdemo.com"
    RABBIT_TUNNEL_HOST="simsek-rabbitmq.msfdemo.com"
    ;;
  mc4)
    MYSQL_TUNNEL_HOST="mc4-mysql.msfdemo.com"
    RABBIT_TUNNEL_HOST="mc4-rabbitmq.msfdemo.com"
    ;;
  msfdemo)
    # TEST/DEMO ONLY — MSF 209 server. Panel runs ON the same machine as
    # MySQL/RabbitMQ, so use localhost directly (no Cloudflare tunnel needed).
    # Do NOT use this for production customer deployments.
    USE_TUNNELS="false"
    MYSQL_TUNNEL_HOST="(localhost — same machine)"
    RABBIT_TUNNEL_HOST="(localhost — same machine)"
    echo ""
    echo "*** WARNING: 'msfdemo' is MSF's internal test server — not a real customer. ***"
    echo ""
    ;;
  *)
    echo "ERROR: Unknown client '$CLIENT'. Supported: norma, simsek, mc4, msfdemo (test)"
    exit 1
    ;;
esac

# Default hosts to localhost (tunnels forward to actual server)
[ -z "$MYSQL_HOST" ]  && MYSQL_HOST="localhost"
[ -z "$RABBIT_HOST" ] && RABBIT_HOST="localhost"

echo ""
echo "=========================================="
echo "  MSF Panel Setup (dass-desktop)"
echo "=========================================="
echo "  Client:         $CLIENT"
echo "  Workstation ID: $WORKSTATION_ID"
echo "  Panel ID:       $PANEL_ID"
echo "  MySQL DB:       $MYSQL_DB"
if [ "$USE_TUNNELS" = "true" ]; then
  echo "  MySQL Tunnel:   $MYSQL_TUNNEL_HOST → localhost:3306"
  echo "  RabbitMQ Tun.:  $RABBIT_TUNNEL_HOST → localhost:5672"
else
  echo "  MySQL Host:     $MYSQL_HOST:$MYSQL_PORT (direct, no tunnel)"
  echo "  RabbitMQ Host:  $RABBIT_HOST:$RABBIT_PORT (direct, no tunnel)"
fi
echo "=========================================="
echo ""

# --- Require root ---
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Please run as root (use sudo)"
  exit 1
fi

# --- Step 1: Install Docker ---
if ! command -v docker &> /dev/null; then
  echo "==> Installing Docker..."
  curl -fsSL https://get.docker.com | sh
else
  echo "==> Docker already installed."
fi

# --- Step 2: Install cloudflared (only if tunnels are used) ---
if [ "$USE_TUNNELS" = "true" ]; then
  if ! command -v cloudflared &> /dev/null; then
    echo "==> Installing cloudflared..."
    apt-get update -qq
    apt-get install -y curl
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
    dpkg -i /tmp/cloudflared.deb
    rm /tmp/cloudflared.deb
  else
    echo "==> cloudflared already installed."
  fi

  # --- Step 3: Setup Cloudflare tunnels (MySQL + RabbitMQ) ---
  echo "==> Setting up Cloudflare tunnels..."
  cat > /etc/systemd/system/msf-tunnels.service << EOF
[Unit]
Description=MSF Cloudflare Access Tunnels for ${CLIENT}
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

  echo "==> Waiting for tunnels to come up..."
  sleep 5
else
  echo "==> Skipping cloudflared setup (client uses direct IP, not tunnel)"
fi

# --- Step 4: Create panel directory and .env ---
echo "==> Creating panel configuration..."
PANEL_DIR="/opt/meta-panel"
mkdir -p $PANEL_DIR
cd $PANEL_DIR

# Build JDBC URL (per developer recommendation — simpler with timeouts)
JDBC_URL="jdbc:mysql://${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DB}?useSSL=false&connectTimeout=10000&socketTimeout=10000&autoReconnect=true&allowPublicKeyRetrieval=true"

cat > .env << EOF
# =========================================================================
# Panel Configuration
# Override system.ini values via DASS_* env vars (handled by dass-desktop
# entrypoint.sh — converts DASS_a__b__c → a.b.c=value in system.ini).
#
# To update any value: edit this file then run:
#   cd /opt/meta-panel && docker compose up -d
# =========================================================================

# --- Panel-Specific ---
DASS_settings__workstationId=${WORKSTATION_ID}
DASS_settings__panelId=${PANEL_ID}
DASS_customerName=${CUSTOMER_NAME}

# --- MySQL ---
DASS_mysql__datasource__jdbcUrl=${JDBC_URL}
DASS_mysql__datasource__username=${MYSQL_USER}
DASS_mysql__datasource__password=${MYSQL_PASSWORD}

# --- RabbitMQ ---
DASS_rabbit__host=${RABBIT_HOST}
DASS_rabbit__port=${RABBIT_PORT}
DASS_rabbit__username=${RABBIT_USER}
DASS_rabbit__password=${RABBIT_PASSWORD}
# Disable SSL for RabbitMQ (default system.ini has this true, but Norma/msfdemo do not use SSL)
DASS_rabbit__useSslProtocol=false

# --- MSF API host (override panel's host= field) ---
DASS_host=http://localhost:7189/
EOF

chmod 600 .env

# --- Step 5: Install hardware support scripts on HOST (not in container) ---
# These scripts manage USB devices (barcode/RFID readers), udev rules, and
# TTY permissions. They must run on the host system, not inside Docker.
echo "==> Installing hardware support scripts on host..."
META_HOME="/opt/meta"
mkdir -p "$META_HOME/conf"

# Create meta user if it doesn't exist (needed by hardware scripts)
if ! id -u meta &>/dev/null; then
  echo "==> Creating 'meta' user..."
  useradd -m -s /bin/bash meta || true
fi

# Add meta user to dialout (needed for serial/USB device access)
usermod -aG dialout meta 2>/dev/null || true

# Install dependencies for hardware scripts
apt-get install -y dos2unix jq wget 2>/dev/null || true

# Download hardware scripts + meta.sh + logback.xml from official MSF distribution
# (same source meta.sh uses — github.com/nuriozalp/download/test/)
HARDWARE_SCRIPTS_URL="https://github.com/nuriozalp/download/raw/master/test"

# Scripts to install in /opt/meta/
for script in meta.sh udev.sh rfid.sh barcode.sh grant_meta_tty_permissions.sh; do
  echo "  - Downloading $script..."
  if wget -q -O "$META_HOME/$script.tmp" "$HARDWARE_SCRIPTS_URL/$script"; then
    mv "$META_HOME/$script.tmp" "$META_HOME/$script"
    dos2unix "$META_HOME/$script" 2>/dev/null || true
    chmod +x "$META_HOME/$script"
  else
    echo "  WARN: $script not found in remote — skipping"
    rm -f "$META_HOME/$script.tmp"
  fi
done

# logback.xml goes into /opt/meta/conf/ (matching meta.sh behavior)
echo "  - Downloading logback.xml..."
if wget -q -O "$META_HOME/conf/logback.xml.tmp" "$HARDWARE_SCRIPTS_URL/logback.xml"; then
  mv "$META_HOME/conf/logback.xml.tmp" "$META_HOME/conf/logback.xml"
  dos2unix "$META_HOME/conf/logback.xml" 2>/dev/null || true
else
  echo "  WARN: logback.xml not found — skipping"
  rm -f "$META_HOME/conf/logback.xml.tmp"
fi

# USB autosuspend settings (required for stable USB device behavior)
echo -1 > /sys/module/usbcore/parameters/autosuspend 2>/dev/null || true
modprobe usbcore autosuspend=-1 2>/dev/null || true

# TTY permissions for hardware devices
chmod 777 /dev/tty* 2>/dev/null || true

# Optional: Download meta.jar to /opt/meta/ as a backup
# (the running container uses its own bundled JAR; this is for emergency manual run)
echo "==> Downloading meta.jar backup..."
LATEST_TAG=$(wget -qO- "https://api.github.com/repos/nuriozalp/download/releases/latest" 2>/dev/null | jq -r '.tag_name' 2>/dev/null || echo "")
if [ -n "$LATEST_TAG" ] && [ "$LATEST_TAG" != "null" ]; then
  echo "  - Latest version: $LATEST_TAG"
  if wget -q -O "$META_HOME/meta.jar.tmp" "https://github.com/nuriozalp/download/releases/download/${LATEST_TAG}/meta.jar"; then
    mv "$META_HOME/meta.jar.tmp" "$META_HOME/meta.jar"
    echo "  - meta.jar backup saved to $META_HOME/meta.jar"
  else
    echo "  WARN: meta.jar backup download failed — skipping (container has its own)"
    rm -f "$META_HOME/meta.jar.tmp"
  fi
else
  echo "  WARN: could not detect latest release tag — skipping JAR backup"
fi

# Run hardware setup scripts (these install udev rules, set permissions, etc.)
echo "==> Running hardware setup scripts..."
[ -x "$META_HOME/udev.sh" ]                       && "$META_HOME/udev.sh"                       || true
[ -x "$META_HOME/rfid.sh" ]                       && "$META_HOME/rfid.sh"                       || true
[ -x "$META_HOME/barcode.sh" ]                    && "$META_HOME/barcode.sh"                    || true
[ -x "$META_HOME/grant_meta_tty_permissions.sh" ] && "$META_HOME/grant_meta_tty_permissions.sh" || true

chown -R meta:meta "$META_HOME" 2>/dev/null || true

# --- Step 6: Download docker-compose.yml ---
echo "==> Downloading docker-compose.yml..."
curl -sSL "${RAW_BASE}/docker-compose.yml" -o docker-compose.yml

# --- Step 7: Login to GHCR (image is private) ---
echo "==> Logging in to GHCR..."
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

# --- Step 8: Allow Docker to access X display (for GUI) ---
echo "==> Allowing Docker GUI access..."
xhost +local:docker 2>/dev/null || true

# --- Step 9: Pull and start the panel ---
echo "==> Pulling dass-desktop image..."
docker compose pull
echo "==> Starting panel..."
docker compose up -d

echo ""
echo "=========================================="
echo "  Setup Complete!"
echo "=========================================="
echo ""
echo "  Panel directory:    $PANEL_DIR"
echo "  Hardware scripts:   $META_HOME"
echo ""
echo "  View logs:          docker compose -f $PANEL_DIR/docker-compose.yml logs -f"
echo "  Restart:            docker compose -f $PANEL_DIR/docker-compose.yml restart"
echo "  Stop:               docker compose -f $PANEL_DIR/docker-compose.yml down"
echo "  Update vars:        nano $PANEL_DIR/.env && docker compose up -d"
echo "  Re-run hw scripts:  sudo $META_HOME/udev.sh && sudo $META_HOME/rfid.sh"
echo ""
