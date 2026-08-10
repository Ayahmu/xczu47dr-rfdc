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
3. Run the FPGA network scan. The workspace is populated only when RFCTRL2
   `NETWORK_GET` returns a non-empty `device_uid`; Linux USB/JTAG and UART
   discovery are diagnostic metadata and do not create board records. After a
   board is discovered, an administrator may edit its label, location, JTAG
   serial, and UART path, but cannot manually create an undiscovered board.
4. Verify the RFCTRL2 PL capability and RFDC-ready state, acquire one board,
   refresh its hardware RFDC configuration, and run a Dry Run with only the
   intended channels enabled. UART state is optional diagnostic information.
5. Disable simulation only after board-local ARM, trigger, and abort/mute have
   been validated on that board.

The bootstrap administrator is created only when the database has no users.
Changing the environment password later does not overwrite an existing account;
use user administration or start with a new runtime database when reprovisioning.

The web backend prepares FPGA UDP links automatically during network scan. The
`rfsoc-web.service` unit must keep both `CAP_NET_ADMIN` and `CAP_NET_RAW`:
`CAP_NET_ADMIN` changes link/address state and `CAP_NET_RAW` permits
`SO_BINDTODEVICE` on the board-facing UDP sockets. Without them, scan stops at
the Host NIC stage with an explicit capability error. The service configures
each candidate port idempotently with `ip link set dev <ifname> up` and
`ip address replace <source-cidr> dev <ifname>` for formal, link-local, and
bootstrap discovery addresses.

For directly attached boards, keep each 10G port in a separate subnet to avoid
ambiguous ARP and routing. These port profiles define address pools and artifact
defaults only; they are not board inventory and they do not create workspace
boards until RFCTRL2 discovery reports a `device_uid`.

| Profiled server port | Server source | First assigned PL IP | Normal target |
| --- | --- | --- | --- |
| `enp225s0f0` | `192.168.1.10` | `192.168.1.128` | `custom_xczu47dr` |
| `enp225s0f1` | `192.168.2.10` | `192.168.2.128` | `custom_xczu47dr` |

Build and upload `custom_xczu47dr` for normal single-board operation. The
bandwidth stress target `custom_xczu47dr_bw` is reserved for standalone testing.
The bootstrap identity starts at `192.168.254.254` on each isolated
point-to-point link; the web console uses the selected server interface to
address the discovered board and then applies a unique formal IP/MAC.
If the links are later joined through a switch, formal IP and MAC values must
be unique.
Persist any required server-facing addresses with the server's normal network
manager only after validating the corresponding physical links. The number of
boards in the workspace is determined by RFCTRL2 discovery, not by this
example table or by the number of configured NIC profiles.

## Continuous Playback Output

The output page offers `Single Shot` and `Continuous Playback` modes.
Continuous playback is a hardware loop mode: the server configures RFDC over
RFCTRL2 UDP, generates one shared loop cache (sine/XY/readout/Z in either IQ or
Real format), uploads it to DDR, then sends exactly one `ARM` and one
`TRIGGER`. After that the PL refills the same DDR frame locally and keeps the
DAC stream running until the requested duration expires or the operator clicks
stop/mute. Each channel's delay and trailing zero padding are inside the
uploaded loop cache, so every cycle is `delay zeros -> waveform -> remaining
zeros`.

This mode does not repeatedly upload waveform data and does not send a UDP
trigger for every loop. The terminal task state is `DONE` after the timed mute,
so the board run lock is released and the next task can be created immediately.

## Environment Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `RFSOC_WEB_RUNTIME_DIR` | `~/.local/state/xczu47dr-rfdc` | SQLite database, waveform runs, releases, and logs |
| `RFSOC_WEB_SIMULATION` | `0` | `1` prevents waveform and RFCTRL2 hardware I/O |
| `RFSOC_WEB_ADMIN_USERNAME` | `admin` | Bootstrap administrator name for an empty database |
| `RFSOC_WEB_ADMIN_PASSWORD` | `admin12345` | Bootstrap password; always override in deployment |
| `RFSOC_WEB_COOKIE_SECURE` | `0` | Set to `1` only when browsers access the service through HTTPS |
| `RFSOC_WEB_ARTIFACT_MAX_BYTES` | `1073741824` | Maximum size of each uploaded `.bit` or `.elf` file |
| `RFSOC_WEB_USB_SYSFS_ROOT` | `/sys/bus/usb/devices` | Linux sysfs path used to enumerate Digilent JTAG adapters without Vivado |
| `RFSOC_WEB_XSCT_BIN` | Xilinx 2024.2 path | XSCT executable used for controlled temporary deployment |
| `RFSOC_WEB_PROGRAM_TIMEOUT_S` | `900` | Maximum total XSCT deployment time before termination |
| `RFSOC_WEB_PROGRAM_VERIFY_TIMEOUT_S` | `20` | RFCTRL2/UART post-deployment verification window |
| `RFSOC_WEB_SERIAL_RECONNECT_S` | `3` | Delay before reopening a disconnected UART |

Linux USB inventory is independent of Xilinx tools. `hw_server` and XSCT are
used only when an administrator explicitly starts a temporary `.bit + .elf`
deployment.

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
