#!/bin/bash
# =============================================================================
# MSF Panel — Generic One-Command Installer (HOST mode, no Docker)
#
# Generic by design: no hardcoded client mapping. You pass exactly what each
# panel needs — tunnel hostnames, IDs, DB/RMQ credentials, API host, customer
# name — and the installer applies everything to /opt/meta/conf/system.ini.
#
# What it does:
#  1. Installs Java + cloudflared + supervisord
#  2. Sets up Cloudflare access tunnels for MySQL + RabbitMQ (systemd service)
#  3. Downloads meta.jar + helper scripts from nuriozalp/download
#  4. Configures /opt/meta/conf/system.ini from CLI flags
#  5. Registers meta.jar as supervisord auto-start service (GUI on real DISPLAY)
# =============================================================================

set -e

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# --- Identity ---
WORKSTATION_ID=""
PANEL_ID=""
CUSTOMER_NAME=""

# --- Tunnels (Cloudflare access — forwarded to localhost on this panel) ---
MYSQL_TUNNEL_HOST=""
RABBIT_TUNNEL_HOST=""

# --- MySQL ---
MYSQL_JDBC_URL=""
MYSQL_USER="root"
MYSQL_PASSWORD=""

# --- RabbitMQ ---
RABBIT_HOST=""
RABBIT_PORT=""
RABBIT_USER="dass"
RABBIT_PASSWORD=""
RABBIT_USE_SSL=""   # "true" | "false" — required (validated below)

# --- Extra raw key=value overrides (repeatable: --set k=v --set k2=v2) ---
EXTRA_OVERRIDES=()

show_help() {
  cat << EOF
MSF Panel Installer — Generic (HOST mode)

Required:
  --workstation-id <id>          Workstation ID (e.g. 441297)
  --panel-id <id>                Panel ID (often same as workstation)
  --customer <name>              customerName field (e.g. norma, msfdemo, mc4)
  --mysql-tunnel <hostname>      Cloudflare hostname for MySQL tunnel
                                 (e.g. norma-mysql.msfdemo.com)
  --rabbit-tunnel <hostname>     Cloudflare hostname for RabbitMQ tunnel
                                 (e.g. norma-rabbitmq.msfdemo.com)
  --jdbc-url <url>               Full JDBC URL written verbatim to system.ini
                                 (e.g. jdbc:mysql://localhost:3306/teknia_group?useSSL=false&connectTimeout=10000&socketTimeout=10000&autoReconnect=true)
  --mysql-password <pwd>         MySQL password
  --rabbit-host <host>           RabbitMQ host (e.g. localhost)
  --rabbit-port <port>           RabbitMQ port (e.g. 5672)
  --rabbit-password <pwd>        RabbitMQ password
  --rabbit-use-ssl <true|false>  Controls rabbit.useSslProtocol in system.ini:
                                   true  → write "rabbit.useSslProtocol=true"
                                   false → remove the line entirely (per developer)

Optional:
  --mysql-user <user>            Default: root
  --rabbit-user <user>           Default: dass

Repeatable raw override (any system.ini key):
  --set key=value                Override any system.ini key directly.
                                 Use multiple times for multiple overrides.
                                 Example:
                                   --set settings.theme=2
                                   --set settings.wareHouseId=406

Example (msfdemo test) — run directly from GitHub:
  curl -sSL https://raw.githubusercontent.com/Meta-Smart-Factory-d-o-o/panel-setup/main/install.sh | sudo bash -s -- \\
    --workstation-id 441297 \\
    --panel-id 441297 \\
    --customer msfdemo \\
    --mysql-tunnel msfdemo-mysql.msfdemo.com \\
    --rabbit-tunnel msfdemo-rmq.msfdemo.com \\
    --jdbc-url 'jdbc:mysql://localhost:3306/teknia_group?useSSL=false&connectTimeout=10000&socketTimeout=10000&autoReconnect=true' \\
    --mysql-password '<MYSQL_PASS>' \\
    --rabbit-host localhost \\
    --rabbit-port 5672 \\
    --rabbit-password 'dass123456' \\
    --rabbit-use-ssl false

Example (Norma production) — run directly from GitHub:
  curl -sSL https://raw.githubusercontent.com/Meta-Smart-Factory-d-o-o/panel-setup/main/install.sh | sudo bash -s -- \\
    --workstation-id 12345 \\
    --panel-id 12345 \\
    --customer norma \\
    --mysql-tunnel norma-mysql.msfdemo.com \\
    --rabbit-tunnel norma-rabbitmq.msfdemo.com \\
    --jdbc-url 'jdbc:mysql://localhost:3306/dass_norma?useSSL=false&autoReconnect=true' \\
    --mysql-password '<MYSQL_PASS>' \\
    --rabbit-host localhost \\
    --rabbit-port 5672 \\
    --rabbit-password '<RABBIT_PASS>' \\
    --rabbit-use-ssl true

After install:
  sudo supervisorctl status meta
  sudo supervisorctl restart meta
  sudo tail -f /var/log/supervisor/meta.out.log
  sudo nano /opt/meta/conf/system.ini   # then: sudo supervisorctl restart meta
EOF
}

# --- Parse args ---
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --workstation-id) WORKSTATION_ID="$2"; shift ;;
    --panel-id) PANEL_ID="$2"; shift ;;
    --customer) CUSTOMER_NAME="$2"; shift ;;
    --mysql-tunnel) MYSQL_TUNNEL_HOST="$2"; shift ;;
    --rabbit-tunnel) RABBIT_TUNNEL_HOST="$2"; shift ;;
    --jdbc-url) MYSQL_JDBC_URL="$2"; shift ;;
    --mysql-user) MYSQL_USER="$2"; shift ;;
    --mysql-password) MYSQL_PASSWORD="$2"; shift ;;
    --rabbit-host) RABBIT_HOST="$2"; shift ;;
    --rabbit-port) RABBIT_PORT="$2"; shift ;;
    --rabbit-user) RABBIT_USER="$2"; shift ;;
    --rabbit-password) RABBIT_PASSWORD="$2"; shift ;;
    --rabbit-use-ssl) RABBIT_USE_SSL="$2"; shift ;;
    --set) EXTRA_OVERRIDES+=("$2"); shift ;;
    -h|--help) show_help; exit 0 ;;
    *) echo "Unknown parameter: $1"; echo "Run with --help for usage"; exit 1 ;;
  esac
  shift
