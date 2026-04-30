# AGENT.md — Orientation for AI agents landing in this container

You are running inside the **DOS Dev Sandbox** — a Docker container
designed for AI-assisted DOS development with two emulators available
(**dosemu2** as primary, **86Box** as alternative). This file is your
orientation. Read it fully before doing anything that touches DOS, an
emulator, or the build toolchain.

## TL;DR

- You can build DOS executables on Linux with **Open Watcom** (`wcl`,
  `wcc`, `wlink`, `wasm`) at `/opt/watcom/`.
- You can run real-DOS-semantics in two ways:
  - **dosemu2 + FDPP (PRIMARY).** Fast (~2-3 s boot), hostfs-mountable
    (no `mcopy` step), raw PTY COM ports (no bridge). Use this by
    default.
  - **86Box (ALTERNATIVE).** Real BIOS, real IDE, full PC emulation.
    Slow (~30 s boot). Use only when you need that fidelity (BIOS
    quirks, real-hardware IDE timing, behaviors verified to differ).
- Both emulators are headless — they have no terminal, only a VNC
  display on port `5901`. The display stack is started for you by
  `entrypoint.sh`, so `vnc://localhost:5901` is reachable from
  container start.
- You drive DOS in three ways:
  - **Non-interactive cleanroom (PRIMARY, ~5 s/call):**
    `dosemu-cmd "DIR C:"` — refreshes dosemu env each call, runs DOS
    commands, captures the screen as text. **Zero vision tokens.** Use
    this by default.
  - **Non-interactive cold-boot (86Box alternative, ~30 s/call):**
    `86box-cmd "DIR C:\\"` — same idea, slower, real BIOS.
  - **Interactive (live human/agent debugging):**
    `dosemu-vnc-start [DIR]` — fluxbox + xterm + dosemu inside VNC :99.
    Connect with any VNC client to localhost:5901, type at the DOS
    prompt, watch the screen update. AI agents normally don't need
    this — `dosemu-cmd` and the captured stdout are enough.
- For DOS programs that talk to a Linux process over COM1:
  - **dosemu2:** `~/.dosemurc` already sets `$_com1 = "pts
    /tmp/dos-com1"`. Just open `/tmp/dos-com1` in your daemon. No
    bridge.
  - **86Box:** run `86box-bridge` once after boot — it discovers
    86Box's host PTY and exposes a stable `/tmp/linux-com1` symlink
    with raw termios + 4 ms/byte throttling.
- To put your build artifacts where DOS can run them:
  - **dosemu2:** `dosemu-cmd --mount /path/to/build "G:" "G:\\PROG.EXE"`
    — host directory becomes a DOS drive instantly.
  - **86Box:** `86box-install-dos --to 'C:\PROJ\BUILD' --src ./build`
    (86Box must be stopped first).
- The container is `linux/amd64` running on QEMU user-mode emulation
  when the host is Apple Silicon. Both emulators handle this; effective
  speed is ~286-class. Fine for 9600-baud serial, BIOS testing, most
  DOS apps. Not for Win9x.

## Decision: which emulator?

| Use case | Pick |
|---|---|
| Default for everything | **dosemu2** |
| Iterative dev, redirector / TSR projects, fast feedback loop | **dosemu2** |
| Sub-second boot for CI-style tests | **dosemu2** |
| Hostfs mount of source tree (no rebuild-into-image step) | **dosemu2** |
| Live debugging in dosdebug | **dosemu2** (`-D+B` flag, `/usr/bin/dosdebug`) |
| Real BIOS / real IDE controller behavior | **86Box** |
| Verifying behavior matches actual hardware | **86Box** |
| BIOS-level diagnostics (POST, CMOS, real RTC) | **86Box** |
| Reproducing a 86Box-specific bug ("works on dosemu doesn't on 86Box") | **86Box** |

**When in doubt, start with dosemu2.** Migrate to 86Box for a specific
test only when you've identified a real reason.

## What's where

