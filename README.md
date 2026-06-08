# MSF Panel Setup — Generic One-Command Installer

Generic installer for MSF panels — no hardcoded client list. You pass exactly
what each panel needs (tunnel hostnames, IDs, JDBC URL, credentials, customer
name) and the script applies everything to `/opt/meta/conf/system.ini`, then
auto-starts the panel via supervisord on the host (real GUI on physical display).

## Norma — production panel

```bash
curl -sSL https://raw.githubusercontent.com/Meta-Smart-Factory-d-o-o/panel-setup/main/install.sh | sudo bash -s -- \
  --workstation-id 12345 \
  --panel-id 12345 \
  --customer norma \
  --mysql-tunnel norma-mysql.msfdemo.com \
  --rabbit-tunnel norma-rabbitmq.msfdemo.com \
  --jdbc-url 'jdbc:mysql://localhost:3306/dass_norma?useSSL=false&autoReconnect=true' \
  --mysql-password '<MYSQL_PASS>' \
  --rabbit-host localhost \
  --rabbit-port 5672 \
  --rabbit-password '<RABBIT_PASS>' \
  --rabbit-use-ssl true
```

## msfdemo — MSF test panel

Same shape as Norma, just different values:

```bash
curl -sSL https://raw.githubusercontent.com/Meta-Smart-Factory-d-o-o/panel-setup/main/install.sh | sudo bash -s -- \
  --workstation-id 441297 \
  --panel-id 441297 \
  --customer msfdemo \
  --mysql-tunnel msfdemo-mysql.msfdemo.com \
  --rabbit-tunnel msfdemo-rmq.msfdemo.com \
  --jdbc-url 'jdbc:mysql://localhost:3306/teknia_group?useSSL=false&connectTimeout=10000&socketTimeout=10000&autoReconnect=true' \
  --mysql-password '<MYSQL_PASS>' \
  --rabbit-host localhost \
  --rabbit-port 5672 \
  --rabbit-password 'dass123456' \
  --rabbit-use-ssl false
```

## Required flags

| Flag                  | What                                                    |
|-----------------------|---------------------------------------------------------|
| `--workstation-id`    | Workstation ID                                          |
| `--panel-id`          | Panel ID                                                |
| `--customer`          | `customerName` field (e.g. `norma`, `msfdemo`, `mc4`)   |
| `--mysql-tunnel`      | Cloudflare hostname for MySQL                           |
| `--rabbit-tunnel`     | Cloudflare hostname for RabbitMQ                        |
| `--jdbc-url`          | Full JDBC URL written verbatim into `system.ini`        |
| `--mysql-password`    | MySQL password                                          |
| `--rabbit-host`       | RabbitMQ host (e.g. `localhost`)                        |
| `--rabbit-port`       | RabbitMQ port (e.g. `5672`)                             |
| `--rabbit-password`   | RabbitMQ password                                       |
| `--rabbit-use-ssl`    | `true` or `false` (see behaviour below)                 |

## Optional flags

| Flag                | Default      |
|---------------------|--------------|
| `--mysql-user`      | `root`       |
| `--rabbit-user`     | `dass`       |

### `--rabbit-use-ssl` behaviour

| Value   | Effect on `system.ini`                                  |
|---------|----------------------------------------------------------|
| `true`  | Writes `rabbit.useSslProtocol=true`                      |
| `false` | **Removes** the `rabbit.useSslProtocol=` line entirely   |

## Override any other `system.ini` key

Use `--set key=value` (repeatable) to push any extra override:

```bash
... \
  --set settings.theme=2 \
  --set settings.wareHouseId=406
```

## What gets installed

1. **OS packages**: `java`, `cloudflared`, `supervisor`, `wget`, `dos2unix`, `jq`, `python3` (+`venv`/`pip`)
   - **Python venv** `/opt/meta/plc-venv` with PLC client libs: `pycomm3` (Allen-Bradley Logix) + `python-snap7` (Siemens S7)
2. **Cloudflare tunnels** (systemd service `msf-tunnels`):
   - `--mysql-tunnel <host>` → `localhost:3306`
   - `--rabbit-tunnel <host>` → `localhost:<rabbit-port>`
3. **`meta` user** + hardware permissions (USB autosuspend, `/dev/tty*`, `dialout`)
4. **`/opt/meta/`** files from `nuriozalp/download`:
   - `meta.jar` (latest release)
   - `meta.sh`, `udev.sh`, `rfid.sh`, `barcode.sh`, `grant_meta_tty_permissions.sh`
   - `conf/logback.xml`
5. **Hardware scripts** executed (udev rules, RFID, barcode, TTY permissions)
6. **`/opt/meta/conf/system.ini`** populated with all flags + any extras from `--set`
7. **supervisord program `meta`** registered — auto-starts on boot, restarts on crash

## Running PLC integration scripts

The PLC client libs live in the isolated venv at `/opt/meta/plc-venv`, **not** in
the system Python. Run scripts with that venv's interpreter:

```bash
/opt/meta/plc-venv/bin/python /opt/meta/your_plc_script.py
```

Or activate the venv for an interactive session:

```bash
source /opt/meta/plc-venv/bin/activate
python your_plc_script.py
deactivate
```

In a script's shebang, point at the venv directly:

```python
#!/opt/meta/plc-venv/bin/python
from pycomm3 import LogixDriver     # Allen-Bradley / Rockwell Logix
import snap7                        # Siemens S7
from snap7.client import Area
```

Verify the libs are importable:

```bash
/opt/meta/plc-venv/bin/python -c "import pycomm3, snap7; print('PLC libs OK')"
```

## Managing the panel

| Action          | Command                                              |
|-----------------|------------------------------------------------------|
| Status          | `sudo supervisorctl status meta`                     |
| Restart         | `sudo supervisorctl restart meta`                    |
| Stop            | `sudo supervisorctl stop meta`                       |
| Live logs       | `sudo tail -f /var/log/supervisor/meta.out.log`      |
| Error logs      | `sudo tail -f /var/log/supervisor/meta.err.log`      |
| Edit config     | `sudo nano /opt/meta/conf/system.ini` (then restart) |
| Tunnel status   | `sudo systemctl status msf-tunnels`                  |

## Why no Docker?

The `dass-desktop` Docker image currently runs `Xvfb` (virtual display) in
its entrypoint, so the GUI never appears on the panel's physical screen.
Until that image supports both headless and panel modes, this installer
runs `meta.jar` directly on the host (same as the original `meta.sh` flow),
which guarantees the GUI shows on the real display.
