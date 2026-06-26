#!/bin/bash
# =============================================================================
# MSF Panel — Fluent Bit centralized logging installer
#
# Ships /var/log/supervisor/meta.*.log → OpenSearch on the logs server.
# Run on each panel after panel-setup/install.sh (or on existing panels).
#
# Usage:
#   curl -sSL .../install-fluent-bit.sh | sudo bash -s -- \
#     --panel-id 441297 --customer msfdemo
#
# Or read panel-id / customer from /opt/meta/conf/system.ini automatically.
# =============================================================================

set -euo pipefail

OPENSEARCH_HOST="${OPENSEARCH_HOST:-95.179.202.168}"
OPENSEARCH_PORT="${OPENSEARCH_PORT:-9200}"
LOG_PREFIX="${LOG_PREFIX:-}"
PANEL_ID=""
CUSTOMER=""
PLANT_ID=""
HOSTNAME_OVERRIDE=""
PLANT_NAME=""
NORMA_REGION=""
SKIP_INSTALL=false

show_help() {
  cat << 'EOF'
MSF Panel — Fluent Bit (centralized logging)

Installs Fluent Bit, ANSI strip filter, log parser, and OpenSearch output.

Options:
  --panel-id <id>           Panel ID (default: read from system.ini)
  --customer <name>         Client name e.g. msfdemo, norma, simsek (default: system.ini)
  --plant-id <id>           Plant ID (default: unknown)
  --plant-name <name>       Plant display name (optional)
  --hostname <name>         Hostname tag (default: hostname -s)
  --opensearch-host <ip>    OpenSearch server (default: 95.179.202.168)
  --opensearch-port <port>  OpenSearch port (default: 9200)
  --log-prefix <prefix>       Index prefix (default: panel-logs-<customer>)
  --norma-region <us|uk|fr> Norma only: set customer + index per region
  --skip-install            Only rewrite config; do not apt-install Fluent Bit

Examples:
  # Auto-read from system.ini:
  sudo bash install-fluent-bit.sh

  # Explicit:
  sudo bash install-fluent-bit.sh --panel-id 441297 --customer msfdemo

  # Simsek panel:
  sudo bash install-fluent-bit.sh --panel-id 12345 --customer simsek --log-prefix panel-logs-simsek

  # Norma US / UK / France (separate OpenSearch indices):
  sudo bash install-fluent-bit.sh --norma-region us
  sudo bash install-fluent-bit.sh --norma-region uk
  sudo bash install-fluent-bit.sh --norma-region fr

After install:
  sudo systemctl status fluent-bit
  sudo journalctl -u fluent-bit -f
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --panel-id) PANEL_ID="$2"; shift 2 ;;
    --customer) CUSTOMER="$2"; shift 2 ;;
    --plant-id) PLANT_ID="$2"; shift 2 ;;
    --plant-name) PLANT_NAME="$2"; shift 2 ;;
    --hostname) HOSTNAME_OVERRIDE="$2"; shift 2 ;;
    --opensearch-host) OPENSEARCH_HOST="$2"; shift 2 ;;
    --opensearch-port) OPENSEARCH_PORT="$2"; shift 2 ;;
    --log-prefix) LOG_PREFIX="$2"; shift 2 ;;
    --norma-region) NORMA_REGION="$2"; shift 2 ;;
    --skip-install) SKIP_INSTALL=true; shift ;;
    -h|--help) show_help; exit 0 ;;
    *) echo "Unknown option: $1"; show_help; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run as root (sudo bash $0 ...)"
  exit 1
fi

SYSTEM_INI="/opt/meta/conf/system.ini"
if [[ -f "$SYSTEM_INI" ]]; then
  [[ -z "$PANEL_ID" ]] && PANEL_ID=$(grep -E '^settings\.panelId=' "$SYSTEM_INI" | head -1 | cut -d= -f2- | tr -d '[:space:]')
  [[ -z "$CUSTOMER" ]] && CUSTOMER=$(grep -E '^customerName=' "$SYSTEM_INI" | head -1 | cut -d= -f2- | tr -d '[:space:]')
  [[ -z "$PLANT_ID" ]] && PLANT_ID=$(grep -E '^settings\.wareHouseId=' "$SYSTEM_INI" | head -1 | cut -d= -f2- | tr -d '[:space:]' || true)
  [[ -z "$PLANT_NAME" ]] && PLANT_NAME=$(grep -E '^settings\.workstationName=' "$SYSTEM_INI" | head -1 | cut -d= -f2- | tr -d '[:space:]' || true)
fi

[[ -z "$PANEL_ID" ]] && { echo "ERROR: --panel-id required (or settings.panelId in system.ini)"; exit 1; }
[[ -z "$CUSTOMER" ]] && { echo "ERROR: --customer required (or customerName in system.ini)"; exit 1; }

if [[ -n "$NORMA_REGION" ]]; then
  case "${NORMA_REGION,,}" in
    us)   CUSTOMER="normaus"; LOG_PREFIX="panel-logs-normaus" ;;
    uk)   CUSTOMER="normauk"; LOG_PREFIX="panel-logs-normauk" ;;
    fr|france) CUSTOMER="normafr"; LOG_PREFIX="panel-logs-normafr" ;;
    *) echo "ERROR: --norma-region must be us, uk, or fr"; exit 1 ;;
  esac
fi

[[ -z "$PLANT_ID" ]] && PLANT_ID="unknown"
[[ -z "$PLANT_NAME" ]] && PLANT_NAME="MSF Panel"
HOSTNAME_TAG="${HOSTNAME_OVERRIDE:-$(hostname -s 2>/dev/null || hostname)}"
PANEL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "$PANEL_IP" ]] && PANEL_IP="unknown"
[[ -z "$LOG_PREFIX" ]] && LOG_PREFIX="panel-logs-${CUSTOMER}"