```
/workspace/                 ← This template's source. Bound from host.
                              You are reading /workspace/AGENT.md.
  Dockerfile                ← Builds this container (both emulators).
  docker-compose.yml        ← Maps ports 5901 (VNC) + 5556 (free for project use).
  entrypoint.sh             ← Seeds /dos/c/dos.img + dosemu configs on
                              first run, starts the headless VNC stack.
  template_dos-c.vhd        ← Pristine DOS install for 86Box (do not modify).
  PROJECTS.md               ← Walkthrough for building a DOS project.
  examples/hello/           ← Reference project: build→install→test loop.
  tools/dosemu/             ← PRIMARY: dosemu2 helper toolkit.
    setup.sh                ← Re-run if dosemu2 install gets corrupted.
    run.sh                  ← Start/stop dosemu sessions; manage display.
    cmd                     ← Cleanroom non-interactive runner.
    vnc-start.sh            ← Fluxbox + xterm live-debug session.
    vnc-stop.sh             ← Tear down live session.
    dosemurc.template       ← Default ~/.dosemurc (dumb video, PTY COM1).
    dosemu-vnc.rc.template  ← Variant for VNC mode.
    README.md               ← Tool reference + dev quirks.
  tools/86box/              ← ALTERNATIVE: 86Box helper toolkit.
    setup.sh                ← Re-run if 86Box install gets corrupted.
    run.sh                  ← Start/stop 86Box; manage Xvfb + x11vnc.
    cmd                     ← The non-interactive cold-boot DOS runner.
    pcmd                    ← Persistent COM2 DOS REPL.
    keys                    ← Keystroke injector.
    screen.py               ← VGA text → ASCII decoder.
    gen-config.py           ← Generates per-project 86box.cfg.
    pty-bridge.py           ← Discovers 86Box's serial PTY + raw bridge.
    install-dos.sh          ← mcopy host files into dos.img.

/dos/c/                     ← Per-project writable DOS C: drive (86Box)
                              + a convenient mount target for dosemu2.
  dos.img                   ← 86Box's raw FAT16 image (~234 MB virtual,
                              ~6 MB sparse).
  86box.cfg                 ← Per-project 86Box machine config.
  AGENT.IMG                 ← 1.44 MB FAT12 floppy used by 86box-cmd.

/dos/src/                   ← Optional bind mount for source.

/home/coder/
  .dosemurc                 ← dosemu2 default config (dumb video, PTY COM1)
  .dosemu-vnc.rc            ← dosemu2 VNC-mode config
  .dosemu/drive_c/          ← FDPP's bundled DOS drive (don't put project
                              files here — use `dosemu-cmd --mount` instead)

/opt/watcom/                ← Open Watcom toolchain.
  binl64/wcl                ← `wcl -bt=dos` cross-compiles 16-bit DOS .EXEs.

/opt/86box/                 ← Extracted 86Box AppImage.
  roms/                     ← Machine + video + HDD ROM files.

/opt/dos-c-base/            ← Baked DOS template (86Box).

/opt/dosemu/                ← Baked dosemu2 config templates (used by
                              entrypoint.sh to seed $HOME on first run).

/usr/local/bin/dosemu-*     ← dosemu2 helpers, on PATH.
/usr/local/bin/86box-*      ← 86Box helpers, on PATH.
```

## How to do common things

### Run a DOS command and capture output (preferred path)

```bash
# Single command (~5 s)
dosemu-cmd "DIR C:"

# Multi-command session (one boot, ~5+3·N seconds)
dosemu-cmd "VER" "DIR C:" "MEM"

# Multi-line via stdin? Pass commands as separate args — dosemu-cmd
# treats each arg as one DOS command line.
dosemu-cmd "ECHO Hello" "TYPE C:\\AUTOEXEC.BAT"
```

Each call refreshes the dosemu environment from scratch — see "Cleanroom
testing" below for why this matters.

### Build a DOS .EXE and run it (dosemu2, no install step)

```bash
# Linux side: build into /tmp/build/
mkdir -p /tmp/build
wcl -bt=dos -ms -0 -os -fe=/tmp/build/HELLO.EXE src/hello.c

# Mount /tmp/build/ as G: and run it — the freshly-built EXE is
# already there, no `mcopy` step required.
dosemu-cmd --mount /tmp/build "G:" "G:\\HELLO.EXE alpha beta"
```

### Build a DOS .EXE and run it (86Box, install required)

```bash
# Linux side
wcl -bt=dos -ms -0 -os -fe=BUILD/HELLO.EXE src/hello.c

# Stop 86Box first — concurrent IDE writes corrupt FAT.
86box-run stop

# Drop the .EXE into the DOS C: drive
86box-install-dos --to 'C:\HELLO' build/HELLO.EXE

# Run it inside DOS
86box-cmd "C:\\HELLO\\HELLO.EXE"
```

### Drive DOS interactively / watch in real time (live debugging)

