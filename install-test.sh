#!/bin/bash
# =============================================================================
# MSF Panel — ISOLATED TEST Installer
#
# This installer is for TESTING ONLY. It does NOT connect to any real client
# (Norma/Simsek/MC4). Instead it spins up a local MySQL + RabbitMQ on the same
# panel so you can verify the dass-desktop image, DASS_* env overrides, and
# install.sh logic without disturbing any production system.
#
# Cleanup: docker compose -f /opt/meta-panel-test/docker-compose.yml down -v
# =============================================================================

set -e

GHCR_USER=""
GHCR_TOKEN=""

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --ghcr-user) GHCR_USER="$2"; shift ;;
    --ghcr-token) GHCR_TOKEN="$2"; shift ;;
    -h|--help)
      echo "Usage: $0 --ghcr-user <user> --ghcr-token <token>"
      exit 0 ;;
    *) echo "Unknown parameter: $1"; exit 1 ;;
  esac
  shift
done

[ -z "$GHCR_USER" ]  && read -p "GitHub username: " GHCR_USER
[ -z "$GHCR_TOKEN" ] && { read -sp "GitHub PAT (read:packages): " GHCR_TOKEN; echo; }

if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Run as root (use sudo)"; exit 1
fi

echo ""
echo "=========================================="
echo "  MSF Panel — ISOLATED TEST"
echo "=========================================="
echo "  This sets up a self-contained test:"
echo "    - Local MySQL (test DB)"
echo "    - Local RabbitMQ (test queue)"
echo "    - dass-desktop (test workstation)"
echo "  Nothing connects to Norma/Simsek/MC4."
echo "=========================================="

# --- Install Docker if missing ---
if ! command -v docker &> /dev/null; then
  echo "==> Installing Docker..."
  curl -fsSL https://get.docker.com | sh
else
  echo "==> Docker already installed."
fi

# --- Setup test folder ---
TEST_DIR="/opt/meta-panel-test"
mkdir -p $TEST_DIR
cd $TEST_DIR

# --- docker-compose.yml: local mysql + rabbitmq + dass-desktop ---
cat > docker-compose.yml << 'EOF'
services:
  test-mysql:
    image: percona/percona-server:8.0
    container_name: test-mysql
    restart: "no"
    environment:
      MYSQL_ROOT_PASSWORD: testpass123
      MYSQL_DATABASE: das_new
    networks:
      - test-net
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-uroot", "-ptestpass123"]
      interval: 5s
      timeout: 5s
      retries: 20
      start_period: 30s

  test-rabbitmq:
    image: rabbitmq:3-management
    container_name: test-rabbitmq
    restart: "no"
    environment:
      RABBITMQ_DEFAULT_USER: dass
      RABBITMQ_DEFAULT_PASS: testpass123
    networks:
      - test-net
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "ping"]
      interval: 5s
      timeout: 5s
      retries: 20
      start_period: 20s

  test-dass-desktop:
    image: ghcr.io/meta-smart-factory-d-o-o/dass-desktop:latest
    container_name: test-dass-desktop
    restart: "no"
    depends_on:
      test-mysql:
        condition: service_healthy
      test-rabbitmq:
        condition: service_healthy
    env_file: .env
    networks:
      - test-net

networks:
  test-net:
    driver: bridge
EOF

# --- .env with DASS_* overrides pointing to local services ---
cat > .env << 'EOF'
DASS_settings__workstationId=999999
DASS_settings__panelId=999999
DASS_customerName=test
DASS_mysql__datasource__jdbcUrl=jdbc:mysql://test-mysql:3306/das_new?useUnicode=yes&characterEncoding=UTF-8&useJDBCCompliantTimezoneShift=true&useLegacyDatetimeCode=false&serverTimezone=UTC&autoReconnect=true&useSSL=false&allowPublicKeyRetrieval=true
DASS_mysql__datasource__username=root
DASS_mysql__datasource__password=testpass123
DASS_rabbit__host=test-rabbitmq
DASS_rabbit__port=5672
DASS_rabbit__username=dass
DASS_rabbit__password=testpass123
DASS_host=http://localhost:7189/
EOF

chmod 600 .env

# --- Login to GHCR ---
echo "==> Logging in to GHCR..."
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

# --- Pull image ---
echo "==> Pulling dass-desktop image..."
docker compose pull

# --- Start ---
echo "==> Starting test environment..."
docker compose up -d

echo ""
echo "=========================================="
echo "  Test environment started!"
echo "=========================================="
echo ""
echo "  Test directory: $TEST_DIR"
echo ""
echo "  Watch logs:"
echo "    docker logs -f test-dass-desktop"
echo ""
echo "  Verify system.ini was overridden:"
echo "    docker exec test-dass-desktop cat /app/conf/system.ini | grep -E 'workstationId|panelId|mysql.datasource.password|rabbit.host'"
echo ""
echo "  CLEANUP when done (removes everything):"
echo "    cd $TEST_DIR && docker compose down -v"
echo "    rm -rf $TEST_DIR"
echo ""
