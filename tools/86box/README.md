# `tools/86box/` — the 86Box helper toolkit (alternative emulator)

> ⚠️  **dosemu2 is the primary emulator** in this sandbox. See
> [`tools/dosemu/README.md`](../dosemu/README.md) for the preferred
> path. Use 86Box when you specifically need real BIOS, real IDE
> controller behavior, or to verify that something works on actual-
> hardware-class emulation. For iterative dev — TSRs, redirectors,
> CI-style tests — start with `dosemu-cmd` not `86box-cmd`. It boots
> in 2-3 s instead of 30 s and mounts host directories directly.

These scripts wrap 86Box for headless, agent-driven, reproducible use
inside the DOS Dev Sandbox container. Read [`/workspace/AGENT.md`](../../AGENT.md)
first for the big picture; this file documents each script in detail.

All scripts are installed to `/usr/local/bin/86box-*` by the Dockerfile.
Source filenames keep their natural extension (`.sh`, `.py`); the
on-PATH name drops the extension and is what scripts call each other by.
That means edits to `/workspace/tools/86box/cmd` take effect for any
caller that uses `86box-cmd`. Either edit here and `docker compose
build` to refresh the image, or symlink `/usr/local/bin/86box-cmd
→ /workspace/tools/86box/cmd` for live-edit during development.

---

## `setup.sh` → `86box-setup`

Idempotent installer. The Dockerfile runs it once at build time. Re-run
manually only if `/opt/86box/` got corrupted.

```bash
sudo 86box-setup
```

Steps it performs:

1. Downloads the 86Box AppImage (default v5.3 b8200) to
   `/opt/86box-app/86Box.AppImage`. Skips if already present.
2. Patches the AppImage's "AI 02" magic bytes at offset 8–10 to zeros.
   Without this, the kernel/QEMU-user can't `exec` the AppImage because
   the magic confuses the ELF parser. We can't use FUSE mode because
   `/dev/fuse` isn't available in Docker.
3. Runs `--appimage-extract` to expand the squashfs payload into
   `/opt/86box/`.
