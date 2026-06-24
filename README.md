# MSF Panel Setup — Interactive One-Command Installer

Interactive installer for MSF panels. Run a single command on the panel and it
asks for everything it needs, then writes `/opt/meta/conf/system.ini` and
auto-starts the panel via supervisord on the host (real GUI on physical display).

## How to run

On the panel (must be root):

```bash
curl -sSL https://raw.githubusercontent.com/Meta-Smart-Factory-d-o-o/panel-setup/main/install.sh | sudo bash
```

That's it — no flags. The script prompts you interactively.

## What it asks

| Prompt                          | Example / values                          |
|---------------------------------|-------------------------------------------|
| **Panel ID**                    | `206072`                                  |
| **API host URL**                | `https://msfdemo.com/api/`                |
| **Use Cloudflare tunnel?**      | `y` / `N`                                 |
| → MySQL tunnel hostname         | `msfdemo-my.msfdemo.com` → `localhost:3306` (only if tunnel = y) |
| → RabbitMQ tunnel hostname      | `msfdemo-rmq.msfdemo.com` → `localhost:5672` (only if tunnel = y) |
| **Install RustDesk?**           | `y` / `N` (skipped if already installed)  |
| **Install AnyDesk?**            | `y` / `N` (skipped if already installed)  |
| **Does this panel talk to a PLC?** | `y` / `N` — if `y`, installs Python + `pycomm3`/`python-snap7` into `/opt/meta/plc-venv` |
| **Install Mosquitto MQTT broker?** | `y` / `N` — if `y`, installs `mosquitto` + `mosquitto-clients` and enables the service |
| **Proceed?**                    | confirmation before anything is installed |

It then writes a clean `system.ini` containing just `host` + `settings.panelId`.
Any other `system.ini` keys (JDBC URL, RabbitMQ credentials, theme, etc.) are
edited afterwards in `/opt/meta/conf/system.ini` (see *Managing the panel*).

## What gets installed

1. **OS packages**: `java`, `cloudflared`, `supervisor`, `wget`, `dos2unix`, `jq`
   - **PLC (only if you answer yes):** `python3` (+`venv`/`pip`) and a **Python venv** at
     `/opt/meta/plc-venv` with `pycomm3` (Allen-Bradley Logix) + `python-snap7` (Siemens S7, incl. native `libsnap7`)
2. **Cloudflare tunnels** (systemd service `msf-tunnels`):
   - `--mysql-tunnel <host>` → `localhost:3306`
   - `--rabbit-tunnel <host>` → `localhost:<rabbit-port>`
3. **Remote-access tools** (optional, asked interactively — skipped if already installed):
   - **RustDesk** — latest `x86_64.deb` from GitHub releases
   - **AnyDesk** — from the official `deb.anydesk.com` apt repo
4. **`meta` user** + hardware permissions (USB autosuspend, `/dev/tty*`, `dialout`)
5. **`/opt/meta/`** files from `nuriozalp/download`:
   - `meta.jar` (latest release)
   - `meta.sh`, `udev.sh`, `rfid.sh`, `barcode.sh`, `grant_meta_tty_permissions.sh`
   - `conf/logback.xml`
6. **Hardware scripts** executed (udev rules, RFID, barcode, TTY permissions)
7. **`/opt/meta/conf/system.ini`** populated with all flags + any extras from `--set`
8. **supervisord program `meta`** registered — auto-starts on boot, restarts on crash

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
| Live logs       | `sudo tail -f /opt/meta/metalog.log`                 |
| Rolling logs    | `/opt/meta/logs/{info,warn,error}/…` (via `logback.xml`) |
| Edit config     | `sudo nano /opt/meta/conf/system.ini` (then restart) |
| Tunnel status   | `sudo systemctl status msf-tunnels`                  |

## Why no Docker?

The `dass-desktop` Docker image currently runs `Xvfb` (virtual display) in
its entrypoint, so the GUI never appears on the panel's physical screen.
Until that image supports both headless and panel modes, this installer
runs `meta.jar` directly on the host (same as the original `meta.sh` flow),
which guarantees the GUI shows on the real display.
