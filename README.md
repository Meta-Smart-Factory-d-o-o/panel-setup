# MSF Panel Setup

One-command installer that deploys the **dass-desktop** Docker image to MSF panels.

> The panel application Docker image (`ghcr.io/meta-smart-factory-d-o-o/dass-desktop`) is built and maintained from the [`dass-portal`](https://github.com/Meta-Smart-Factory-d-o-o/dass-portal) repo. This `panel-setup` repo only ships an installer + docker-compose for deploying it on panels.

---

## How It Works

1. The `dass-desktop` image already contains a default `system.ini`
2. Its entrypoint scans for env vars prefixed with `DASS_` and overrides the matching keys in `system.ini` at container start
   - Naming convention: `DASS_<key with __ instead of .>`
   - Example: `DASS_mysql__datasource__password=secret` → `mysql.datasource.password=secret`
3. Cloudflare access tunnels route `localhost:3306` and `localhost:5672` from the panel to the centralized MySQL/RabbitMQ server

---

## Quick Start

On a fresh panel (Ubuntu/Debian), run as root:

```bash
curl -sSL https://raw.githubusercontent.com/Meta-Smart-Factory-d-o-o/panel-setup/main/install.sh | sudo bash -s -- \
  --client norma \
  --workstation-id 441243 \
  --panel-id 441243 \
  --mysql-db dass_norma \
  --mysql-password "yourpass" \
  --rabbit-password "yourpass" \
  --ghcr-user farhanawan77 \
  --ghcr-token "ghp_xxxxxxxxxxxxxxxxxxxx"
```

Or run interactively (will prompt for missing values):

```bash
curl -sSL https://raw.githubusercontent.com/Meta-Smart-Factory-d-o-o/panel-setup/main/install.sh | sudo bash
```

> Generate a GitHub PAT (read:packages scope only) at:
> https://github.com/settings/tokens/new?scopes=read:packages&description=msf-panel-ghcr

---

## What It Does

1. Installs **Docker** (if not present)
2. Installs **cloudflared** (if not present)
3. Sets up Cloudflare access tunnels (systemd service `msf-tunnels.service`)
   - MySQL: `<client>-mysql.msfdemo.com` → `localhost:3306`
   - RabbitMQ: `<client>-rabbitmq.msfdemo.com` → `localhost:5672`
4. Creates `/opt/meta-panel/.env` with `DASS_*` override variables
5. **Installs hardware support scripts on host** (replaces manual `meta.sh`):
   - Creates `meta` user, adds to `dialout` group
   - Downloads `udev.sh`, `rfid.sh`, `barcode.sh`, `grant_meta_tty_permissions.sh` to `/opt/meta/`
   - Installs udev rules and TTY permissions for USB devices (barcode, RFID readers)
   - Disables USB autosuspend
6. Logs in to GHCR (image is private)
7. Pulls `ghcr.io/meta-smart-factory-d-o-o/dass-desktop:latest`
8. Starts the container

---

## Supported Clients

### Production

| Client | MySQL Tunnel | RabbitMQ Tunnel |
|--------|-------------|------------------|
| `norma` | `norma-mysql.msfdemo.com` | `norma-rabbitmq.msfdemo.com` |
| `simsek` | `simsek-mysql.msfdemo.com` | `simsek-rabbitmq.msfdemo.com` |
| `mc4` | `mc4-mysql.msfdemo.com` | `mc4-rabbitmq.msfdemo.com` |

### Test / Internal

| Client | MySQL Tunnel | RabbitMQ Tunnel |
|--------|-------------|------------------|
| `msfdemo` | `msfdemo-mysql.msfdemo.com` | `msfdemo-rmq.msfdemo.com` |

**`msfdemo` is MSF's internal test server — NOT a real customer.** Same Cloudflare-tunnel pattern as production clients. Use for QA, demos, and validating new panel features against MSF's own server before deploying to real customers.

---

## Operations

```bash
# View logs
docker compose -f /opt/meta-panel/docker-compose.yml logs -f

# Restart
docker compose -f /opt/meta-panel/docker-compose.yml restart

# Stop
docker compose -f /opt/meta-panel/docker-compose.yml down

# Update image to latest
cd /opt/meta-panel && docker compose pull && docker compose up -d

# Update any config value
nano /opt/meta-panel/.env
cd /opt/meta-panel && docker compose up -d
```

---

## Updating a Value Later

All panel/client settings can be changed by editing `/opt/meta-panel/.env`:

```bash
sudo nano /opt/meta-panel/.env
# change DASS_mysql__datasource__password=newpass
cd /opt/meta-panel && sudo docker compose up -d
```

The container will restart and pick up the new value automatically.

---

## DASS_* Override Reference

Any field in `system.ini` can be overridden using this env var pattern:

| system.ini key | env var |
|---------------|---------|
| `mysql.datasource.password` | `DASS_mysql__datasource__password` |
| `mysql.datasource.username` | `DASS_mysql__datasource__username` |
| `mysql.datasource.jdbcUrl` | `DASS_mysql__datasource__jdbcUrl` |
| `rabbit.host` | `DASS_rabbit__host` |
| `rabbit.password` | `DASS_rabbit__password` |
| `settings.workstationId` | `DASS_settings__workstationId` |
| `settings.panelId` | `DASS_settings__panelId` |
| `customerName` | `DASS_customerName` |
| `host` | `DASS_host` |
| `language` | `DASS_language` |
| `country` | `DASS_country` |

(Any key in `system.ini` works — just replace `.` with `__` and prefix `DASS_`.)
