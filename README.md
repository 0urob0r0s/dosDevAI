# DOS Dev Sandbox — dosemu2 (+ 86Box) + Open Watcom + Claude Code

A Docker container for AI-assisted DOS development. Real DOS, real
INT 2Fh redirector dispatch, two emulators to choose from. Designed
for Apple Silicon hosts but builds anywhere `linux/amd64` runs.

> **AI agents:** read [`AGENT.md`](AGENT.md) first — it covers what's
> available, how to drive DOS, and what NOT to do. For *building* a
> DOS project (build/install/test loop, serial work, gotchas) see
> [`PROJECTS.md`](PROJECTS.md). The toolkit references live in
> [`tools/dosemu/README.md`](tools/dosemu/README.md) (primary) and
> [`tools/86box/README.md`](tools/86box/README.md) (alternative).

## What's inside

| Layer | Component |
|---|---|
| Build | **Open Watcom** v2 (Linux x86_64 build, cross-compiles 16/32-bit DOS .EXEs) |
| Runtime — primary | **dosemu2** + **FDPP** — fast (boot ~2-3 s), hostfs-mountable, raw-PTY COM ports |
| Runtime — alternative | **86Box** v5.3 — full PC emulation w/ real BIOS, IDE, separate machine config |
| DOS | **MS-DOS 6.22** template VHD (86Box path) · **FDPP** built-in DOS core (dosemu2 path) |
| Display | **Xvfb + x11vnc** → port `5901`, no auth (dev sandbox only). Shared by both runtimes. |
| Live VNC | **fluxbox + xterm** for dosemu2 live sessions; Qt window for 86Box |
| Serial | dosemu2: raw PTY at `/tmp/dos-com1` (no bridge) · 86Box: `86box-bridge` shuttle |
| Agent | **Claude Code** + helper tools (`dosemu-*`, `86box-*`) |

The agent drives DOS in three ways:

1. **`dosemu-cmd`** (primary, ~5 s/call) — non-interactive cleanroom
   runner. Refreshes dosemu env between every test, captures the DOS
   screen as text, no vision tokens. Hostfs mount via `-d` skips the
   "install into image" step entirely.
2. **`86box-cmd`** (alternative, ~30 s/call) — same idea for 86Box.
   Use when you specifically need real-BIOS / real-IDE behavior.
3. **VNC** (interactive, both emulators) — `dosemu-vnc-start` puts a
   fluxbox+xterm dosemu session on port 5901; 86Box natively shows
   its Qt window there. Connect with any VNC client.

## Build

```bash
docker compose build
```

First build pulls the dosemu2 + FDPP packages (~50 MB), the 86Box
AppImage (~85 MB), the official 86Box ROM repo (~70 MB), and the Open
Watcom Linux build. Expect ~5 minutes on a fast connection. Subsequent
builds are cached.

## Run

```bash
docker compose run --rm dos-claude              # interactive shell
docker compose run --rm dos-claude claude       # Claude Code session
```

The first time, `entrypoint.sh`:
- seeds `./dos-c/dos.img` from the baked 86Box template,
- patches `CONFIG.SYS` with `LASTDRIVE=Z` (so redirector projects can
  map X..Z) and `AUTOEXEC.BAT` with the `86box-cmd` hook,
- generates a default `./dos-c/86box.cfg` (ninja machine + serial1 PTY
  passthrough enabled),
- seeds `~/.dosemurc` and `~/.dosemu-vnc.rc` for dosemu2,
- warms `~/.dosemu/drive_c/` with FDPP's fdppconf.sys,
- starts the headless display stack so `vnc://localhost:5901` answers
  immediately.

All these files are bind-mounted, so per-project state survives container
restarts.

### Watch DOS in real time

VNC is on host port `5901`, explicitly bound to all interfaces in
`docker-compose.yml`:

```bash
open vnc://localhost:5901             # macOS
# or any VNC client: 127.0.0.1:5901
```