4. Downloads the official ROM repo
   (<https://github.com/86Box/roms/archive/refs/heads/master.zip>, ~70 MB)
   and unpacks it into `/opt/86box/roms/`.
5. Verifies the result by checking `usr/local/bin/86Box` and
   `roms/machines/ninja/`.

Override defaults via env: `BOX86_VERSION`, `BOX86_BUILD`,
`BOX86_INSTALL_DIR`, `BOX86_ROMS_DIR`, `BOX86_APPIMAGE_URL`,
`BOX86_ROMS_URL`.

---

## `gen-config.py` → `86box-gen-config`

Generates an `86box.cfg` for a project's VM directory.

```bash
86box-gen-config --out /dos/c/86box.cfg --vhd dos.img
86box-gen-config --out /dos/c/86box.cfg --vhd dos.img --serial1-passthrough
86box-gen-config --out /dos/c/86box.cfg --machine ami286 --cpu 286 --mhz 12 --mem-mb 4
86box-gen-config --out /dos/c/86box.cfg --set "Sound:sndcard=sb16"
```

The defaults emulate the same machine the bundled MS-DOS 6.22 template
VHD was created on: **`ninja`** (i486DX2/66, 8 MB RAM, S3 Stealth64v PCI,
internal floppy controller, IDE PCI HDD controller). Changing the disk
geometry away from `62, 4, 1930, 0, ide` will break boot — DOS was
installed against that CHS layout.

The `[Floppy and CD-ROM drives]` section sets `fdd_01_type = 35_2hd` but
no image. `86box-cmd` injects `fdd_01_fn = AGENT.IMG` per command.

`--serial1-passthrough` enables 86Box's **host PTY passthrough** on COM1
(`serial1_passthrough_enabled = 1`). 86Box opens its own openpty() pair
and writes "Slave side is /dev/pts/N" to its log; `86box-bridge` watches
the log, opens that slave with raw termios, and re-publishes it as a
stable `/tmp/linux-com1` symlink. There's a legacy `--serial1-tcp PORT`
flag that records `serial1_passthrough_mode = tcp_server` in cfg, but
86Box v5.3 b8200 ignores it and falls back to PTY mode anyway. Use
`--serial1-passthrough` and `86box-bridge`.

---

## `run.sh` → `86box-run`

Manages the headless display stack and the 86Box process.

```bash
86box-run display-up         # bring up Xvfb + x11vnc only (no 86Box)
86box-run start /dos/c       # ensure display, then start 86Box
86box-run wait-vnc           # block until VNC port answers
86box-run stop               # SIGKILL 86Box (display stack stays up)
86box-run kill-all           # also stop x11vnc and Xvfb
86box-run status             # what's up
```

The container's `entrypoint.sh` calls `86box-run display-up` so port
5901 is reachable from the moment the container starts, even before any
86Box session boots — the VNC client just sees a blank Xvfb desktop.

What `start` does:

1. Spawns Xvfb on `:99` (resolution 1024x768x24) if not running.
2. Spawns x11vnc serving `:99` on port 5901 (`-nopw -listen 0.0.0.0
   -forever -shared -noxdamage -quiet`) if not running.
3. `chmod 0444 <vm-path>/86box.cfg` — defense in depth against 86Box
   rewriting the cfg with normalized CHS on shutdown.
4. Launches 86Box via `./AppRun -P <vm-path> -C 86box.cfg -R /opt/86box/roms
   --noconfirm` with `DISPLAY=:99 QT_QPA_PLATFORM=xcb`. PID is recorded in
   `/tmp/86box/86box.pid`.
5. Background-fires ESC keypresses every 2 seconds for the first 10 seconds
   so the AMIBIOS "CMOS Checksum Invalid / Press F1 ... ESC to Boot"
   prompt is dismissed automatically on first run. Once the NVR file is
   established, the prompt stops appearing and these keypresses are no-ops.

What `stop` does:

- **SIGKILL only.** SIGTERM lets 86Box gracefully save its cfg, which
  rewrites the hard-disk CHS to a different (functionally-equivalent but
  not-byte-equivalent) layout, breaking DOS boot.
- Also `pkill -9 -f "86Box.*86box.cfg"` to catch any zombies.
- Does not stop Xvfb / x11vnc — those are cheap and leaving them up
  speeds up the next `start`.

Env: `BOX86_HOME`, `BOX86_ROMS`, `BOX86_DISPLAY`, `BOX86_RES`,
`BOX86_VNC_PORT`, `BOX86_LOG_DIR`.

---

## `cmd` → `86box-cmd`

Non-interactive DOS command runner. The workhorse. Boots 86Box from
scratch each call (~30 s) so DOS state never leaks between invocations.

```bash
86box-cmd "DIR C:\\"
86box-cmd "VER" "DIR C:\\" "MEM /C"
echo -e "VER\nDIR\n" | 86box-cmd
86box-cmd --vm /dos/c "DIR"
86box-cmd --timeout 180 "..."   # default timeout 60s
```

For tests that need TSR state to persist across multiple commands
(e.g. `SERDFS install + DIR + /U`), pipe a multi-line BAT into a SINGLE
`86box-cmd` call — TSR state survives the whole BAT, and you only pay
the boot cost once.

Pipeline:

1. Build a `RUN.BAT` from the input. Each non-redirected command line is
   suffixed with ` >> A:\OUT.TXT` so DOS captures stdout. The BAT writes
   `__86BOX_AGENT_DONE__` and `A:\DONE` as completion markers.
2. Format a fresh 1.44 MB FAT12 floppy image at `<vm-path>/AGENT.IMG`
   using `mformat`, copy `RUN.BAT` onto it.
3. `chmod u+w` the project's `86box.cfg` (86box-run marked it 0444), patch
   the `[Floppy and CD-ROM drives]` section to attach `AGENT.IMG`.
4. `86box-run stop && 86box-run start <vm-path> && 86box-run wait-vnc`.
5. Poll for `A:\DONE` to appear in `AGENT.IMG` via mtools' `mdir`.
   Default timeout is 60 seconds (override with `BOX86_TIMEOUT` or `--timeout`).
6. `mtype` `A:\OUT.TXT` to stdout. Stop 86Box.

The DOS side is glued together by the AUTOEXEC.BAT hook installed once
by `entrypoint.sh` when seeding `/dos/c/dos.img`:

```bat
REM 86box-cmd hook
IF EXIST A:\RUN.BAT CALL A:\RUN.BAT
```

If you re-create `dos.img` from a different template, you need to
re-install this hook (the entrypoint does it for you on a fresh image).

Env: `BOX86_VM_PATH` (default `/dos/c`), `BOX86_TIMEOUT` (default 60).

---

## `pcmd` → `86box-pcmd`

Persistent DOS REPL over COM2. Boots 86Box once (~30 s cold start), runs
`PCMDD.EXE` on the DOS side as a foreground program that reads
length-prefixed commands from COM2 and writes back length+errorlevel+
stdout. Subsequent `run` calls are sub-second (no boot cost) and DOS-
side TSR / driver state survives across calls.

```bash
86box-pcmd start          # boot + bring up COM2 bridge + verify ready (~40 s)
86box-pcmd run "VER"      # ~0.7 s — DOS prints MS-DOS Version 6.22
86box-pcmd run "DIR C:\\" # ~3 s — DIR through the persistent session
86box-pcmd run "MEM /C"   # works fine through pcmd; see D7 in SerialDFS
                          # tracker for an interesting hang it does NOT trigger
86box-pcmd stop           # tear down 86Box + bridge + AUTOEXEC hook
86box-pcmd status         # show readiness
```

Wire protocol on `/tmp/linux-com2`:

    Request   host -> DOS:  uint16 cmd_len, byte cmd[cmd_len]
    Response  DOS  -> host: uint16 out_len, uint8 errorlevel, byte out[out_len]

How `start` works:
1. Ensures 86box.cfg has both `serial1_passthrough_enabled` and
   `serial2_passthrough_enabled` (re-runs `86box-gen-config` if not).
2. Ensures `AGENT.IMG` exists and is attached as fdd_01 (otherwise
   AUTOEXEC's `IF EXIST A:\RUN.BAT` hangs on "Not ready reading drive A").
3. Installs `PCMDD.EXE` into `C:\` of dos.img (via `86box-install-dos`).
4. Patches `AUTOEXEC.BAT` with the v2 hook
   `IF EXIST C:\PCMDD.EXE C:\PCMDD.EXE` (sentinel-guarded so it can be
   removed by `stop`). Strips any legacy v1 hook line from the abandoned
   floppy-poll attempt.
5. Boots 86Box; AUTOEXEC chain runs and ends with PCMDD.EXE looping on
   COM2.
6. Brings up `86box-bridge --port 2 --link /tmp/linux-com2`.
7. Probes with a noop and waits up to 120 s for a clean response.

Source: `/workspace/tools/86box/pcmd` (host-side Python wrapper) +
`/workspace/tools/86box/dos/pcmdd.c` + `seruart.c` (built into
`/opt/dos-c-base/pcmdd/PCMDD.EXE` at image build time).

**Caveats** (vs `86box-cmd`):
- Each `run` spawns a fresh `COMMAND.COM /C` child. Environment vars
  set by `SET FOO=bar` do NOT persist across runs (each child has its
  own env). Current directory does NOT persist. TSR state DOES persist
  (TSRs hook interrupts in the global IVT, which is process-independent).
- For SerialDFS-style INT 2Fh redirector testing, `86box-cmd` with a
  multi-line BAT is still the recommended path. pcmd will install the
  TSR and `/STATS` will respond, but DIR-on-the-redirected-drive
  through pcmd's per-command context has shown empty results in
  testing — see SerialDFS TODO_TRACKER D8.
- The previous, abandoned `86box-pcmd` (floppy-poll over AGENT.IMG)
  remains documented in `feedback_no_floppy_poll.md` so the next agent
  doesn't re-try it. This implementation is the COM2-daemon design that
  doc proposed as the right fix.

---

## `pty-bridge.py` → `86box-bridge`

86Box's serial passthrough opens an internal `openpty()` pair and writes
`serial_passthrough: Slave side is /dev/pts/N` to its log. The slave
number changes per VM lifetime, and the slave's default termios still
has line-discipline cooking enabled (IXON eats `0x11`/`0x13`, ICRNL
mangles `0x0D`, etc.) — fatal for any binary protocol.

`86box-bridge` watches the log for the slave path, opens it with raw
termios, creates an intermediate raw PTY pair under our control,
symlinks `/tmp/linux-com1` → the new slave, and shuttles raw bytes both
directions. Host→86Box writes are throttled to ~1 ms/byte (line rate at
9600 baud); without this, 86Box's UART RX register overflows under
burst writes from the host.

```bash
86box-bridge                          # start in background, COM1; idempotent
86box-bridge --port 2 --link /tmp/linux-com2 \
             --pidfile /tmp/86box/com2.pid start    # COM2 instead
86box-bridge stop                     # kill the running bridge
86box-bridge status
86box-bridge foreground --trace       # run in this terminal, hex-dump every chunk
```

`--port N` picks which serial passthrough to bridge: 1 = COM1 (the
default, used by SerialDFS et al), 2 = COM2 (used by `86box-pcmd` for
the persistent-DOS REPL channel — they coexist). The Nth match of
`serial_passthrough: Slave side is /dev/pts/N` in 86Box's log is the
slave for serialN.

State: `/tmp/86box/bridge.pid` (PID) and `/tmp/86box/bridge.log` (stdout).

Env (all overridable per-invocation via flags):
- `BOX86_LOG` — 86Box log to scrape for the slave path. Default `/tmp/86box/86box.log`.
- `BOX86_BRIDGE_LINK` — symlink path to publish. Default `/tmp/linux-com1`.
- `BOX86_BRIDGE_TX_DELAY_MS` — host→86Box per-byte sleep. Default 4 ms.
- `BOX86_BRIDGE_CONNECT_TIMEOUT` — seconds to wait for the slave path. Default 90.

Pre-req: 86Box must be configured with `serial1_passthrough_enabled = 1`
(set by `86box-gen-config --serial1-passthrough`, which is the default
in the entrypoint-generated cfg).

### Why the 4 ms/byte default

86Box's emulated 8250/16550 UART under QEMU-user on Apple Silicon drops
bytes on sustained host→guest bursts faster than ~4 ms/byte (≈2400 baud
effective), even though the guest's UART is configured for 9600 baud
(theoretical 1.04 ms/byte). The drop appears to be timing-jitter-related
in the emulation layer, not a FIFO overrun — even bytes well-spaced from
each other are occasionally lost on sustained traffic.

For short interactions (a single PING, a single LIST_DIR) the rate
doesn't matter; bytes get through clean. For sustained transfers (e.g.
multi-chunk file reads), the cumulative drop probability adds up: at
~5% per chunk × 128 chunks = 99% chance at least one drop. The 4 ms
default was empirically the smallest value that kept SerialDFS's 8 KB
COPY tests reliable across many runs.

If you're writing a new project that hits the same wall:
- Bump `BOX86_BRIDGE_TX_DELAY_MS` to 6-8 ms to stay reliable on larger
  transfers.
- Make your protocol's RPC layer **idempotent**: client retries on
  timeout must produce the same response, not advance any cursor on the
  server side. (SerialDFS learned this the hard way — see TODO_TRACKER
  D6 in that project for the symptom.)
- Bump retry counts (`SERRPC_RETRIES`-equivalent) into the 5-10 range,
  not 3.
- Real-hardware 16550 UARTs do NOT have this drop pattern; this is
  purely a sandbox-emulation limitation.

---

## `install-dos.sh` → `86box-install-dos`

Generic helper that mcopies host files into `dos.img` at a chosen DOS
path. Replaces the per-project `mcopy -i dos.img@@$((62*512))` boilerplate
that every test harness used to ship.

```bash
86box-install-dos --to 'C:\PROJ\BUILD' build/MYPROG.EXE build/MYPROG.DAT
86box-install-dos --to 'C:\TOOLS' --src ./build --pattern '*.EXE'
86box-install-dos --to 'C:\PROJ' --src ./bin   # all of ./bin
```

Creates the destination directory chain (`MMD`) idempotently and uses
`MCOPY -o` to overwrite.

**Refuses to run while 86Box is up** — concurrent mtools writes vs. the
emulated IDE controller cause FAT cache divergence between DOS BUFFERS
and the on-disk state, leading to silent file corruption. Stop 86Box
(`86box-run stop`), install, restart.

Env: `BOX86_VM_PATH` (`/dos/c`) — used to locate `dos.img`. Override
with `--img PATH`.

---

## `keys` → `86box-keys`

Keystroke injection via `vncdotool`. Use for interactive control.

```bash
86box-keys type "DIR"            # types literal characters, no Enter
86box-keys press enter           # one named key (esc, f1, up, ctrl-c, ...)
86box-keys line "TYPE C:\\AUTOEXEC.BAT"   # type text + Enter
86box-keys raw -- type "DIR" key enter    # pass remaining args verbatim
```

`vncdotool` is installed system-wide at `/usr/local/bin/vncdo` by the
Dockerfile (via pip with `--break-system-packages`). The script also
falls back to `~/.local/bin/vncdo` if a project chose to install it
user-local. Env: `BOX86_VNC_HOST` (default 127.0.0.1), `BOX86_VNC_PORT`
(default 5901).

---

## `screen.py` → `86box-screen`

Captures the VNC framebuffer and decodes the 80×25 VGA text-mode region
into ASCII. Cheap (no model vision tokens; ~500 input tokens of plain
text per snapshot).

```bash
86box-screen                      # print to stdout
86box-screen --out screen.txt     # write to file
86box-screen --png /tmp/keep.png  # also keep the raw PNG
86box-screen --debug              # verbose region detection
```

How it works:

1. `vncdo capture` → PNG of Xvfb's full desktop.
2. Scan candidate VGA cell sizes (8×16, 9×16, 8×14, 9×14) for an 80×25
   character grid located just below the 86Box menu+toolbar (which
   consume ~70 pixels at the top of the Qt window).
3. For each cell, sample its pixels into a small 8×8 binary fingerprint
   (luminance threshold + pack to 64 bits).
4. Look up each fingerprint against the table generated by `build-fontmap.py`.
   Unknown fingerprints become `?`.

Exits **2** when no text region is detected (graphics mode, BIOS splash,
unusual font). The raw PNG path is printed to stderr in that case so the
caller can fall back to image-to-model.

If the decoder gets too many `?` characters in normal use, regenerate
the fontmap from the actual running emulator: see `build-fontmap.py`.

---

## `build-fontmap.py` → `86box-build-fontmap`

Generates the `FINGERPRINTS = {fp: char, ...}` table used by
`screen.py`. Currently builds from a Linux-side TTF font (DejaVu Sans
Mono fallback). For perfect fidelity to 86Box's actual VGA 8×16 BIOS
font you'd want to fingerprint glyphs out of a calibration screenshot
of the real emulator — that's a TODO; the current map gets ASCII right
~95%.

```bash
86box-build-fontmap --out tools/86box/fontmap.py --cell 8x16
```

---

## Common gotchas

| Symptom | Cause | Fix |
|---|---|---|
| "Missing operating system" on every boot | dos.img CHS doesn't match cfg | Reseed: `rm /dos/c/dos.img` and re-run entrypoint, or `qemu-img convert -O raw template_dos-c.vhd dos.img` and reinstall the AUTOEXEC + LASTDRIVE patches. |
| "Unable to activate the local drive mapping" when installing a redirector TSR (e.g. SerialDFS) | LASTDRIVE in CONFIG.SYS too low | Entrypoint patches `LASTDRIVE=Z` automatically; if you replaced CONFIG.SYS by hand, re-run entrypoint or add the line yourself. |
| 86Box shows menu bar but emulator viewport is black | Qt VNC platform plugin doesn't render child widgets | Already handled. We use Xvfb + x11vnc instead of `QT_QPA_PLATFORM=vnc`. If you've reverted, revert back. |
| `86box-cmd` times out | (1) BIOS waiting for ESC, (2) AUTOEXEC hook missing, (3) floppy controller not configured (`fdc=internal` missing from cfg) | (1) `86box-run start` auto-presses ESC; check it's not been removed. (2) Check `mtype -i /dos/c/dos.img@@$((62*512)) ::AUTOEXEC.BAT` for the `REM 86box-cmd hook` line. (3) Check `/dos/c/86box.cfg` `[Storage controllers]` has `fdc = internal`. |
| `vnc://localhost:5901` won't connect | Container not started, or display stack not up | Entrypoint runs `86box-run display-up` automatically. Verify with `86box-run status`. The Compose port mapping is explicit `0.0.0.0:5901:5901` — confirm with `docker compose ps`. |
| Serial frame bytes corrupted under host→DOS direction | UART RX overrun (host pushes faster than emulated baud), or termios cooking on the slave PTY | Use `86box-bridge` — it sets raw termios on both PTYs and throttles host→86Box writes to 1 ms/byte. Direct opens of `/dev/pts/N` don't have either of those. |
| Output garbled / partial | Multiple positional args got joined | `86box-cmd` quotes each arg as a separate command. Confirm you're passing them as `86box-cmd "VER" "DIR"` not `86box-cmd "VER DIR"`. |
| 86Box rewrites my cfg | SIGTERM was used or settings dialog was opened | Use `86box-run stop` (SIGKILL). Don't open Settings via VNC. cfg is chmod'd 0444 to make this loud. |
| `vncdo` command not found | Tool not on PATH | Installed system-wide at `/usr/local/bin/vncdo` by the Dockerfile. Confirm with `which vncdo`; if missing, the Dockerfile pip install layer didn't run. |
| File copies into `dos.img` work but DOS sees garbage / FAT errors | mtools wrote concurrent with 86Box's IDE controller | `86box-install-dos` already refuses to run while 86Box is up. If you bypass it: stop 86Box first. |
| `MEM /C` after a redirector TSR install hangs the BAT | MEM enumerates UMB/XMS, which on 86Box+QEMU appears to interact badly with the just-installed CDS entry | Run MEM /C in a separate `86box-cmd` cold boot (install + MEM /C + /U all in that one BAT, nothing else). It works there. SerialDFS recorded its resident size that way. |

## Tests

The toolkit has a smoke-test directory at `/workspace/tools/86box/tests/`.
Anything that lands in production and isn't trivially observable should
have a test here.

| Test | What it covers |
|---|---|
| `tests/test-pcmd.sh` | Full `86box-pcmd` lifecycle: start, status, three runs (VER, ECHO, DIR), stop, AUTOEXEC hook cleanup. ~70 s total. |

Run a single test with `bash /workspace/tools/86box/tests/<name>.sh`,
or run them all with `for t in /workspace/tools/86box/tests/*.sh; do
bash "$t" || break; done`. Add new tests as new tools land.

For a single end-to-end build→install→run example (separate from
toolkit-internal tests), see [`examples/hello/`](../../examples/hello/).

---

## Versioning

- 86Box: pinned in `Dockerfile` ARGs (`BOX86_VERSION`, `BOX86_BUILD`).
- 86Box ROMs: HEAD of the `master` branch on each container build (not
  pinned to a specific commit yet — could be a future improvement).
- vncdotool: pinned to `1.3.0` in the Dockerfile pip install.
- Open Watcom: HEAD of "Current-build" — a moving target, but the API
  is stable.