#### dosemu2 path (preferred for live)

```bash
dosemu-vnc-start /dos/c/serdfs/dos/build   # fluxbox + xterm + dosemu
# from your host machine:
open vnc://localhost:5901    # macOS — or any VNC client
# you'll see fluxbox with one xterm window titled "DOSEMU2";
# type at the DOS prompt, watch the screen update.
dosemu-vnc-stop              # tear down when done
```

If you also want a Linux-side daemon running alongside (e.g. SerialDFS):

```bash
dosemu-vnc-start \
    --daemon "python3 -m linux.serdfsd --serial /tmp/dos-com1 --baud 9600 \
              --root /workspace/DOS --log-level DEBUG \
              > /tmp/serdfsd.log 2>&1" \
    /dos/c/serdfs/dos/build
```

#### 86Box path

```bash
86box-run start /dos/c
86box-run wait-vnc            # blocks until VNC banner is reachable
86box-keys line "DIR C:\\"    # types text + Enter
86box-screen                  # prints 80×25 ASCII of current screen
86box-run stop
```

Or just `open vnc://localhost:5901` and type by hand.

### COM1 talking to a Linux process

#### dosemu2 — direct PTY, no bridge

`~/.dosemurc` already configures `$_com1 = "pts /tmp/dos-com1"`. On
each `dosemu` launch, dosemu opens its own openpty pair and symlinks
the slave to `/tmp/dos-com1`. Just open it from Linux:

```bash
# In a real test, use dosemu-cmd's --daemon flag — it handles the
# wait-for-PTY-symlink + spawn + reap dance for you.
dosemu-cmd \
    --daemon "your-daemon /tmp/dos-com1" \
    --mount /your/proj \
    "G:" "PROG.EXE"
```

dosemu's UART runs at host speed; no per-byte throttle, no termios
cooking. Same protocol design rule applies as everywhere else: build
your retries idempotent.

#### 86Box — bridge required

86Box's serial1 is configured for **host PTY passthrough** by default
(the entrypoint generates the cfg with `--serial1-passthrough`). Each
VM lifetime gets a fresh `/dev/pts/N`; `86box-bridge` finds it and
publishes a stable `/tmp/linux-com1` symlink:

```bash
# After 86Box is up:
86box-bridge                  # idempotent; daemonises, returns when ready
ls -l /tmp/linux-com1         # → /dev/pts/M (intermediate raw PTY)
your-daemon /tmp/linux-com1
```

`86box-bridge` sets raw termios on both PTYs (no IXON, no ICRNL, no
ECHO) and throttles host→86Box writes to 1 ms/byte (matches 9600 baud).
Without the throttle, 86Box's UART RX register overruns under burst
writes.

## Cleanroom testing — non-negotiable

dosemu2's UART/PTY emulation accumulates state across runs in subtle
ways: stale FIFOs in `$XDG_RUNTIME_DIR/dosemu2/`, stale `/tmp/dos-com1`
symlinks, qemu-x86_64-wrapped dosemu PIDs that survive their parent.
The same binary that produces N successful RPCs on one run can fail
to install on the next, with no source change.

**Always refresh the dosemu environment on every test.** That's what
`dosemu-cmd` does for you. If you write your own driver, replicate
the kill / rm / spawn / wait / teardown sequence — see
`tools/dosemu/cmd` source.

86Box has a similar (less severe) state-leak property; `86box-cmd`
similarly cold-boots per call.

## What NOT to do

- **Don't run `dosbox-x`.** It's not in this container, and even when
  it was, it bypasses INT 2Fh redirector dispatch — useless for any
  real-DOS work. Use dosemu2 + FDPP or 86Box.
- **Don't reuse a long-lived dosemu instance across unrelated tests.**
  See "Cleanroom testing" above.
- **Don't `kill` 86Box gracefully.** SIGTERM lets it write back its
  cfg with normalized geometry → next boot fails. Use `86box-run stop`
  (SIGKILL).
- **Don't `qemu-img convert` `dos.img` back to VHD.** It rewrites CHS
  geometry; DOS boot fails. Keep `dos.img` raw.
- **Don't edit `/dos/c/86box.cfg` while 86Box is running.** The cfg
  is chmod'd 0444 to make this loud; respect it.
- **Don't put project files in `~/.dosemu/drive_c/`.** That's FDPP's
  bundled boot drive. Use `dosemu-cmd --mount /your/path` to expose
  host directories as DOS drives instead.
