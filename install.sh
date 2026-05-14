#!/bin/bash
# =============================================================================
# MSF Panel — One-Command Installer
# Usage:
#   curl -sSL https://raw.githubusercontent.com/msf/panel-setup/main/install.sh | bash -s -- \
#     --client norma \
#     --workstation-id 441243 \
#     --panel-id 441243 \
#     --mysql-db norma_db \
#     --mysql-password "yourpass" \
#     --rabbit-password "yourpass"
# =============================================================================

set -e

# --- Default values ---
CLIENT=""
WORKSTATION_ID=""
PANEL_ID=""
CUSTOMER_NAME=""
MYSQL_DB=""
MYSQL_USER="root"
MYSQL_PASSWORD=""
RABBIT_USER="dass"
RABBIT_PASSWORD=""
KAFKA_HOST="localhost"
KAFKA_PORT="9092"
KAFKA_TOPIC="panel-events"
KAFKA_USER=""
KAFKA_PASSWORD=""
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
    --mysql-db) MYSQL_DB="$2"; shift ;;
    --mysql-user) MYSQL_USER="$2"; shift ;;
    --mysql-password) MYSQL_PASSWORD="$2"; shift ;;
    --rabbit-user) RABBIT_USER="$2"; shift ;;
    --rabbit-password) RABBIT_PASSWORD="$2"; shift ;;
    --kafka-host) KAFKA_HOST="$2"; shift ;;
    --kafka-port) KAFKA_PORT="$2"; shift ;;
    --kafka-topic) KAFKA_TOPIC="$2"; shift ;;
    --kafka-user) KAFKA_USER="$2"; shift ;;
    --kafka-password) KAFKA_PASSWORD="$2"; shift ;;
    --ghcr-user) GHCR_USER="$2"; shift ;;
    --ghcr-token) GHCR_TOKEN="$2"; shift ;;
    -h|--help)
      cat << EOF
MSF Panel Installer

Required:
  --client <name>           Client name (norma|simsek|mc4)
  --workstation-id <id>     Unique workstation ID
  --panel-id <id>           Unique panel ID
  --mysql-db <name>         MySQL database name
  --mysql-password <pwd>    MySQL password (changes per client)
  --ghcr-user <user>        GitHub username (for pulling private image)
  --ghcr-token <token>      GitHub Personal Access Token (read:packages scope)

Optional:
  --customer <name>         Default: same as --client
  --mysql-user <user>       Default: root
  --rabbit-user <user>      Default: dass (same across all clients)
  --rabbit-password <pwd>   Default: dass (same across all clients)
  --kafka-host <host>       Default: localhost
  --kafka-port <port>       Default: 9092
  --kafka-topic <topic>     Default: panel-events
  --kafka-user <user>       Default: (empty)
  --kafka-password <pwd>    Default: (empty)
EOF
      exit 0
      ;;
    *) echo "Unknown parameter: $1"; echo "Run with --help for usage"; exit 1 ;;
  esac
  shift
done

# --- Interactive prompt if missing ---
if [ -z "$CLIENT" ]; then
  read -p "Client (norma/simsek/mc4): " CLIENT
fi
if [ -z "$WORKSTATION_ID" ]; then
  read -p "Workstation ID: " WORKSTATION_ID
fi
if [ -z "$PANEL_ID" ]; then
  read -p "Panel ID [$WORKSTATION_ID]: " PANEL_ID
  PANEL_ID=${PANEL_ID:-$WORKSTATION_ID}
fi
if [ -z "$MYSQL_DB" ]; then
  read -p "MySQL Database name: " MYSQL_DB
fi
if [ -z "$MYSQL_PASSWORD" ]; then
  read -sp "MySQL password: " MYSQL_PASSWORD; echo
fi
# RabbitMQ creds default to 'dass/dass' for all clients — only prompt if not set
# and only used as overrides (leaving empty keeps the defaults in system.ini.default)
if [ -z "$GHCR_USER" ]; then
  read -p "GitHub username (for image pull): " GHCR_USER
fi
if [ -z "$GHCR_TOKEN" ]; then
  read -sp "GitHub PAT (read:packages scope): " GHCR_TOKEN; echo
