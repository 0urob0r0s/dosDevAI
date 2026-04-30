# 86Box + Open Watcom + Claude Code — DOS Dev Sandbox

A Docker container for AI-assisted DOS development. Real DOS, real BIOS, real
INT 2Fh redirector behavior — not an interpreter. Designed for Apple Silicon
hosts but builds anywhere `linux/amd64` runs.

> **AI agents:** read [`AGENT.md`](AGENT.md) first — it covers what's
> available, how to drive DOS, and what NOT to do. For *building* a DOS
> project (build/install/test loop, serial bridge usage, gotchas) see
> [`PROJECTS.md`](PROJECTS.md). The toolkit reference lives in
> [`tools/86box/README.md`](tools/86box/README.md).

## What's inside

| Layer | Component |
|---|---|
| Build | **Open Watcom** v2 (Linux x86_64 build, cross-compiles 16/32-bit DOS .EXEs) |
| Runtime | **86Box** v5.3 — emulates a complete PC (BIOS, IDE, video, COM ports) |
| DOS | **MS-DOS 6.22** template VHD baked in (see *Licensing* below) |
| Display | **Xvfb + x11vnc** → port `5901`, no auth (dev sandbox only) |
| Serial | **`86box-bridge`** discovers 86Box's host PTY and exposes `/tmp/linux-com1` with raw termios |
| Agent | **Claude Code** + helper tools (`86box-cmd`, `86box-keys`, `86box-screen`, `86box-bridge`) |

The agent drives DOS in two ways:

1. **`86box-cmd`** — non-interactive: writes a BAT to a virtual floppy, boots
   86Box, captures stdout to a file on the floppy, reads it back via mtools.
   No screen scraping, no vision tokens.