- **Don't expect dumb-mode video memory writes to be visible.** dosemu2
  in `-dumb` mode has no video device. Direct writes to 0xB8000 from
  inside DOS code don't appear anywhere — use serial-channel
  diagnostics instead.
- **Don't expect speed.** Effective ~286-class on Apple Silicon; fine
  for serial work, slow for graphics.
- **Don't reinvent the persistent-DOS runner over a floppy.** The
  86Box-side `pcmd` is COM2-based; the dosemu-side equivalent is just
  `dosemu-cmd` itself (already fast enough that persistent REPL
  doesn't help).

## Diagnostic checklist when something goes wrong

1. **dosemu2 not installing your TSR / failing parseargv:**
   - Suspect: stale dosemu state. Run `dosemu-run stop` then retry.
   - Verify: same binary did install before? If so, the env corrupted.
     Container restart may be needed (see SerialDFS quirk #2 in
     `tools/dosemu/README.md`).

2. **dosemu-cmd hangs:**
   - `pgrep -af dosemu` — multiple instances?
   - `ls -l /tmp/dos-com1` — leftover symlink?
   - `ls $XDG_RUNTIME_DIR/dosemu2/` — stale FIFOs?
   - Run `dosemu-run kill-all` to nuke everything, retry.

3. **86Box-specific:**
   - `86box-run status`, `tail /tmp/86box/86box.log`
   - `86box-screen --debug` or `vncdo capture /tmp/peek.png` + Read
   - `qemu-img info /dos/c/dos.img` — is the disk image still raw?
   - `mdir -i /dos/c/dos.img@@$((62*512)) ::` — can you list FAT16?

4. **Serial bytes corrupted:**
   - dosemu2: extremely unlikely (raw PTY, host speed). Check your
     daemon's termios — should be raw.
   - 86Box: `86box-bridge status` + `cat /tmp/86box/bridge.log`. Run
     `86box-bridge foreground --trace` to hex-dump every byte.

5. **dosemu2 dosdebug:**
   - Launch with `dosemu -D+B -dumb -n -f ~/.dosemurc &`
   - Attach with `/usr/bin/dosdebug` in another terminal
   - Set breakpoints with `bp seg:off`, step with `t`, dump regs/mem.

## Building your own DOS project

For the practical loop (build → install → test, serial work,
DOS-specific pitfalls, working test patterns), see [`PROJECTS.md`](PROJECTS.md).

A working minimal reference is at [`examples/hello/`](examples/hello/) —
~30-line `hello.c`, a one-target makefile, and a `test.sh` that
exercises build → install → run-and-assert end-to-end. Run with
`bash /workspace/examples/hello/test.sh` (~10 s on dosemu2, ~40 s on
86Box, depending on which path the test uses).

## When you're done with a task

If you discover something non-obvious about this environment (a new
gotcha, a workaround that wasn't documented, a configuration tweak
that made things faster), update **this file** so the next agent
doesn't have to relearn it. Then update the relevant toolkit README
(`tools/dosemu/README.md` or `tools/86box/README.md`), or
`PROJECTS.md` if it's a project-development learning that should help
future DOS projects.

## Provenance + further reading

- The migration from DOSBox-X to 86Box happened on 2026-04-26.
- dosemu2 was added as the primary emulator on 2026-04-29 / -30 after
  86Box's "5th-RPC trap" UART hang made iterative redirector dev
  painful.
- Companion docs:
  - [`README.md`](README.md) (top-level overview)
  - [`PROJECTS.md`](PROJECTS.md) (DOS project walkthrough)
  - [`tools/dosemu/README.md`](tools/dosemu/README.md) (dosemu2 toolkit reference + quirks)
  - [`tools/86box/README.md`](tools/86box/README.md) (86Box toolkit reference)
  - per-project `~/.claude/projects/.../memory/` (long-term memory)
- Reference DOS project: `/dos/c/serdfs/` (SerialDFS — a serial-driven
  INT 2Fh redirector with ~13 KB resident TSR; uses every toolkit
  feature). Open issues at `/dos/c/serdfs/todos.md`.
- dosemu2: <https://github.com/dosemu2/dosemu2>
- FDPP: <https://github.com/dosemu2/fdpp>
- 86Box: <https://86box.net> · ROMs: <https://github.com/86Box/roms>
- Open Watcom: <https://github.com/open-watcom/open-watcom-v2>
