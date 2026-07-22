# Web Console Deployment

The RFSoC web console is a Vue 3 / Element Plus application served by FastAPI.
It is an operational console rather than a reusable HTML admin template: the
board editor, live events, waveform preview, UART terminal, and programming
workflow depend on component state and authenticated REST/WebSocket APIs.

The first production release supports one selected board per waveform job.
Users independently enable CH1-CH8 and run `upload -> ARM -> local TRIGGER`.
Multi-board execution is rejected and does not perform hardware I/O.

## Build And Install

The examples below install the repository at `/opt/xczu47dr-rfdc` and runtime
state at `/var/lib/rfsoc-web`. Adjust both systemd unit paths if the checkout is
kept elsewhere.

```bash
sudo useradd --system --home /var/lib/rfsoc-web --create-home --shell /usr/sbin/nologin rfsoc-web
sudo usermod -aG dialout rfsoc-web

sudo mkdir -p /opt/xczu47dr-rfdc /etc/rfsoc-web /var/lib/rfsoc-web
sudo chown -R rfsoc-web:rfsoc-web /var/lib/rfsoc-web

cd /opt/xczu47dr-rfdc
python3 -m venv .venv
.venv/bin/pip install -r software/requirements.txt
cd software/webui
npm ci
npm run build
```

Copy `deploy/rfsoc-web.env.example` to `/etc/rfsoc-web/rfsoc-web.env`, set a
unique administrator password, and restrict access to the service account:

```bash
sudo install -m 0640 -o root -g rfsoc-web deploy/rfsoc-web.env.example /etc/rfsoc-web/rfsoc-web.env
sudo editor /etc/rfsoc-web/rfsoc-web.env
sudo install -m 0644 deploy/systemd/hw-server.service /etc/systemd/system/hw-server.service
sudo install -m 0644 deploy/systemd/rfsoc-web.service /etc/systemd/system/rfsoc-web.service
sudo systemctl daemon-reload
sudo systemctl enable --now hw-server.service rfsoc-web.service
```

`rfsoc-web` must be in `dialout` for UART access. JTAG USB permissions depend on
the installed Xilinx cable udev rules; add the service account to the local
cable-access group if those rules use one. Restart the services after changing
group membership.

## Initial Operation

1. Open `http://SERVER_IP:8000` on the trusted laboratory network and log in
   with `RFSOC_WEB_ADMIN_USERNAME` / `RFSOC_WEB_ADMIN_PASSWORD`.
2. Create individual user accounts. Do not share the administrator account for
   normal waveform work.
3. Run an inventory scan, then register or edit each board with its exact IP,
   JTAG cable serial, target profile, and stable UART path.
4. Verify the RFCTRL2 PL capability and RFDC-ready state, acquire one board,
   refresh its hardware RFDC configuration, and run a Dry Run with only the
   intended channels enabled. UART state is optional diagnostic information.
5. Disable simulation only after board-local ARM, trigger, and abort/mute have
   been validated on that board.

The bootstrap administrator is created only when the database has no users.
Changing the environment password later does not overwrite an existing account;
use user administration or start with a new runtime database when reprovisioning.

## Environment Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `RFSOC_WEB_RUNTIME_DIR` | `~/.local/state/xczu47dr-rfdc` | SQLite database, waveform runs, releases, and logs |
| `RFSOC_WEB_SIMULATION` | `0` | `1` prevents waveform and RFCTRL2 hardware I/O |
| `RFSOC_WEB_ADMIN_USERNAME` | `admin` | Bootstrap administrator name for an empty database |
| `RFSOC_WEB_ADMIN_PASSWORD` | `admin12345` | Bootstrap password; always override in deployment |
| `RFSOC_WEB_COOKIE_SECURE` | `0` | Set to `1` only when browsers access the service through HTTPS |
| `RFSOC_WEB_ARTIFACT_MAX_BYTES` | `1073741824` | Maximum size of each uploaded `.bit` or `.elf` file |
| `RFSOC_WEB_VIVADO_BIN` | Xilinx 2024.2 path | Vivado executable used for JTAG discovery |
| `RFSOC_WEB_VIVADO_TIMEOUT_S` | `30` | JTAG discovery timeout |
| `RFSOC_WEB_HW_SERVER_URL` | `localhost:3121` | Existing `hw_server` endpoint |
| `RFSOC_WEB_XSCT_BIN` | Xilinx 2024.2 path | XSCT executable used for controlled temporary deployment |
| `RFSOC_WEB_PROGRAM_TIMEOUT_S` | `900` | Maximum total XSCT deployment time before termination |
| `RFSOC_WEB_PROGRAM_VERIFY_TIMEOUT_S` | `20` | RFCTRL2/UART post-deployment verification window |
| `RFSOC_WEB_SERIAL_RECONNECT_S` | `3` | Delay before reopening a disconnected UART |

## Security And Data

The service is intended for a trusted internal network. Authentication uses an
HttpOnly same-site session cookie and a CSRF token for mutations. Bind Uvicorn
to a private interface or place it behind the laboratory reverse proxy; do not
publish port 8000 directly to the Internet.

Back up `RFSOC_WEB_RUNTIME_DIR/rfsoc_web.sqlite3` together with its `artifacts`
and `runs` directories. Artifact releases are immutable through the API. JTAG
deployment is temporary and does not write QSPI, SD, or eMMC. UART access is
read-only; no serial command endpoint is exposed, and runtime RFDC apply does
not depend on a UART mapping or serial output.

Use the journal for service diagnostics:

```bash
journalctl -u hw-server.service -u rfsoc-web.service -f
```