echo "==> MSF Fluent Bit install"
echo "    panel_id=$PANEL_ID customer=$CUSTOMER hostname=$HOSTNAME_TAG"
echo "    opensearch=${OPENSEARCH_HOST}:${OPENSEARCH_PORT} index=${LOG_PREFIX}"

install_fluent_bit() {
  if command -v fluent-bit >/dev/null 2>&1 || [[ -x /opt/fluent-bit/bin/fluent-bit ]]; then
    echo "==> Fluent Bit already installed"
    return 0
  fi

  echo "==> Installing Fluent Bit..."
  export DEBIAN_FRONTEND=noninteractive

  if [[ -f /etc/debian_version ]]; then
  codename=$( . /etc/os-release && echo "${VERSION_CODENAME:-$UBUNTU_CODENAME}" )
  if [[ -n "$codename" ]]; then
    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://packages.fluentbit.io/fluentbit.key \
      | gpg --dearmor -o /usr/share/keyrings/fluentbit-keyring.gpg 2>/dev/null || true
    if [[ -f /usr/share/keyrings/fluentbit-keyring.gpg ]]; then
      echo "deb [signed-by=/usr/share/keyrings/fluentbit-keyring.gpg] https://packages.fluentbit.io/ubuntu/${codename} ${codename} main" \
        > /etc/apt/sources.list.d/fluent-bit.list
      apt-get update -qq
      apt-get install -y fluent-bit
      return 0
    fi
  fi
  fi

  echo "==> Fallback: Fluent Bit install script"
  curl -fsSL https://raw.githubusercontent.com/fluent/fluent-bit/master/install.sh | sh
}

if [[ "$SKIP_INSTALL" != true ]]; then
  install_fluent_bit
fi

echo "==> Writing /etc/fluent-bit/scripts/strip_ansi.lua"
mkdir -p /etc/fluent-bit/scripts
cat > /etc/fluent-bit/scripts/strip_ansi.lua << 'LUAEOF'
function strip_ansi(tag, timestamp, record)
    if record["log"] then
        record["log"] = string.gsub(record["log"], "\27%[[0-9;]*m", "")
    end
    return 2, timestamp, record
end
LUAEOF

echo "==> Writing /etc/fluent-bit/parsers.conf"
cat > /etc/fluent-bit/parsers.conf << 'PARSEEOF'
[PARSER]
    Name        meta_log
    Format      regex
    Regex       ^(?<log_time>\d{2}\.\d{2}\.\d{4} \d{2}:\d{2}:\d{2}[.,]\d{3})\s+(?<level>INFO|WARN|ERROR|DEBUG)\s+(?<message>.*)$
PARSEEOF

echo "==> Writing /etc/fluent-bit/fluent-bit.conf"
cat > /etc/fluent-bit/fluent-bit.conf << FBEOF
[SERVICE]
    Flush         5
    Daemon        off
    Log_Level     info
    Parsers_File  parsers.conf

[INPUT]
    Name              tail
    Path              /var/log/supervisor/meta.*.log
    Tag               panel.logs
    Refresh_Interval  5
    Read_from_Head    Off
    Skip_Long_Lines   On

[FILTER]
    Name   lua
    Match  panel.logs
    script /etc/fluent-bit/scripts/strip_ansi.lua
    call   strip_ansi

[FILTER]
    Name    record_modifier
    Match   panel.logs
    Record  client ${CUSTOMER}
    Record  client_display ${CUSTOMER}
    Record  panel_id ${PANEL_ID}
    Record  plant_id ${PLANT_ID}
    Record  hostname ${HOSTNAME_TAG}
    Record  plant_name "${PLANT_NAME}"
    Record  panel_ip ${PANEL_IP}

[FILTER]
    Name          parser
    Match         panel.logs
    Key_Name      log
    Parser        meta_log
    Reserve_Data  On
    Preserve_Key  On

[OUTPUT]
    Name               opensearch
    Match              panel.logs
    Host               ${OPENSEARCH_HOST}
    Port               ${OPENSEARCH_PORT}
    Index              ${LOG_PREFIX}
    Suppress_Type_Name On
    tls                Off
    Logstash_Format    On
    Logstash_Prefix    ${LOG_PREFIX}
    Logstash_DateFormat %Y.%m.%d
    Retry_Limit        False
FBEOF

echo "==> Enabling fluent-bit service"
systemctl daemon-reload
systemctl enable fluent-bit
systemctl restart fluent-bit

sleep 2
if systemctl is-active --quiet fluent-bit; then
  echo "==> Fluent Bit is running"
else
  echo "ERROR: fluent-bit failed to start"
  journalctl -u fluent-bit -n 30 --no-pager
  exit 1
fi

echo ""
echo "=========================================="
echo "  Fluent Bit setup complete"
echo "=========================================="
echo "  Panel ID  : $PANEL_ID"
echo "  Customer  : $CUSTOMER"
echo "  Index     : ${LOG_PREFIX}-YYYY.MM.DD"
echo "  OpenSearch: http://${OPENSEARCH_HOST}:${OPENSEARCH_PORT}"
echo ""
echo "  Verify on server:"
echo "    curl -s 'http://${OPENSEARCH_HOST}:${OPENSEARCH_PORT}/${LOG_PREFIX}-*/_search' \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"size\":1,\"query\":{\"term\":{\"panel_id.keyword\":\"${PANEL_ID}\"}}}'"
echo ""
echo "  Panel logs:"
echo "    sudo journalctl -u fluent-bit -f"
echo ""
