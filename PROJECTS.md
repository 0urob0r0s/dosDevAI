# PROJECTS.md — building real DOS projects in this sandbox

So you (human or agent) want to write a DOS program — TSR, network
redirector, retro game, packet driver port, whatever — using this
container. This file is the *practical* counterpart to `AGENT.md`: a
walkthrough of the development loop, the test patterns that have
proven to work, and the gotchas that have already cost the previous
project (SerialDFS) hours of debugging.

> **First, read [`AGENT.md`](AGENT.md).** It covers the toolkits and
> what NOT to do. This file assumes you know the dosemu2 (`dosemu-*`)
> and 86Box (`86box-*`) wrappers exist.
>
> **Want the loop in 4 minutes flat?** Run
> `bash /workspace/examples/hello/test.sh` — it builds a tiny `hello.c`
> with Open Watcom, boots dosemu2, runs the `.EXE` from a hostfs
> mount, and asserts the captured stdout. 4/4 PASS in ~10 s.

---

## Pick your emulator

| Project type | Recommended path |
|---|---|
| TSR / redirector / serial-protocol DOS work | **dosemu2** primary, 86Box for fidelity check |
| Plain DOS app (no exotic hardware coupling) | **dosemu2** |
| BIOS / IDE-driver / boot-sector / hardware-quirk work | **86Box** |
| Game with VGA mode 13h / Sound Blaster | **86Box** (better hardware emulation) |

For everything else, start with dosemu2 and switch only if you find
behavior that demands real-hardware accuracy.

---

## Project layout

```
myproj/
├── Dockerfile             ← copy from /workspace template if standing up your own image
├── docker-compose.yml     ← maps ports 5901 + your TCP port
├── dos-c/                 ← bind-mounted to /dos/c — DOS C: drive (86Box) /
│                              optional mount target for dosemu-cmd
│   ├── dos.img            ← 86Box FAT16 image; only needed for 86Box path
│   └── 86box.cfg          ← machine config; only needed for 86Box path
├── workspace/             ← bind-mounted to /workspace — Linux dev workspace
└── .claude/               ← bind-mounted to /home/coder/.claude — Claude Code state

myproj/dos/                ← inside the project itself
├── src/                   ← .c, .h, .asm — Open Watcom inputs
│   └── makefile           ← `wcl -bt=dos -ms -0 -os -fe=build/MYPROG.EXE src/myprog.c`
├── build/                 ← output .EXE / .COM / .OBJ — also dosemu's hostfs mount target
│   └── MYPROG.EXE
└── tools/                 ← optional non-resident DOS utilities
```

You don't HAVE to use this layout — only the bind-mount points
(`./dos-c`, `./workspace`, `./.claude`) are dictated by the Compose
file. Everything inside is yours.

---

## The build → run loop (dosemu2 — preferred)

Two steps total. No "install into image" step. The host directory
becomes a DOS drive.

### 1. Build with Open Watcom

```bash
# A 16-bit small-memory-model DOS .EXE
wcl -bt=dos -ms -0 -os -fe=build/MYPROG.EXE src/myprog.c

# Compact memory model for things needing > 64 KB code or data
wcl -bt=dos -mc -0 -os -fe=build/BIG.EXE src/big.c

# With a separate .asm file
wasm src/foo.asm -fo=build/foo.obj
wcl -bt=dos -ms -0 -os -fe=build/MYPROG.EXE src/myprog.c build/foo.obj
```

Common `wcl` flags:
- `-bt=dos` — target DOS (16-bit real mode).
- `-ms` / `-mc` / `-ml` — small / compact / large memory model.
- `-0` — 8086-compatible. `-2` for 286+, `-3` for 386+.
- `-os` — optimize for size. `-ot` for speed. Skip if debugging.
- `-d2` — full debug info (use with `-od` for no optimization).
- `-fe=PATH` — output executable path.

Multiple compilation units link in one `wcl` call. For separate
compile/link, use `wcc` / `wlink`.

