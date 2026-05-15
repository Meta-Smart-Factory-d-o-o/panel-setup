#!/bin/bash
# =============================================================================
# MSF Panel — One-Command Installer (HOST mode, no Docker)
#
# This installer:
#  1. Installs Cloudflare access tunnels for MySQL + RabbitMQ (no Docker needed)
#  2. Downloads meta.jar + all helper scripts (meta.sh, udev.sh, rfid.sh,
#     barcode.sh, grant_meta_tty_permissions.sh, logback.xml) to /opt/meta/
#  3. Configures /opt/meta/conf/system.ini with client-specific values
#  4. Sets up the 'meta' user, hardware permissions, USB autosuspend
#  5. Installs supervisord and registers meta.jar as an auto-start service
#
# Result: Panel GUI starts on real display (DISPLAY=:0) like the old meta.sh
# flow — no Docker container, no Xvfb virtual display.
# =============================================================================

set -e

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# --- Required (panel-specific) ---
CLIENT=""
WORKSTATION_ID=""
PANEL_ID=""

# --- MySQL ---
MYSQL_HOST=""
MYSQL_PORT="3306"
MYSQL_DB=""
MYSQL_USER="root"
MYSQL_PASSWORD=""

# --- RabbitMQ ---
RABBIT_HOST=""
RABBIT_PORT="5672"
RABBIT_USER="dass"
RABBIT_PASSWORD=""

# --- Parse args ---
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --client) CLIENT="$2"; shift ;;
    --workstation-id) WORKSTATION_ID="$2"; shift ;;
    --panel-id) PANEL_ID="$2"; shift ;;
    --mysql-host) MYSQL_HOST="$2"; shift ;;
    --mysql-port) MYSQL_PORT="$2"; shift ;;
    --mysql-db) MYSQL_DB="$2"; shift ;;
    --mysql-user) MYSQL_USER="$2"; shift ;;
    --mysql-password) MYSQL_PASSWORD="$2"; shift ;;
    --rabbit-host) RABBIT_HOST="$2"; shift ;;
    --rabbit-port) RABBIT_PORT="$2"; shift ;;
    --rabbit-user) RABBIT_USER="$2"; shift ;;
    --rabbit-password) RABBIT_PASSWORD="$2"; shift ;;
    -h|--help)
      cat << EOF
MSF Panel Installer (HOST mode — runs meta.jar directly, no Docker)

Required:
  --client <name>           Client name (norma|simsek|mc4|msfdemo)
                            'msfdemo' = MSF internal test server
  --workstation-id <id>     Unique workstation ID
  --panel-id <id>           Unique panel ID
  --mysql-db <name>         MySQL database name
  --mysql-password <pwd>    MySQL password
  --rabbit-password <pwd>   RabbitMQ password

Optional:
  --mysql-host <host>       Default: localhost (via Cloudflare tunnel)
  --mysql-port <port>       Default: 3306
  --mysql-user <user>       Default: root
  --rabbit-host <host>      Default: localhost (via Cloudflare tunnel)
  --rabbit-port <port>      Default: 5672
  --rabbit-user <user>      Default: dass

After install, the panel auto-starts on next boot.
Manage with:  sudo supervisorctl status meta
              sudo supervisorctl restart meta
              sudo supervisorctl tail -f meta
EOF
      exit 0
      ;;
    *) echo "Unknown parameter: $1"; echo "Run with --help for usage"; exit 1 ;;
  esac
  shift
done

# --- Interactive prompts for missing values ---
[ -z "$CLIENT" ]          && read -p "Client (norma/simsek/mc4/msfdemo): " CLIENT
[ -z "$WORKSTATION_ID" ]  && read -p "Workstation ID: " WORKSTATION_ID
if [ -z "$PANEL_ID" ]; then
  read -p "Panel ID [$WORKSTATION_ID]: " PANEL_ID
  PANEL_ID=${PANEL_ID:-$WORKSTATION_ID}
fi
[ -z "$MYSQL_DB" ]        && read -p "MySQL database name: " MYSQL_DB
[ -z "$MYSQL_PASSWORD" ]  && { read -sp "MySQL password: " MYSQL_PASSWORD; echo; }
[ -z "$RABBIT_PASSWORD" ] && { read -sp "RabbitMQ password: " RABBIT_PASSWORD; echo; }

# --- Client → tunnel hostname mapping ---
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
    MYSQL_TUNNEL_HOST="msfdemo-mysql.msfdemo.com"
    RABBIT_TUNNEL_HOST="msfdemo-rmq.msfdemo.com"
    echo ""
    echo "*** NOTE: 'msfdemo' is MSF's internal test server — not a real customer. ***"
    echo ""
    ;;
  *)
    echo "ERROR: Unknown client '$CLIENT'. Supported: norma, simsek, mc4, msfdemo"
    exit 1
    ;;
esac

[ -z "$MYSQL_HOST" ]  && MYSQL_HOST="localhost"
[ -z "$RABBIT_HOST" ] && RABBIT_HOST="localhost"

echo ""
echo "=========================================="
echo "  MSF Panel Setup (HOST mode)"
echo "=========================================="
echo "  Client:         $CLIENT"
echo "  Workstation ID: $WORKSTATION_ID"
echo "  Panel ID:       $PANEL_ID"
echo "  MySQL DB:       $MYSQL_DB"
echo "  MySQL Tunnel:   $MYSQL_TUNNEL_HOST → localhost:3306"
echo "  RabbitMQ Tun.:  $RABBIT_TUNNEL_HOST → localhost:5672"
echo "=========================================="
echo ""

