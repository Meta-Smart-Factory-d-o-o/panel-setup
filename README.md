# MSF Panel Setup

One-command installer for MSF panel applications across all clients (Norma, Simsek, MC4).

---

## Quick Start

On a fresh panel (Ubuntu/Debian), run as root:

```bash
curl -sSL https://raw.githubusercontent.com/msf/panel-setup/main/install.sh | sudo bash -s -- \
  --client norma \
  --workstation-id 441243 \
  --panel-id 441243 \
  --mysql-db norma_db \
  --mysql-password "yourpass" \
  --rabbit-password "yourpass"
```

Or run interactively (script will prompt for values):

```bash
curl -sSL https://raw.githubusercontent.com/msf/panel-setup/main/install.sh | sudo bash
```

---

## What it Does

1. Installs **Docker** (if not present)
2. Installs **cloudflared** (if not present)
3. Sets up Cloudflare tunnels for MySQL (port 3306) and RabbitMQ (port 5672) — routes to the correct client's server
4. Generates `.env` file with panel-specific values
5. Pulls the latest panel Docker image from GHCR
6. Starts the panel container (auto-restarts on reboot)

---

## Supported Clients

| Client | MySQL Tunnel | RabbitMQ Tunnel |
|--------|--------------|-----------------|
| `norma` | `norma-mysql.msfdemo.com` | `norma-rabbitmq.msfdemo.com` |
| `simsek` | `simsek-mysql.msfdemo.com` | `simsek-rabbitmq.msfdemo.com` |
| `mc4` | `mc4-mysql.msfdemo.com` | `mc4-rabbitmq.msfdemo.com` |

To add a new client, edit `install.sh` and add a new `case` entry.

---

## Required Parameters

| Flag | Description | Example |
|------|-------------|---------|
| `--client` | Client name | `norma` |
| `--workstation-id` | Unique workstation ID | `441243` |
| `--panel-id` | Unique panel ID | `441243` |
| `--mysql-db` | MySQL database name | `norma_db` |
| `--mysql-password` | MySQL password | `secret` |
| `--rabbit-password` | RabbitMQ password | `secret` |

## Optional Parameters

| Flag | Default | Description |
|------|---------|-------------|
| `--workcenter-id` | `425` | Workcenter ID |
| `--workstation-name` | `GENERIC` | Display name |
| `--warehouse-id` | `406` | Warehouse ID |
| `--customer` | same as `--client` | Customer name in system.ini |
| `--language` | `TR` | Language code |
| `--country` | `US` | Country code |
| `--mysql-user` | `root` | MySQL user |
| `--rabbit-user` | `dass` | RabbitMQ user |

---

## After Installation

Panel files are at `/opt/meta-panel/`.

```bash
# View logs
docker compose -f /opt/meta-panel/docker-compose.yml logs -f

# Restart panel
docker compose -f /opt/meta-panel/docker-compose.yml restart

# Stop panel
docker compose -f /opt/meta-panel/docker-compose.yml down

# Update to latest version
cd /opt/meta-panel && docker compose pull && docker compose up -d
```

---

## Repo Structure

```
panel-setup/
├── install.sh           # Main one-command installer
├── Dockerfile           # Panel image build definition
├── entrypoint.sh        # Generates system.ini from env vars
├── docker-compose.yml   # Template for panel deployment
├── .env.example         # Template for panel-specific values
└── .github/workflows/
    └── build.yml        # CI/CD: builds & pushes image to GHCR
```

---

## CI/CD

On every push to `main` branch, GitHub Actions automatically:
1. Builds the Docker image
2. Pushes to `ghcr.io/msf/panel-setup:latest`

Panels can then pull the latest image with `docker compose pull && docker compose up -d`.

---

## Examples

### Norma US Panel
```bash
curl -sSL <url>/install.sh | sudo bash -s -- \
  --client norma --workstation-id 441267 --panel-id 441267 \
  --mysql-db norma_db --mysql-password "root123" --rabbit-password "dass123456"
```

### Simsek Panel
```bash
curl -sSL <url>/install.sh | sudo bash -s -- \
  --client simsek --workstation-id 5001 --panel-id 5001 \
  --mysql-db teknia_group --mysql-password "t!eK*nia<p123" --rabbit-password "dass123456"
```

### MC4 Panel
```bash
curl -sSL <url>/install.sh | sudo bash -s -- \
  --client mc4 --workstation-id 9001 --panel-id 9001 \
  --mysql-db mc4_db --mysql-password "mc4pass" --rabbit-password "mc4pass"
```