### 2. Run inside DOS

```bash
# Quick one-shot
dosemu-cmd --mount $(pwd)/build "G:" "G:\\MYPROG.EXE arg1 arg2"

# Multi-step session (TSR install + ops + unload, all in ONE boot)
dosemu-cmd --mount $(pwd)/build \
    "G:" \
    "G:\\MYPROG.EXE /INSTALL" \
    "DIR X:" \
    "MYPROG /STATUS" \
    "MYPROG /U"

# With a Linux-side daemon (e.g. for serial protocol work)
dosemu-cmd --mount $(pwd)/build \
    --daemon "python3 -m linux.serdfsd \
                --serial /tmp/dos-com1 --baud 9600 \
                --root /workspace/DOS --log-level DEBUG \
                > /tmp/serdfsd.log 2>&1" \
    --tail-sleep 10 \
    "G:" "SERDFS X /COM1 /BAUD:9600" "X:" "DIR X:" "EXIT"
```

Each `dosemu-cmd` call refreshes the dosemu environment from scratch
(see "Cleanroom testing" in [`AGENT.md`](AGENT.md)). Inside one call,
DOS state (TSR resident, environment vars, current dir) survives
across all commands. Across calls, nothing survives — by design.

> **Throughput.** ~5 s for a single command, then +`--cmd-sleep` (default
> 3 s) per additional command, plus `--tail-sleep` (default 6 s) after
> the last one. So 4-command session ≈ 5 + 3·3 + 6 = 20 s.

---

## The build → install → test loop (86Box — alternative)

Use when you specifically need real-BIOS / real-IDE behavior.

### 1. Build with Open Watcom

(Same as above.)

### 2. Install into dos.img

```bash
# Stop the emulator first — concurrent mtools+IDE writes corrupt FAT.
86box-run stop

# Copy your build artifacts into a DOS path.
86box-install-dos --to 'C:\MYPROJ\BUILD' --src ./build --pattern '*.EXE'

# Or pick specific files.
86box-install-dos --to 'C:\MYPROJ' build/MYPROG.EXE build/MYPROG.DAT
```

`86box-install-dos` creates the directory chain (`MMD`) and copies
files (`MCOPY -o`) idempotently. **Always run with 86Box stopped.**

### 3. Test inside DOS

```bash
# Quick one-shot
86box-cmd "C:\\MYPROJ\\BUILD\\MYPROG.EXE"

# Multi-line BAT — TSR install + ops + unload all in one cold boot
86box-cmd <<'BAT'
C:\MYPROJ\BUILD\MYPROG.EXE /INSTALL
DIR C:\
MYPROG /STATUS
MYPROG /U
BAT
```

Each `86box-cmd` call cold-boots 86Box (~30 s). Inside one call, DOS
state survives across all BAT lines. Across calls, nothing survives.

For sub-second iteration on the 86Box path, use `86box-pcmd` — see
the 86Box toolkit README for caveats. **On the dosemu2 path, you
don't need a persistent runner — `dosemu-cmd` is already fast.**

---

## Talking to a Linux process over COM1

### dosemu2 path — direct PTY

Default `~/.dosemurc` config:
```
$_com1 = "pts /tmp/dos-com1"
```

Each dosemu launch creates a fresh PTY pair and symlinks the slave to
`/tmp/dos-com1`. Linux processes attach directly:

```bash
DOS code (UART 0x3F8)  ↔  dosemu's openpty slave  ↔  /tmp/dos-com1
                                                          ↓
                                                  your Linux daemon
```

No bridge, no host-side throttle, no termios cooking — dosemu's UART
runs at host speed. The wrapper script `dosemu-cmd --daemon "CMD"`
handles the wait-for-symlink + spawn dance for you.

### 86Box path — bridge required

```
DOS code (UART 0x3F8)  ↔  86Box openpty() pair  ↔  86box-bridge
                                                       ↓
                                               /tmp/linux-com1 (raw PTY)
                                                       ↓
                                               your Linux daemon
```