if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Please run as root (use sudo)"
  exit 1
fi

# --- Step 1: Install required packages ---
echo "==> Installing required packages..."
apt-get update -qq
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
  curl wget dos2unix jq openjdk-17-jre-headless supervisor 2>&1 | tail -3

# Java with GUI support (not the headless one — we need AWT)
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
  openjdk-17-jre 2>&1 | tail -3

# --- Step 2: Install cloudflared ---
if ! command -v cloudflared &> /dev/null; then
  echo "==> Installing cloudflared..."
  curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
  dpkg -i /tmp/cloudflared.deb
  rm /tmp/cloudflared.deb
else
  echo "==> cloudflared already installed."
fi

# --- Step 3: Setup Cloudflare tunnels ---
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

# --- Step 4: Setup meta user + hardware permissions ---
echo "==> Setting up meta user + hardware permissions..."
if ! id -u meta &>/dev/null; then
  useradd -m -s /bin/bash meta || true
fi
usermod -aG dialout meta 2>/dev/null || true

echo -1 > /sys/module/usbcore/parameters/autosuspend 2>/dev/null || true
modprobe usbcore autosuspend=-1 2>/dev/null || true
chmod 777 /dev/tty* 2>/dev/null || true

# --- Step 5: Download meta.jar + helper scripts ---
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
  wget -q -O "$META_HOME/meta.jar" "https://github.com/nuriozalp/download/releases/download/${LATEST_TAG}/meta.jar"
  echo "  - meta.jar saved ($(du -h $META_HOME/meta.jar | cut -f1))"
else
  echo "ERROR: could not detect latest meta.jar release tag"
  exit 1
fi

# --- Step 6: Run hardware setup scripts ---
echo "==> Running hardware setup scripts..."
[ -x "$META_HOME/udev.sh" ]                       && "$META_HOME/udev.sh"                       || true
[ -x "$META_HOME/rfid.sh" ]                       && "$META_HOME/rfid.sh"                       || true
[ -x "$META_HOME/barcode.sh" ]                    && "$META_HOME/barcode.sh"                    || true
[ -x "$META_HOME/grant_meta_tty_permissions.sh" ] && "$META_HOME/grant_meta_tty_permissions.sh" || true

# --- Step 7: Configure system.ini with client-specific values ---
echo "==> Configuring $META_HOME/conf/system.ini..."
SYSTEM_INI="$META_HOME/conf/system.ini"

# If no system.ini exists yet, download a base from the dass-portal repo
if [ ! -f "$SYSTEM_INI" ]; then
  echo "  - downloading base system.ini..."
  wget -q -O "$SYSTEM_INI" \
    "https://raw.githubusercontent.com/Meta-Smart-Factory-d-o-o/panel-setup/main/system.ini.default" \
    2>/dev/null || true
  # Fallback: create minimal one
  if [ ! -s "$SYSTEM_INI" ]; then
    cat > "$SYSTEM_INI" << INI
#$(date)
customerName=$CLIENT
host=http://localhost:7189/
INI
  fi
fi

# Helper: set or replace a key in system.ini
set_ini() {
  local k="$1" v="$2"
  # Escape sed special chars in value (just &, /, \)
  local v_esc=$(printf '%s' "$v" | sed 's|[\\/&]|\\&|g')
  if grep -q "^${k}=" "$SYSTEM_INI"; then
    sed -i "s|^${k}=.*|${k}=${v_esc}|" "$SYSTEM_INI"
  else
    echo "${k}=${v}" >> "$SYSTEM_INI"
  fi
}

JDBC_URL="jdbc:mysql://${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DB}?useSSL=false&connectTimeout=10000&socketTimeout=10000&autoReconnect=true&allowPublicKeyRetrieval=true"

set_ini "customerName"                   "$CLIENT"
set_ini "settings.workstationId"         "$WORKSTATION_ID"
set_ini "settings.panelId"               "$PANEL_ID"
set_ini "mysql.datasource.jdbcUrl"       "$JDBC_URL"
set_ini "mysql.datasource.username"      "$MYSQL_USER"
set_ini "mysql.datasource.password"      "$MYSQL_PASSWORD"
set_ini "rabbit.host"                    "$RABBIT_HOST"
set_ini "rabbit.port"                    "$RABBIT_PORT"
set_ini "rabbit.username"                "$RABBIT_USER"
set_ini "rabbit.password"                "$RABBIT_PASSWORD"
# Per developer: rabbit.useSslProtocol must be removed (not 'false', completely gone)
sed -i '/^rabbit\.useSslProtocol=/d' "$SYSTEM_INI"

chown -R meta:meta "$META_HOME"
chmod 777 "$META_HOME/meta.jar" 2>/dev/null || true

echo ""
echo "  --- Final system.ini overrides ---"
grep -E "workstationId|panelId|customerName|^host=|mysql\.datasource\.(jdbcUrl|username|password)|^rabbit\." "$SYSTEM_INI" | sed 's/password=.*/password=*****/'
echo ""

# --- Step 8: Setup supervisord service for meta.jar ---
echo "==> Configuring supervisord to auto-start panel..."

# Detect display: prefer existing meta user's session, fall back to :0
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

# Allow Docker/other apps to use the X display
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
echo "  Tunnels:   sudo systemctl status msf-tunnels"
echo "  Config:    sudo nano /opt/meta/conf/system.ini"
echo ""
echo "  (After editing system.ini: sudo supervisorctl restart meta)"
echo ""
