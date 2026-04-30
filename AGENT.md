# AGENT.md — Orientation for AI agents landing in this container

You are running inside the **DOS Dev Sandbox** — a Docker container designed
for AI-assisted DOS development. This file is your orientation. Read it
fully before doing anything that touches DOS, the emulator, or the build
toolchain.

## TL;DR

- You can build DOS executables on Linux with **Open Watcom** (`wcl`, `wcc`,
  `wlink`, `wasm`) at `/opt/watcom/`.
- You can run real DOS on real BIOS via **86Box** (an x86 PC emulator).
  86Box is **headless** — it has no terminal, only a VNC display on
  port `5901`. The display stack is started for you by `entrypoint.sh`,
  so `vnc://localhost:5901` is reachable from container start.
- You drive DOS in two ways:
  - **Non-interactive (per-command cold-boot, ~30 s/call):**
    `86box-cmd "DIR C:\\"` — runs a DOS command, captures stdout to a
    file via a virtual floppy, returns it. **Zero vision tokens.** Use
    for one-shot probes and for self-contained multi-line BATs that need
    a clean DOS state.
  - **Persistent (sub-second/call after one 30 s boot):**
    `86box-pcmd start; 86box-pcmd run "VER"; …; 86box-pcmd stop` —
    keeps 86Box alive, talks to a DOS-side REPL (PCMDD.EXE) over COM2.
    Best for iterative dev, debugging hung TSRs, anything where you'd
    otherwise burn many ~30 s boots. TSR state persists across runs;
    env vars and CWD don't (each run is a fresh `COMMAND.COM /C`).
  - **Interactive:** `86box-keys` (send keystrokes via VNC) and
    `86box-screen` (decode the 80×25 text-mode framebuffer into ASCII).
    Use this for things the above two can't do (boot menus, hung
    programs, full-screen apps).
- For anything that talks to the DOS COM1 over serial, run `86box-bridge`
  once after boot — it discovers 86Box's host PTY and exposes a stable
  `/tmp/linux-com1` symlink with raw termios + 4 ms/byte throttling.
- To put your build artifacts inside `dos.img` so DOS can run them:
  `86box-install-dos --to 'C:\PROJ\BUILD' --src ./build --pattern '*.EXE'`
  (86Box must be stopped first — see PROJECTS.md).
- The container is `linux/amd64` running on QEMU user-mode emulation when
  the host is Apple Silicon. 86Box itself emulates an x86 PC on top.
  **Two-level emulation is slow** — effective speed ≈ real 286. Fine for
  9600-baud serial, BIOS testing, most DOS apps. Not for Win9x.

## What's where

```
/workspace/                 ← This template's source. Bound from host.
                              You are reading /workspace/AGENT.md.
  Dockerfile                ← Builds this container.
  docker-compose.yml        ← Maps ports 5901 (VNC) + 5556 (free for project use).
  entrypoint.sh             ← Seeds /dos/c/dos.img on first run, patches
                              CONFIG.SYS LASTDRIVE=Z + AUTOEXEC.BAT hook,
                              seeds /workspace/examples/, starts the
                              headless VNC stack.
  template_dos-c.vhd        ← Pristine DOS install (do not modify).
  PROJECTS.md               ← Walkthrough for building a DOS project.
  examples/hello/           ← Reference project: build→install→test loop
                              in ~30 lines of C + a 4/4-PASS test.sh.
  tools/86box/              ← Source for the 86box-* helper tools.
    setup.sh                ← Re-run if 86Box install gets corrupted.
    run.sh                  ← Start/stop 86Box; manage Xvfb + x11vnc.
    cmd                     ← The non-interactive DOS runner.
    pcmd                    ← Postmortem stub for an abandoned design.
    keys                    ← Keystroke injector.
    screen.py               ← VGA text → ASCII decoder.
    gen-config.py           ← Generates per-project 86box.cfg.
    pty-bridge.py           ← Discovers 86Box's serial PTY + raw bridge.
    install-dos.sh          ← mcopy host files into dos.img at a DOS path.

/dos/c/                     ← Per-project writable DOS C: drive.
                              Bound from host (project state survives rebuilds).
  dos.img                   ← Raw FAT16 image (~234 MB virtual, ~6 MB sparse).
  86box.cfg                 ← Per-project 86Box machine config. Read-only
                              during runtime; do not edit while 86Box is up.
  AGENT.IMG                 ← 1.44 MB FAT12 floppy used by 86box-cmd.
                              Recreated each command. Don't bother reading it.

/dos/src/                   ← Optional bind mount for source. Use freely.
                              Many projects bind their repo here.

/opt/watcom/                ← Open Watcom toolchain.
  binl64/wcl                ← `wcl -bt=dos` cross-compiles 16-bit DOS .EXEs.
  binl/                     ← 32-bit binaries if you need them.

/opt/86box/                 ← Extracted 86Box AppImage. Don't run AppRun
                              directly — use `86box-run start <vm-path>`.
  roms/                     ← Machine + video + HDD ROM files.
                              Reference these when picking gen-config flags.

/opt/dos-c-base/            ← Baked DOS template. entrypoint.sh seeds
                              /dos/c/dos.img from template_dos-c.vhd here.

/usr/local/bin/86box-*      ← Helper tools, on PATH. Read each tool's
                              header (sed -n '1,30p') for usage. Source
                              files in /workspace/tools/86box/ keep their
                              .sh/.py extensions for editor support; the
                              extension is dropped on install.
```