```bash
86box-cmd "MYPROG.EXE COM1 9600" > /tmp/myprog.out 2>&1 &
CMD_PID=$!

86box-bridge start                 # waits for /tmp/linux-com1
your-daemon /tmp/linux-com1 &      # opens the PTY via pyserial
DAEMON_PID=$!

wait "$CMD_PID"
kill "$DAEMON_PID"
```

### Tunables when bytes get dropped (mostly 86Box)

| Knob | Default | Bump if … |
|---|---|---|
| `BOX86_BRIDGE_TX_DELAY_MS` (86Box) | 4 ms | sustained transfers > 16 chunks lose data |
| your protocol's retry count | 5–10 | one retry isn't enough at scale |
| your protocol's per-attempt timeout | 3–5 s | host→guest > 1 s per chunk |

dosemu2 doesn't generally drop bytes — but its UART emulation has a
**buffer-saturation pattern around 5 KB sustained transfer** that can
make every 10th–11th RPC fail. This was the reason for the migration
from 86Box (which has a worse equivalent at the 5th RPC). For both
emulators, the protocol design rule below is mandatory.

**Critical protocol design rule learned from SerialDFS:** retries
must be **idempotent**. If your client re-sends a request on timeout,
the server must produce the same response — never advance any cursor
/ queue / state-machine. SerialDFS's `CMD_READ` initially used the
server's open-file position, so retries silently skipped chunks; the
fix was extending the request payload with an explicit offset and
using `pread()` instead of `read()` on the server.

---

## Test patterns that work

SerialDFS's `tests/e2e/` directory has working patterns; copy and
adapt. Below are the dosemu2-flavored versions.

### Pattern 1: One-shot smoke test

```bash
OUT=$(dosemu-cmd --mount $(pwd)/build "G:" "G:\\MYPROG.EXE")
echo "${OUT}" | grep -q "EXPECTED MESSAGE" || exit 1
```

### Pattern 2: Multi-step session inside one boot

```bash
OUT=$(dosemu-cmd --mount $(pwd)/build \
    "G:" \
    "MYTSR /INSTALL" \
    "DIR X:" \
    "MYTSR /STATUS" \
    "MYTSR /U")
```

TSR install + use + unload — no per-step boot cost. The whole
session runs in one ~5 s cold boot.

### Pattern 3: With Linux-side daemon

```bash
dosemu-cmd \
    --mount $(pwd)/build \
    --daemon "your-daemon /tmp/dos-com1 > /tmp/d.log 2>&1" \
    --tail-sleep 8 \
    "G:" \
    "MYTSR /INSTALL COM1 9600" \
    "DIR X:" \
    "MYTSR /U" > /tmp/session.log
```

`dosemu-cmd` waits for `/tmp/dos-com1` to exist before launching the
daemon, and reaps both processes at teardown.

### Pattern 4: Fault injection (kill daemon mid-test)

```bash
# Kick off dosemu in background
dosemu-cmd \
    --mount $(pwd)/build \
    --daemon "your-daemon /tmp/dos-com1 2>/tmp/d.log" \
    --tail-sleep 30 \
    "G:" "MYTSR /INSTALL COM1 9600" "ops..." > /tmp/out.log &
CMD_PID=$!

# Watcher: kill the daemon once a known-good marker appears
( deadline=$(($(date +%s) + 60))
  while [ $(date +%s) -lt $deadline ]; do
      grep -q 'first-known-good-marker' /tmp/d.log 2>/dev/null && break
      sleep 1
  done
  sleep 2
  pkill -9 -f your-daemon ) &

wait "$CMD_PID"
# assertions on /tmp/out.log: errors are visible, BAT still completed
```

This proves your TSR/program handles daemon disappearance without
hanging.

---

## Watching DOS interactively

### dosemu2 (preferred)

