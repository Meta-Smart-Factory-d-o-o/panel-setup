# MSF Panel Setup — One-Command Installer

Installs an MSF panel directly on a host machine (no Docker), with full GUI
support. Handles Cloudflare tunnels, hardware scripts, `meta.jar` download,
`system.ini` configuration, and auto-start via supervisord.

## Quick Start

```bash
curl -sSL https://raw.githubusercontent.com/Meta-Smart-Factory-d-o-o/panel-setup/main/install.sh | sudo bash -s -- \
  --client norma \
  --workstation-id 12345 \
  --panel-id 12345 \
  --mysql-db dass_norma \
  --mysql-password '<MYSQL_PASS>' \
  --rabbit-password '<RABBIT_PASS>'
```

That's it. The panel:
- Auto-starts on next boot.
- Reconnects on crash.
- GUI shows on the panel's physical display.

## What this installer does

1. **Installs OS packages**: `java`, `cloudflared`, `supervisor`, `wget`, `dos2unix`, `jq`
2. **Sets up Cloudflare tunnels** (systemd service `msf-tunnels`):
   - `<client>-mysql.msfdemo.com` → `localhost:3306`
   - `<client>-rabbitmq.msfdemo.com` → `localhost:5672`
3. **Creates `meta` user** and grants hardware permissions (USB autosuspend, `/dev/tty*`, `dialout` group)
4. **Downloads `/opt/meta/`** files from the official `nuriozalp/download` distribution:
   - `meta.jar` (latest release)
   - `meta.sh`, `udev.sh`, `rfid.sh`, `barcode.sh`, `grant_meta_tty_permissions.sh`
   - `conf/logback.xml`
5. **Runs hardware scripts** (`udev`, `rfid`, `barcode`, `grant_meta_tty_permissions`)
6. **Configures `/opt/meta/conf/system.ini`** with client-specific values
   (workstation ID, panel ID, MySQL/RabbitMQ creds, JDBC URL, `customerName`)
7. **Registers `meta.jar` as a supervisord service** (`meta`) — auto-starts on boot

## Supported Clients

### Production

| Client  | MySQL Tunnel                  | RabbitMQ Tunnel                  |
|---------|-------------------------------|----------------------------------|
| norma   | `norma-mysql.msfdemo.com`     | `norma-rabbitmq.msfdemo.com`     |
| simsek  | `simsek-mysql.msfdemo.com`    | `simsek-rabbitmq.msfdemo.com`    |
| mc4     | `mc4-mysql.msfdemo.com`       | `mc4-rabbitmq.msfdemo.com`       |

### Test / Internal

| Client  | MySQL Tunnel                  | RabbitMQ Tunnel              |
|---------|-------------------------------|------------------------------|
| msfdemo | `msfdemo-mysql.msfdemo.com`   | `msfdemo-rmq.msfdemo.com`    |

`msfdemo` is MSF's internal test server. **Not a real customer.** Use for QA, demos, and validating new panel features before deploying to real customers.

## Required arguments

| Flag                  | Purpose                            |
|-----------------------|------------------------------------|
| `--client`            | One of: `norma`, `simsek`, `mc4`, `msfdemo` |
| `--workstation-id`    | Unique workstation ID              |
| `--panel-id`          | Unique panel ID (often same as workstation) |
| `--mysql-db`          | MySQL database name (e.g. `dass_norma`, `teknia_group`) |
| `--mysql-password`    | MySQL root password                |
| `--rabbit-password`   | RabbitMQ password                  |

## Optional arguments

| Flag             | Default                  |
|------------------|--------------------------|
| `--mysql-host`   | `localhost` (via tunnel) |
| `--mysql-port`   | `3306`                   |
| `--mysql-user`   | `root`                   |
| `--rabbit-host`  | `localhost` (via tunnel) |
| `--rabbit-port`  | `5672`                   |
| `--rabbit-user`  | `dass`                   |

## Managing the panel after install

| Action          | Command                                              |
|-----------------|------------------------------------------------------|
| Status          | `sudo supervisorctl status meta`                     |
| Restart         | `sudo supervisorctl restart meta`                    |
| Stop            | `sudo supervisorctl stop meta`                       |
| Live logs       | `sudo tail -f /var/log/supervisor/meta.out.log`      |
| Error logs      | `sudo tail -f /var/log/supervisor/meta.err.log`      |
| Edit config     | `sudo nano /opt/meta/conf/system.ini` then restart   |
| Tunnel status   | `sudo systemctl status msf-tunnels`                  |

## Why no Docker?

The `dass-desktop` Docker image is currently configured for headless mode
(uses `Xvfb` virtual display), so panel GUI never appears on the real display.
Until that image supports both modes, this installer runs `meta.jar` directly
on the host — same as the original `meta.sh` flow — which guarantees the GUI
appears on the physical panel screen.

## Updating the panel

Re-run the same install command — it will:
- Pull the latest `meta.jar` from `nuriozalp/download` releases
- Re-apply hardware scripts
- Re-configure `system.ini` with any updated args
- Restart the panel service
