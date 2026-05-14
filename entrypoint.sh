#!/bin/bash
set -e

SYSTEM_INI="/opt/meta/conf/system.ini"
DEFAULT_INI="/opt/meta/system.ini.default"

# --- system.ini handling ---
# 1. If user mounted a custom system.ini at /opt/meta/conf/system.ini → use as-is
# 2. Otherwise, generate one from the default template using env vars
if [ -f "$SYSTEM_INI" ] && grep -q "user-provided" "$SYSTEM_INI" 2>/dev/null; then
    echo "==> Using user-provided system.ini (mounted via volume)"
else
    echo "==> Generating system.ini from default template + env vars..."
    mkdir -p "$(dirname "$SYSTEM_INI")"
    cp "$DEFAULT_INI" "$SYSTEM_INI"

    # Replace placeholders with env values (only what changes per panel/client)
    sed -i \
        -e "s|__WORKSTATION_ID__|${WORKSTATION_ID}|g" \
        -e "s|__PANEL_ID__|${PANEL_ID}|g" \
        -e "s|__CUSTOMER_NAME__|${CUSTOMER_NAME}|g" \
        -e "s|__MYSQL_HOST__|${MYSQL_HOST:-localhost}|g" \
        -e "s|__MYSQL_PORT__|${MYSQL_PORT:-3306}|g" \
        -e "s|__MYSQL_DB__|${MYSQL_DB}|g" \
        -e "s|__MYSQL_USER__|${MYSQL_USER:-root}|g" \
        -e "s|__MYSQL_PASSWORD__|${MYSQL_PASSWORD}|g" \
        "$SYSTEM_INI"

    # Optional overrides — only apply if user provided custom values
    [ -n "$RABBIT_HOST" ]     && sed -i "s|^rabbit.host=.*|rabbit.host=${RABBIT_HOST}|" "$SYSTEM_INI"
    [ -n "$RABBIT_PORT" ]     && sed -i "s|^rabbit.port=.*|rabbit.port=${RABBIT_PORT}|" "$SYSTEM_INI"
    [ -n "$RABBIT_USER" ]     && sed -i "s|^rabbit.username=.*|rabbit.username=${RABBIT_USER}|" "$SYSTEM_INI"
    [ -n "$RABBIT_PASSWORD" ] && sed -i "s|^rabbit.password=.*|rabbit.password=${RABBIT_PASSWORD}|" "$SYSTEM_INI"
    [ -n "$KAFKA_HOST" ]      && sed -i "s|^kafka.host=.*|kafka.host=${KAFKA_HOST}|" "$SYSTEM_INI"
    [ -n "$KAFKA_PORT" ]      && sed -i "s|^kafka.port=.*|kafka.port=${KAFKA_PORT}|" "$SYSTEM_INI"
    [ -n "$KAFKA_TOPIC" ]     && sed -i "s|^kafka.topic=.*|kafka.topic=${KAFKA_TOPIC}|" "$SYSTEM_INI"
    [ -n "$KAFKA_USER" ]      && sed -i "s|^kafka.username=.*|kafka.username=${KAFKA_USER}|" "$SYSTEM_INI"
    [ -n "$KAFKA_PASSWORD" ]  && sed -i "s|^kafka.password=.*|kafka.password=${KAFKA_PASSWORD}|" "$SYSTEM_INI"
    [ -n "$MSF_HOST" ]        && sed -i "s|^host=.*|host=http\\\\://${MSF_HOST}\\\\:7189/|" "$SYSTEM_INI"
fi

# --- Download / Update meta.jar ---
echo "==> Checking for latest meta.jar..."

if [ -z "$JAR_VERSION" ] || [ "$JAR_VERSION" = "latest" ]; then
    LATEST_TAG=$(wget -qO- https://api.github.com/repos/${JAR_REPO:-nuriozalp/download}/releases/latest | jq -r '.tag_name')
    echo "==> Latest version: $LATEST_TAG"
    JAR_URL="https://github.com/${JAR_REPO:-nuriozalp/download}/releases/download/${LATEST_TAG}/meta.jar"
else
    JAR_URL="https://github.com/${JAR_REPO:-nuriozalp/download}/releases/download/${JAR_VERSION}/meta.jar"
fi

if [ ! -f /opt/meta/meta.jar ] || [ "$AUTO_UPDATE" = "true" ]; then
    echo "==> Downloading meta.jar..."
    wget -O /opt/meta/meta.jar "$JAR_URL"
fi

echo "==> Starting Meta Panel..."
exec java \
    --add-opens=java.base/java.lang=ALL-UNNAMED \
    -Djavax.accessibility.assistive_technologies \
    -Djavax.accessibility.screen_magnifier_present=false \
    -jar /opt/meta/meta.jar