```bash
dosemu-vnc-start /your/build/dir
# from your host:
open vnc://localhost:5901    # macOS — or any VNC client → 5901
# fluxbox + xterm with dosemu in dumb video; type at the DOS prompt.
dosemu-vnc-stop              # tear down when done
```

For redirector debugging with a daemon:
```bash
dosemu-vnc-start \
    --daemon "your-daemon /tmp/dos-com1 > /tmp/d.log 2>&1" \
    /your/build/dir
```

### 86Box (alternative)

```bash
86box-run start /dos/c
86box-run wait-vnc
86box-keys line "DIR C:\\"
86box-screen
vncdo -s ::5901 capture /tmp/peek.png   # for graphics modes
86box-run stop
```

Or `open vnc://localhost:5901` directly.

---

## DOS-specific pitfalls (most cost an hour each first time)

### `LASTDRIVE=Z`

DOS defaults to `LASTDRIVE=E`. Drive letters above E are simply not
allocated in the CDS — installing a redirector for X:/Y:/Z: fails
with "Unable to activate the local drive mapping."

- **86Box path:** the entrypoint patches `LASTDRIVE=Z` into
  `CONFIG.SYS` on first seed (idempotent). If you reseed `dos.img` by
  hand, re-apply it.
- **dosemu2 path:** FDPP's bundled `fdppconf.sys` already sets
  `lastdrive=Z`.

### Don't `qemu-img convert` `dos.img` back to VHD (86Box)

It rewrites CHS geometry, breaks DOS boot. Keep `dos.img` raw.

### Don't graceful-stop 86Box

`SIGTERM` lets 86Box save its cfg, normalizing CHS away from the
template's geometry → boot fails. Always use `86box-run stop`
(SIGKILL). The cfg is `chmod 0444` while up as defense in depth.
dosemu2 has no equivalent issue.

### Cleanroom every test

The dosemu2 environment accumulates state across runs (see AGENT.md
"Cleanroom testing"). Always use `dosemu-cmd` (or replicate its
kill/rm/spawn/teardown logic) for each test. Don't try to reuse a
long-lived dosemu instance across unrelated tests.

### MEM /C interaction with redirector TSRs (86Box specifically)

A `MEM /C` immediately after a redirector TSR install in the same BAT
hangs DOS under 86Box+QEMU. SerialDFS's `e2e_tsr.sh` hit this and
worked around it by running MEM /C in a separate cold boot. dosemu2
does NOT exhibit this hang.

### Status-bar bytes leak into captured output

If your TSR draws a status bar via `INT 28h`/`INT 1Ch` hooks, those
writes go to video memory but the install banner is also a chunk of
text. When `86box-cmd` or `dosemu-cmd` captures the screen, the
install message and some screen bytes can be interleaved — `strings`
/ `grep -aF` in your test scripts handles this fine.

### Redirector TSRs and `INT 2Fh AH=11h`

The whole point of using **dosemu2 + FDPP** or **86Box** (not
DOSBox-X) is real INT 2Fh dispatch. A TSR installs a handler for
INT 2Fh AH=11h, DOS calls it for redirector subfunctions (AL_OPEN,
AL_FINDFIRST, etc.). If you're porting an EtherDFS-style redirector,
vendor `etherdfs/` and copy its `dosstruc.h` / `chint086.asm` /
`chint.h` verbatim — those structures are not something to retype.
SerialDFS lives at `/dos/c/serdfs/` and follows that pattern.

### DOS COMMAND.COM uses `AL_SPOPNFIL` for COPY/TYPE

Instead of `AL_OPEN` (0x16), DOS 6.22 / FDPP COMMAND.COM dispatches
COPY's source-file open and TYPE's open via `AL_SPOPNFIL` (0x2E)
with action code `0x01`. SerialDFS's handler probes via `CMD_OPEN`
first for this case and returns CX=1 — that's what makes COPY/TYPE
on a redirected drive actually work. If you're writing your own
redirector, do the same.