Until you launch a session, you'll see a blank Xvfb desktop. Then:

```bash
dosemu-vnc-start /dos/c/serdfs/dos/build  # fluxbox + xterm + dosemu
# or
86box-run start /dos/c                    # Qt window (alternative)
```

## Tools the agent uses

### dosemu2 (primary path)

All under `/usr/local/bin/`. Source in `/workspace/tools/dosemu/`.

| Command | Purpose |
|---|---|
| `dosemu-setup` | Idempotent installer (apt) — re-run only if dosemu2 install gets corrupted |
| `dosemu-run display-up \| dumb \| vnc \| stop \| status` | Start/stop the display stack and dosemu sessions |
| `dosemu-cmd "DIR"` | Cleanroom non-interactive runner — boots dosemu fresh per call (~5 s) |
| `dosemu-vnc-start [DIR]` | Live-debug session: fluxbox + xterm + dosemu on VNC port 5901 |
| `dosemu-vnc-stop` | Tear down the live session |

### 86Box (alternative path)

Source in `/workspace/tools/86box/`.

| Command | Purpose |
|---|---|
| `86box-setup` | Idempotent installer — fetches AppImage + ROMs |
| `86box-gen-config` | Generate `86box.cfg` (default machine: `ninja` i486DX2/66) |
| `86box-run display-up \| start \| stop \| status \| wait-vnc` | Manage 86Box + display |
| `86box-cmd "DIR"` | Run DOS command(s) in a fresh 86Box cold-boot (~30 s) |
| `86box-pcmd start \| run "CMD" \| stop` | Persistent DOS REPL over COM2 |
| `86box-install-dos` | mcopy host files into `dos.img` at a DOS path |
| `86box-bridge` | Discover 86Box's serial PTY + raw bridge → `/tmp/linux-com1` |
| `86box-keys`, `86box-screen`, `86box-build-fontmap` | Keystroke / screen / VGA-font helpers |

### Quick smoke (dosemu2)

```bash
docker compose run --rm dos-claude bash -lc '
  dosemu-cmd "VER" "DIR C:" "MEM"
'
```

### Quick smoke (86Box)

```bash
docker compose run --rm dos-claude bash -lc '
  86box-cmd "VER" "DIR C:\\" "MEM /C"
'
```

### End-to-end (build → install → test on a real DOS .EXE)

A reference project at [`examples/hello/`](examples/hello/) — a
~30-line `hello.c`, a one-target makefile, and a `test.sh` that
exercises the whole loop. Run inside the container:

```bash
bash /workspace/examples/hello/test.sh
```

Prints `Results: 4 passed, 0 failed` in ~10 s on the dosemu2 path
(~40 s on the 86Box path).

## File transfer

### dosemu2: just mount the host directory

```bash
dosemu-cmd --mount /your/build/dir "G:" "G:\\PROG.EXE"
```

`-d` flag mounts a host path as the next free DOS letter (typically
`G:`). No mtools, no `dos.img`, no `86box-run stop` step. The DOS side
sees a normal FAT-style drive with your live host files.

### 86Box: mtools against `dos.img`

```bash
# Stop 86Box first — concurrent IDE writes corrupt FAT.
86box-run stop
86box-install-dos --to 'C:\PROJ\BUILD' --src ./build --pattern '*.EXE'
```

The bridge between Linux and DOS for 86Box is `mtools` against the
project's `dos.img` (a flat raw disk image — `qemu-img convert`'d
once from the baked VHD on first run, then never touched by qemu-img).
The first FAT16 partition starts at LBA 62.

## Project bootstrap

For a new DOS project:

```bash
mkdir myproj && cd myproj
mkdir dos-c workspace .claude
cp /path/to/template/{Dockerfile,docker-compose.yml,entrypoint.sh,template_dos-c.vhd} .
cp -r /path/to/template/tools .
docker compose run --rm dos-claude
```