fi
if [ -z "$CUSTOMER_NAME" ]; then
  CUSTOMER_NAME=$CLIENT
fi

# --- Client → tunnel hostname mapping ---
case "$CLIENT" in
  norma)
    MYSQL_TUNNEL="norma-mysql.msfdemo.com"
    RABBIT_TUNNEL="norma-rabbitmq.msfdemo.com"
    ;;
  simsek)
    MYSQL_TUNNEL="simsek-mysql.msfdemo.com"
    RABBIT_TUNNEL="simsek-rabbitmq.msfdemo.com"
    ;;
  mc4)
    MYSQL_TUNNEL="mc4-mysql.msfdemo.com"
    RABBIT_TUNNEL="mc4-rabbitmq.msfdemo.com"
    ;;
  *)
    echo "ERROR: Unknown client '$CLIENT'. Supported: norma, simsek, mc4"
    exit 1
    ;;
esac

echo ""
echo "=========================================="
echo "  MSF Panel Setup"
echo "=========================================="
echo "  Client:         $CLIENT"
echo "  Workstation ID: $WORKSTATION_ID"
echo "  Panel ID:       $PANEL_ID"
echo "  MySQL DB:       $MYSQL_DB"
echo "  MySQL Tunnel:   $MYSQL_TUNNEL"
echo "  RabbitMQ Tun.:  $RABBIT_TUNNEL"
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

# --- Step 2: Install cloudflared ---
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
ExecStart=/bin/sh -c '/usr/local/bin/cloudflared access tcp --hostname ${MYSQL_TUNNEL} --url localhost:3306 & /usr/local/bin/cloudflared access tcp --hostname ${RABBIT_TUNNEL} --url localhost:5672 & wait'
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

# --- Step 4: Create panel directory and .env ---
echo "==> Creating panel configuration..."
PANEL_DIR="/opt/meta-panel"
mkdir -p $PANEL_DIR
cd $PANEL_DIR

cat > .env << EOF
# --- Panel-Specific (REQUIRED) ---
WORKSTATION_ID=${WORKSTATION_ID}
PANEL_ID=${PANEL_ID}
CUSTOMER_NAME=${CUSTOMER_NAME}

# --- MySQL (REQUIRED — changes per client) ---
MYSQL_DB=${MYSQL_DB}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}

# --- RabbitMQ (uses defaults from image if not set) ---
RABBIT_USER=${RABBIT_USER}
RABBIT_PASSWORD=${RABBIT_PASSWORD}

# --- Kafka (optional) ---
KAFKA_HOST=${KAFKA_HOST}
KAFKA_PORT=${KAFKA_PORT}
KAFKA_TOPIC=${KAFKA_TOPIC}
KAFKA_USER=${KAFKA_USER}
KAFKA_PASSWORD=${KAFKA_PASSWORD}

# --- Connection (tunnels handle routing) ---
MSF_HOST=localhost
MYSQL_HOST=localhost
MYSQL_PORT=3306

# --- Updates ---
AUTO_UPDATE=true
JAR_VERSION=latest
JAR_REPO=nuriozalp/download
EOF

chmod 600 .env

# --- Step 5: Download docker-compose.yml ---
echo "==> Downloading docker-compose.yml..."
curl -sSL "${RAW_BASE}/docker-compose.yml" -o docker-compose.yml

# --- Step 6: Login to GHCR (image is private) ---
echo "==> Logging in to GHCR..."
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

# --- Step 7: Allow Docker to access X display (for GUI) ---
echo "==> Allowing Docker GUI access..."
xhost +local:docker 2>/dev/null || true

# --- Step 8: Start the panel ---
echo "==> Pulling and starting panel..."
docker compose pull
docker compose up -d

echo ""
echo "=========================================="
echo "  ✓ Setup Complete!"
echo "=========================================="
echo ""
echo "  Panel directory: $PANEL_DIR"
echo "  View logs:       docker compose -f $PANEL_DIR/docker-compose.yml logs -f"
echo "  Restart:         docker compose -f $PANEL_DIR/docker-compose.yml restart"
echo "  Stop:            docker compose -f $PANEL_DIR/docker-compose.yml down"
echo ""