### dosemu2 dumb-mode video memory writes are invisible

`-dumb` mode has no video device. Direct writes from inside DOS code
to 0xB8000 don't appear anywhere. If you're using video-memory
beacons as a cheap diagnostic, they won't show in `dosemu-cmd`
output. Use serial-channel side-diagnostics instead (extra payload
fields, side-channel CMD_PING with state).

### dosemu2 install threshold (open issue)

Watcom-built TSRs that use `#pragma code_seg("BEGTEXT", "CODE")` for
the resident image can hit a **byte-exact-fragile install threshold**:
+8–16 bytes of BEGTEXT growth can break parseargv ("Usage:" message
prints instead of the install banner). Adding 32 bytes of pure NOP
padding has been verified sufficient. Suspected cause: fixed-offset
relocation in the Watcom-emitted prologue or chint086.asm; root cause
not pinned down. See `/dos/c/serdfs/todos.md` for the open
investigation. If you hit this on a new project, the workaround is
"don't grow BEGTEXT" — keep diagnostics out of the resident image.

### dosemu2 EXEC truncation around 5 KB (open issue)

EXEC of an EXE > ~5 KB through a SerialDFS-style network redirector
truncates the load image; daemon serves all bytes correctly but DOS
loads only the first 9–10 chunks (~4.6–5.1 KB). Partial code crashes
with `Invalid Opcode`. COPY of the same files works fine. Workaround:
copy locally first (`COPY X:\PROG.EXE C:\PROG.EXE`) before EXEC. Same
investigation as above; see SerialDFS `todos.md`.

---

## When to break out of the toolkit

The provided `dosemu-*` and `86box-*` tools cover the 95% case.
Reach for raw tools when you need to:

- **Step debugger (dosemu2)** → launch with `dosemu -D+B -dumb -n &`,
  attach via `/usr/bin/dosdebug`. Set breakpoints with `bp seg:off`,
  step with `t`, dump regs/memory.
- **Debug a serial protocol byte-by-byte (86Box)** → `86box-bridge
  --trace` hex-dumps every chunk both directions. (dosemu2's PTY can
  be hexdumped with `socat -x`.)
- **Inspect dos.img mid-test (86Box)** → 86box must be stopped first.
  `mdir -i /dos/c/dos.img@@$((62*512)) ::` lists; `mtype` reads;
  `mcopy -o` writes.
- **Watch the actual VGA framebuffer (86Box)** → `vncdo -s ::5901
  capture /tmp/peek.png` and Read it. `86box-screen` ASCII-decodes
  text mode but falls back to the PNG path on graphics mode /
  unfamiliar font.
- **Step through emulated CPU (86Box)** → built-in debugger reachable
  from its menu (View > Debugger via VNC).

---

## Where to find each piece

| What | Where |
|---|---|
| dosemu2 toolkit sources | `/workspace/tools/dosemu/` |
| dosemu2 toolkit reference | `tools/dosemu/README.md` |
| 86Box toolkit sources | `/workspace/tools/86box/` |
| 86Box toolkit reference | `tools/86box/README.md` |
| Agent orientation | `AGENT.md` |
| Top-level project doc | `README.md` |
| dosemu2 default config (~/.dosemurc) | `tools/dosemu/dosemurc.template` |
| 86Box DOS template (read-only) | `/opt/dos-c-base/template_dos-c.vhd` |
| FDPP kernel (dosemu2's DOS core) | `/usr/share/fdpp/fdppkrnl.*.elf` |
| Open Watcom toolchain | `/opt/watcom/` |
| Extracted 86Box AppImage | `/opt/86box/` |
| 86Box ROMs | `/opt/86box/roms/` |
| Per-project DOS C: drive | `/dos/c/` |
| Per-project agent memory | `/home/coder/.claude/projects/.../memory/` |
| Reference DOS project | `/dos/c/serdfs/` (SerialDFS) |
| Reference open issues | `/dos/c/serdfs/todos.md` |