Inside the container, `/dos/c/` is your project's writable DOS C:
drive (used by 86Box; dosemu2 doesn't require it), `/dos/src/` is
wherever you want to mount source from, and `/workspace/` is the
build/agent workspace.

## Serial passthrough

### dosemu2 — raw PTY (no bridge)

`~/.dosemurc` configures `$_com1 = "pts /tmp/dos-com1"`. dosemu2 opens
its own openpty pair on every launch and symlinks the slave to
`/tmp/dos-com1`. Linux processes attach directly:

```bash
dosemu-cmd \
    --daemon "python3 -m linux.serdfsd --serial /tmp/dos-com1 --baud 9600 ..." \
    --mount /your/dos/build \
    "G:" "SERDFS X /COM1 /BAUD:9600" "DIR X:"
```

No host-side throttle (the 86Box-required `BOX86_BRIDGE_TX_DELAY_MS`
isn't a thing here), no termios cooking. dosemu2's UART runs at host
speed.

### 86Box — bridge required

```bash
86box-run start /dos/c          # boot the VM
86box-bridge                    # discover PTY + start shuttle
ls -l /tmp/linux-com1           # → /dev/pts/N (raw, ready to use)
```

86Box opens an internal `openpty()` pair, writes "Slave side is
/dev/pts/N" to its log; `86box-bridge` watches the log, opens the
slave with raw termios, creates an intermediate raw PTY pair under
our control, and symlinks `/tmp/linux-com1` to it. Throttles
host→86Box writes to 1 ms/byte (matches 9600 baud) — without this,
86Box's UART RX register overruns under host bursts.

## Mounts

```
./dos-c       → /dos/c                  → C: inside 86Box (dos.img + 86box.cfg)
                                           also bind-target for `dosemu-cmd --mount`
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

- **dosemu2** is GPLv2; installed from the Ubuntu universe repo.
- **FDPP** is GPLv3; same source.
- **86Box** is GPLv2; built from the official AppImage release.
- **86Box ROMs** repo is permissively licensed where individual ROMs allow;
  see `/opt/86box/roms/LICENSE`.
- **Open Watcom** is under the Sybase Open Watcom Public License.
- **Template VHD**: the file shipped in this repo as `template_dos-c.vhd`
  may contain MS-DOS 6.22, which is **not redistributable**. Replace with
  FreeDOS 1.3 (MIT) before sharing this repo publicly. The dosemu2 path
  uses FDPP and doesn't need this template.

## Architecture notes

- The container is `linux/amd64`. On Apple Silicon hosts, Docker
  Desktop runs it under QEMU user-mode emulation. Inside, dosemu2 and
  86Box both emulate an x86 PC. Two-level emulation is slow; dosemu2
  copes by running everything in pure C-emulated CPU mode
  (`$_cpu_vm = "emulated"`, `$_cpuemu = (1)`), which is ~286-class
  effective speed but works inside qemu-user where JIT/KVM doesn't.
- The Qt VNC platform plugin doesn't render 86Box's emulator viewport
  correctly (only the menu bar paints). Both toolkits use Xvfb +
  x11vnc instead.
- dosemu2's `-dumb` mode renders the DOS screen as text into stdout —
  zero vision tokens for AI agents reading the output. Use it.
- DOSBox-X was the original sandbox runtime but its DOS dispatches
  all file ops directly to its internal `Drives[]` table without
  going through INT 2Fh, which makes it useless for redirector-based
  DOS development. dosemu2 + FDPP and 86Box both do real INT 2Fh
  dispatch and so match actual hardware behavior.
- The current `86box-pcmd` is a COM2-DOS-daemon REPL design (PCMDD.EXE
  on the DOS side, host wrapper on this side). For dosemu2 the
  equivalent is just `dosemu-cmd` itself — it's already so fast per
  call that the persistent-REPL pattern provides no win.