2. **VNC** — interactive: keystroke injection via `86box-keys`, screen
   capture via `86box-screen` (which decodes the 80×25 text-mode framebuffer
   to ASCII for cheap text-only round-trips, falling back to raw PNG only
   when the screen isn't text mode).

## Build

```bash
docker compose build
```

First build pulls the 86Box AppImage (~85 MB), the official ROM repo
(~70 MB), and the Open Watcom Linux build. Expect ~5 minutes on a fast
connection. Subsequent builds are cached.

## Run

```bash
docker compose run --rm dos-claude              # interactive shell
docker compose run --rm dos-claude claude       # Claude Code session
```

The first time, `entrypoint.sh`:
- seeds `./dos-c/dos.img` from the baked template,
- patches `CONFIG.SYS` with `LASTDRIVE=Z` (so redirector projects can map
  X..Z) and `AUTOEXEC.BAT` with the `86box-cmd` hook,
- generates a default `./dos-c/86box.cfg` (ninja machine + serial1 PTY
  passthrough enabled), and
- starts the headless display stack so `vnc://localhost:5901` answers
  immediately.

All these files are bind-mounted, so per-project state survives container
restarts. Re-create the VHD by deleting `./dos-c/dos.img`; the patches
are reapplied on the next start.

### Watch DOS in real time

VNC is on host port `5901`, explicitly bound to all interfaces in
`docker-compose.yml`:

```bash
open vnc://localhost:5901             # macOS
# or any VNC client: 127.0.0.1:5901
```

No password (dev only). Until you launch a 86Box session, the VNC client
just shows a blank Xvfb desktop.

## Tools the agent uses

All under `/usr/local/bin/`. Source lives in `/workspace/tools/86box/`.
Naming convention: source filenames keep their `.sh` / `.py` extension
(for editor support); the Dockerfile drops the extension on install, so
every tool is on PATH as `86box-<name>`.

| Command | Purpose |
|---|---|
| `86box-setup` | Idempotent installer — fetches AppImage + ROMs |
| `86box-gen-config` | Generate `86box.cfg` (default machine: `ninja` i486DX2/66) |
| `86box-run display-up \| start \| stop \| status \| wait-vnc` | Start/stop/inspect 86Box and the display stack |
| `86box-cmd "DIR C:\\"` | Run DOS command(s) in a fresh cold-boot, capture stdout |
| `86box-pcmd start \| run "CMD" \| stop` | Persistent DOS REPL over COM2 — sub-second runs after one boot |
| `86box-install-dos` | mcopy host files into `dos.img` at a DOS path |
| `86box-bridge` | Discover 86Box's serial PTY + raw bridge → `/tmp/linux-com1` (or COM2 with `--port 2`) |
| `86box-keys type \| press \| line` | Inject keystrokes via VNC |
| `86box-screen` | Capture VNC + decode 80×25 text mode to ASCII |
| `86box-build-fontmap` | Regenerate the VGA glyph fingerprint table |
| `86box-pcmd` | Postmortem stub for an abandoned design (see toolkit README) |

### Quick smoke

```bash
docker compose run --rm dos-claude bash -lc '
  86box-cmd "VER" "DIR C:\\" "MEM /C"
'
```

### End-to-end smoke (build → install → test on a real DOS .EXE)

A reference project lives at [`examples/hello/`](examples/hello/) — a
~30-line `hello.c`, a one-target makefile, and a `test.sh` that exercises
the whole loop. Run inside the container:

```bash
bash /workspace/examples/hello/test.sh
```

Prints `Results: 4 passed, 0 failed` in ~40 s. Source for the test is
the simplest possible reference for any new DOS project to copy.

## File transfer

The bridge between Linux and DOS is `mtools` against the project's
`dos.img` (a flat raw disk image — `qemu-img convert`'d once from the
baked VHD on first run, then never touched by qemu-img). The first FAT16
partition starts at LBA 62, so you can write to it directly:

```bash
# inside the container
OFFSET=$((62 * 512))

mcopy -i /dos/c/dos.img@@${OFFSET} myprogram.exe ::
mdir   -i /dos/c/dos.img@@${OFFSET} ::
mtype  -i /dos/c/dos.img@@${OFFSET} ::AUTOEXEC.BAT
```

Stop 86Box (`86box-run stop`) before doing concurrent writes against
`dos.img` — leaving 86Box running while mtools rewrites FAT sectors
risks divergence between DOS BUFFERS and the on-disk state.

`dos.img` is held sparse on the host filesystem — the apparent 234 MB only
costs ~6 MB of actual disk on a clean DOS install.

`86box-cmd` uses the same approach for the agent floppy (`AGENT.IMG`) so
DOS can run a fresh `RUN.BAT` per command and the host can read back
`OUT.TXT` without touching the running emulator.

## Project bootstrap

For a new DOS project:

```bash
mkdir myproj && cd myproj
mkdir dos-c workspace .claude

# copy the template files into the new project
cp /path/to/template/{Dockerfile,docker-compose.yml,entrypoint.sh,template_dos-c.vhd} .
cp -r /path/to/template/tools .

docker compose run --rm dos-claude
```

Inside the container, `/dos/c/` is your project's writable DOS C: drive,
`/dos/src/` is wherever you want to mount source from (typically your
host's working dir), and `/workspace/` is the build/agent workspace.

## Serial passthrough (COM1)

The default `86box.cfg` enables 86Box's host PTY passthrough on COM1.
86Box opens an internal `openpty()` pair on each VM launch and writes
`serial_passthrough: Slave side is /dev/pts/N` to its log; `86box-bridge`
watches the log, opens that PTY with raw termios, creates an
intermediate raw PTY pair under our control, and symlinks
`/tmp/linux-com1` to the slave. Application code (a Linux daemon, a
serial echo server, etc.) just opens `/tmp/linux-com1` via pyserial /
socat / whatever — the bridge takes care of byte-rate throttling
(1 ms/byte, matching 9600 baud, so 86Box's UART RX register doesn't
overrun under host bursts) and termios cooking (no IXON/ICRNL/ECHO).

```bash
86box-run start /dos/c          # boot the VM
86box-bridge                    # discover PTY + start shuttle
ls -l /tmp/linux-com1           # → /dev/pts/N (raw, ready to use)
```

> **About `tcp_server` mode in 86Box's cfg.** `86box-gen-config` accepts
> a legacy `--serial1-tcp PORT` flag that records `tcp_server` mode, but
> 86Box v5.3 b8200 ignores it and falls back to PTY mode regardless.
> Use `--serial1-passthrough` (the new default) and `86box-bridge`. The
> `5556` port left mapped in `docker-compose.yml` is reserved for any
> TCP service your project wants to publish from inside the container.

## Mounts

```
./dos-c       → /dos/c                  → C: inside 86Box (dos.img + 86box.cfg)
./workspace   → /workspace              → Linux dev workspace
./.claude     → /home/coder/.claude     → Claude Code state
```

`create_host_path: true` so missing directories are auto-created.

## Sudo

Inside the container, `coder` has passwordless sudo:

```bash
sudo apt-get install -y vim
```

## Licensing

- **86Box** is GPLv2; built from the official AppImage release.
- **86Box ROMs** repo is permissively licensed where individual ROMs allow;
  see `/opt/86box/roms/LICENSE`.
- **Open Watcom** is under the Sybase Open Watcom Public License.
- **Template VHD**: the file shipped in this repo as `template_dos-c.vhd`
  may contain MS-DOS 6.22, which is **not redistributable**. Replace with
  FreeDOS 1.3 (MIT-licensed) before sharing this repo publicly.

## Architecture notes

- The container is `linux/amd64`. On Apple Silicon hosts, Docker Desktop
  runs it under QEMU user-mode emulation. Inside, 86Box itself emulates an
  x86 PC. Two-level emulation is slow (~286-class effective speed), but
  fine for 9600-baud serial work, BIOS testing, and most DOS apps.
- The Qt VNC platform plugin doesn't render 86Box's emulator viewport
  correctly (only the menu bar paints). We use Xvfb + x11vnc instead;
  much more reliable. See `tools/86box/run.sh`.
- `86box-cmd` does NOT scrape the screen — it uses an agent floppy image
  as the stdout channel. Zero vision tokens per command.
- DOSBox-X was the original sandbox runtime but its DOS dispatches all
  file ops directly to its internal `Drives[]` table without going
  through INT 2Fh, which makes it useless for redirector-based DOS
  development. 86Box uses real BIOS + real INT 2Fh dispatch and so
  matches actual hardware behavior.
- The current `86box-pcmd` is the COM2-DOS-daemon design: a small
  Watcom-built `PCMDD.EXE` runs on the DOS side as a foreground REPL,
  reading length-prefixed commands from COM2 and writing back
  length+errorlevel+stdout. Sub-second per `run` after one ~30 s cold
  boot; TSR state persists across runs. The earlier v1 implementation
  attempted a poll-loop over the AGENT.IMG floppy and was unworkable
  (DOS BUFFERS caches the floppy FAT/dir, host writes invisible to
  DOS, OUT.TXT got corrupted by free-cluster reuse). The postmortem of
  v1 is preserved in `feedback_no_floppy_poll.md` so the lessons aren't
  lost; the current implementation is the COM2 design that postmortem
  proposed as the right fix.