## How to do common things

### Run a DOS command and capture output

```bash
# Single command
86box-cmd "DIR C:\\"

# Multiple commands
86box-cmd "VER" "DIR C:\\" "MEM /C"

# Multi-line via stdin
86box-cmd <<'BAT'
ECHO Hello
TYPE C:\AUTOEXEC.BAT
BAT
```

This boots 86Box from scratch each time (~30 s), runs your BAT, captures
`A:\OUT.TXT`, prints it, kills 86Box. The output is plain DOS stdout.

For test scenarios that need a TSR resident across multiple commands
(install + ops + unload), put all commands in **one** `86box-cmd` call —
the BAT runs to completion in a single boot and TSR state survives the
whole BAT.

### Build a DOS .EXE on Linux and run it

```bash
# Linux side
wcl -bt=dos -ms -0 -os -fe=BUILD/HELLO.EXE src/hello.c

# Drop the .EXE into the DOS C: drive (FAT16 partition starts at LBA 62)
OFFSET=$((62 * 512))
mcopy -o -i /dos/c/dos.img@@${OFFSET} BUILD/HELLO.EXE ::

# Run it inside DOS
86box-cmd "C:\\HELLO.EXE"
```

### Drive DOS interactively (text mode)

```bash
86box-run start /dos/c
86box-run wait-vnc            # blocks until VNC banner is reachable
# ... wait for boot to finish ...
86box-keys line "DIR C:\\"    # types text + Enter
86box-screen                  # prints 80×25 ASCII of current screen
86box-run stop
```

### Watch DOS in real time (human observation)

VNC is on host port `5901` (mapped through docker-compose). The display
stack starts with the container, so the VNC port answers immediately —
you'll see a blank Xvfb desktop until 86Box is launched.

```
open vnc://localhost:5901    # macOS
```

No password. Multiple viewers OK (x11vnc is `-shared`).

### COM1 talking to a Linux process

86Box's serial1 is configured for **host PTY passthrough** by default
(the entrypoint generates the cfg with `--serial1-passthrough` set).
Each VM lifetime gets a fresh `/dev/pts/N`; `86box-bridge` finds it and
publishes a stable `/tmp/linux-com1` symlink:

```bash
# After 86Box is up:
86box-bridge                  # idempotent; daemonises, returns when ready
ls -l /tmp/linux-com1         # → /dev/pts/M (intermediate raw PTY)

# Linux side now uses /tmp/linux-com1 directly (no extra layer):
python3 -c "import serial; s = serial.Serial('/tmp/linux-com1', 9600); ..."
# or:
socat - PTY,raw,link=/tmp/linux-com1
```

`86box-bridge` sets raw termios on both PTYs (no IXON, no ICRNL, no
ECHO) and throttles host→86Box writes to 1 ms/byte (matches 9600 baud).
Without the throttle, 86Box's UART RX register overruns under burst
writes from the host.

The Compose `5556` port is left mapped for projects that need to expose
their own TCP service to the host; 86Box itself does **not** use it
(v5.3 b8200 ignores the `serial%_passthrough_mode = tcp_server` flag and
falls back to PTY mode regardless).

## What NOT to do

- **Don't run `dosbox-x`.** It's not in this container, and even when it
  was, it bypasses INT 2Fh redirector dispatch — useless for any real-DOS
  work. We migrated specifically because of this.
- **Don't `qemu-img convert` the dos.img back into VHD format.** It rewrites
  the disk's CHS geometry (1930/4/62 → 965/16/31), and DOS boot fails
  ("Missing operating system") because the boot sector reads via classic
  CHS INT 13h. Keep dos.img as raw.