done

# --- Validate required values ---
missing=()
[ -z "$WORKSTATION_ID" ]    && missing+=("--workstation-id")
[ -z "$PANEL_ID" ]          && missing+=("--panel-id")
[ -z "$CUSTOMER_NAME" ]     && missing+=("--customer")
[ -z "$MYSQL_TUNNEL_HOST" ] && missing+=("--mysql-tunnel")
[ -z "$RABBIT_TUNNEL_HOST" ]&& missing+=("--rabbit-tunnel")
[ -z "$MYSQL_JDBC_URL" ]    && missing+=("--jdbc-url")
[ -z "$MYSQL_PASSWORD" ]    && missing+=("--mysql-password")
[ -z "$RABBIT_PASSWORD" ]   && missing+=("--rabbit-password")
[ -z "$RABBIT_HOST" ]       && missing+=("--rabbit-host")
[ -z "$RABBIT_PORT" ]       && missing+=("--rabbit-port")
[ -z "$RABBIT_USE_SSL" ]    && missing+=("--rabbit-use-ssl")

if [ ${#missing[@]} -gt 0 ]; then
  echo "ERROR: missing required arguments: ${missing[*]}"
  echo "Run with --help for usage."
  exit 1
fi

# Validate rabbit-use-ssl value
if [ "$RABBIT_USE_SSL" != "true" ] && [ "$RABBIT_USE_SSL" != "false" ]; then
  echo "ERROR: --rabbit-use-ssl must be 'true' or 'false' (got: '$RABBIT_USE_SSL')"
  exit 1
fi

echo ""
echo "=========================================="
echo "  MSF Panel Setup (HOST mode)"
echo "=========================================="
echo "  Customer:        $CUSTOMER_NAME"
echo "  Workstation ID:  $WORKSTATION_ID"
echo "  Panel ID:        $PANEL_ID"
echo "  MySQL Tunnel:    $MYSQL_TUNNEL_HOST → localhost:3306"
echo "  RabbitMQ Tun.:   $RABBIT_TUNNEL_HOST → localhost:$RABBIT_PORT"
echo "  Rabbit host:     $RABBIT_HOST:$RABBIT_PORT"
echo "  JDBC URL:        $MYSQL_JDBC_URL"
echo "  Rabbit SSL:      $RABBIT_USE_SSL"
[ ${#EXTRA_OVERRIDES[@]} -gt 0 ] && echo "  Extra overrides: ${#EXTRA_OVERRIDES[@]} key(s) via --set"
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
  curl wget dos2unix jq openjdk-17-jre supervisor 2>&1 | tail -3

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
Description=MSF Cloudflare Access Tunnels (${CUSTOMER_NAME})
After=network.target

[Service]
Type=simple
ExecStart=/bin/sh -c '/usr/local/bin/cloudflared access tcp --hostname ${MYSQL_TUNNEL_HOST} --url localhost:3306 & /usr/local/bin/cloudflared access tcp --hostname ${RABBIT_TUNNEL_HOST} --url localhost:${RABBIT_PORT} & wait'
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

# --- Step 7: Configure /opt/meta/conf/system.ini ---
echo "==> Configuring $META_HOME/conf/system.ini..."
SYSTEM_INI="$META_HOME/conf/system.ini"

# If system.ini doesn't exist yet, create a minimal one (meta.jar fills the rest)
if [ ! -f "$SYSTEM_INI" ]; then
  cat > "$SYSTEM_INI" << INI
#$(date)
customerName=${CUSTOMER_NAME}
INI
fi

# Helper: set or replace a key in system.ini
set_ini() {
  local k="$1" v="$2"
  local v_esc
  v_esc=$(printf '%s' "$v" | sed 's|[\\/&]|\\&|g')
  if grep -q "^${k}=" "$SYSTEM_INI"; then
    sed -i "s|^${k}=.*|${k}=${v_esc}|" "$SYSTEM_INI"
  else
    echo "${k}=${v}" >> "$SYSTEM_INI"
  fi
}

# Standard overrides
set_ini "customerName"              "$CUSTOMER_NAME"
set_ini "settings.workstationId"    "$WORKSTATION_ID"
set_ini "settings.panelId"          "$PANEL_ID"
set_ini "mysql.datasource.jdbcUrl"  "$MYSQL_JDBC_URL"
set_ini "mysql.datasource.username" "$MYSQL_USER"
set_ini "mysql.datasource.password" "$MYSQL_PASSWORD"
set_ini "rabbit.host"               "$RABBIT_HOST"
set_ini "rabbit.port"               "$RABBIT_PORT"
set_ini "rabbit.username"           "$RABBIT_USER"
set_ini "rabbit.password"           "$RABBIT_PASSWORD"

# rabbit.useSslProtocol special handling:
#   true  → write the line
#   false → remove the line entirely (per developer)
case "$RABBIT_USE_SSL" in
  true)  set_ini "rabbit.useSslProtocol" "true" ;;
  false) sed -i '/^rabbit\.useSslProtocol=/d' "$SYSTEM_INI" ;;
esac

# Apply any --set key=value extras
for override in "${EXTRA_OVERRIDES[@]}"; do
  k="${override%%=*}"
  v="${override#*=}"
  if [ -z "$k" ] || [ "$k" = "$override" ]; then
    echo "  WARN: ignoring malformed --set '$override' (expected key=value)"
    continue
  fi
  echo "  - extra override: $k"
  set_ini "$k" "$v"
done

chown -R meta:meta "$META_HOME"
chmod 777 "$META_HOME/meta.jar" 2>/dev/null || true

echo ""
echo "  --- Final system.ini key overrides ---"
grep -E "^(customerName|mysql\.datasource\.(jdbcUrl|username|password)|rabbit\.(host|port|username|password|useSslProtocol)|settings\.(workstationId|panelId))=" "$SYSTEM_INI" \
  | sed 's/password=.*/password=*****/'
echo ""

# --- Step 8: Setup supervisord service for meta.jar ---
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
echo "  Tunnels:   sudo systemctl status msf-tunnels"
echo "  Config:    sudo nano /opt/meta/conf/system.ini"
echo ""
echo "  (After editing system.ini: sudo supervisorctl restart meta)"
echo ""