- **Don't `kill` 86Box gracefully.** SIGTERM lets it write back its cfg
  with normalized geometry → next boot fails. Use `86box-run stop`, which
  does SIGKILL, or `kill -9` directly. The cfg is chmod 0444 while 86Box
  runs as defense in depth.
- **Don't edit `/dos/c/86box.cfg` while 86Box is running.** Stop 86Box,
  edit, restart.
- **Don't open the 86Box settings dialog** (via VNC). Same reason —
  saving from the dialog rewrites the cfg.
- **Don't write screenshots into context unless you need pixels.**
  `86box-cmd` and `86box-screen` give you text without burning vision
  tokens. Reserve raw PNG (`vncdo capture`) for graphics-mode screens
  and BIOS dialogs.
- **Don't expect speed.** Two-level emulation. A simple `DIR` cycle is
  ~30s end-to-end (BIOS POST + DOS boot + run + capture). Plan around it.
- **Don't reinvent the persistent-DOS runner over the AGENT.IMG floppy.**
  That was attempted as `86box-pcmd` v1 and didn't work (DOS BUFFERS
  caches the floppy FAT/dir; host-side mtools writes are invisible to
  DOS). The current `86box-pcmd` is the COM2-DOS-daemon design that
  postmortem proposed — uses PCMDD.EXE on the DOS side and a serial
  channel, all DOS-side writes are coherent. Use it for sub-second
  iteration, with the caveat that env vars + CWD don't persist across
  `pcmd run` calls (TSRs do — they hook the global IVT).

## Diagnostic checklist when something goes wrong

1. `86box-run status` — is Xvfb / x11vnc / 86Box up?
2. `tail /tmp/86box/86box.log` — Qt and emulator stderr.
3. `86box-screen --debug` or capture a PNG via
   `vncdo capture /tmp/peek.png` and Read it — what does the
   emulator actually show right now?
4. `qemu-img info /dos/c/dos.img` — is the disk image still raw and the
   right size?
5. `mdir -i /dos/c/dos.img@@$((62*512)) ::` — can you list the FAT16
   partition? If not, the image is corrupt — `rm /dos/c/dos.img` and
   re-run `entrypoint.sh` to reseed from template (LASTDRIVE=Z and the
   AUTOEXEC hook are reapplied automatically).
6. `mdir -i /dos/c/AGENT.IMG ::` — is `OUT.TXT` present? If yes,
   `mtype -i /dos/c/AGENT.IMG ::OUT.TXT` to read it directly.
7. `86box-bridge status` + `cat /tmp/86box/bridge.log` — for serial
   issues, check the PTY discovery + shuttle is up. `86box-bridge
   foreground --trace` runs in your terminal and hex-dumps every byte
   in both directions.

## Building your own DOS project

For the practical loop (build → install → test, serial bridge usage,
DOS-specific pitfalls, working test patterns), see [`PROJECTS.md`](PROJECTS.md).
That file is where the SerialDFS-discovered learnings live.

A working minimal reference lives at [`examples/hello/`](examples/hello/) —
~30-line `hello.c`, a one-target makefile, and a `test.sh` that
exercises build → install → run-and-assert end-to-end. Run with
`bash /workspace/examples/hello/test.sh` (~40 s, 4/4 PASS). Copy it as
the starting point for a new project.

## When you're done with a task

If you discover something non-obvious about this environment (a new
gotcha, a workaround that wasn't documented, a configuration tweak that
made things faster), update **this file** so the next agent doesn't have
to relearn it. Then update `tools/86box/README.md` if the change touches
the toolkit itself, or `PROJECTS.md` if it's a project-development
learning that should help future DOS projects.

## Provenance + further reading

- The migration from DOSBox-X to 86Box happened on 2026-04-26.
- Companion docs: [`PROJECTS.md`](PROJECTS.md) (DOS project walkthrough),
  [`tools/86box/README.md`](tools/86box/README.md) (toolkit details),
  [`README.md`](README.md) (top-level project overview),
  per-project `~/.claude/projects/.../memory/` (long-term memory across
  container restarts).
- Reference DOS project to crib from: `/dos/c/serdfs/` (SerialDFS — a
  serial-driven INT 2Fh redirector with ~13 KB resident TSR; uses every
  toolkit feature).
- 86Box: <https://86box.net> · ROMs: <https://github.com/86Box/roms>
- Open Watcom: <https://github.com/open-watcom/open-watcom-v2>
