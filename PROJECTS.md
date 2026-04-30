# PROJECTS.md — building real DOS projects in this sandbox

So you (human or agent) want to write a DOS program — TSR, network
redirector, retro game, packet driver port, whatever — using this
container. This file is the *practical* counterpart to `AGENT.md`: a
walkthrough of the development loop, the test patterns that have
proven to work, and the gotchas that have already cost the previous
project (SerialDFS) hours of debugging.

> **First, read [`AGENT.md`](AGENT.md).** It covers the toolkit and
> what NOT to do. This file assumes you know `86box-cmd`, `86box-run`,
> `86box-bridge`, and `86box-install-dos` exist.
>
> **Want the loop in 4 minutes flat?** Run
> `bash /workspace/examples/hello/test.sh` — it builds a tiny `hello.c`
> with Open Watcom, mcopies into `dos.img`, runs it inside 86Box, and
> asserts the captured stdout. 4/4 PASS in ~40 s. Source at
> [`examples/hello/`](examples/hello/) is the smallest possible copy-
> paste template.

---

## Project layout

```
myproj/
├── Dockerfile             ← copy from /workspace template if standing up your own image
├── docker-compose.yml     ← maps ports 5901 + your TCP port
├── dos-c/                 ← bind-mounted to /dos/c — DOS C: drive lives here
│   ├── dos.img            ← seeded by entrypoint; LASTDRIVE=Z + AUTOEXEC hook patched
│   └── 86box.cfg          ← machine config (default: ninja + serial1 passthrough)
├── workspace/             ← bind-mounted to /workspace — Linux dev workspace
└── .claude/               ← bind-mounted to /home/coder/.claude — Claude Code state

myproj/dos/                ← inside the project itself
├── src/                   ← .c, .h, .asm — Open Watcom inputs
│   └── makefile           ← `wcl -bt=dos -ms -0 -os -fe=build/MYPROG.EXE src/myprog.c`
├── build/                 ← output .EXE / .COM / .OBJ — host-side artifacts
│   └── MYPROG.EXE
└── tools/                 ← optional non-resident DOS utilities
```

You don't HAVE to use this layout — only the bind-mount points
(`./dos-c`, `./workspace`, `./.claude`) are dictated by the Compose
file. Everything inside is yours.

---

## The build → install → test loop

Three steps, all on the Linux side:

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
- `-0` — 8086-compatible code generation. Use `-2` if you only target 286+, `-3` for 386.
- `-os` — optimize for size. `-ot` for speed. Skip if debugging.
- `-d2` — full debug info (use with `-od` for no optimization).
- `-fe=PATH` — output executable path.

Multiple compilation units link in one `wcl` call. For separate
compile/link, use `wcc` / `wlink`.

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
files (`MCOPY -o`) idempotently. **Always run this with 86Box stopped.**

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
state (TSR resident, environment vars, current dir) survives across
all BAT lines. Across calls, nothing survives — that's by design.

> **For sub-second iteration**, use `86box-pcmd` instead. It boots
> 86Box once, runs PCMDD.EXE on the DOS side as a foreground REPL
> over COM2, and lets you submit one-off commands at typing speed
> with TSR / driver state preserved across calls. See the toolkit
> README for caveats (each `pcmd run` is a fresh `COMMAND.COM /C`,
> so env vars + CWD don't survive between runs — TSR state does).

---

## Talking to a Linux process over COM1

Any project that needs DOS-side serial I/O — packet drivers, network
redirectors, debug output — uses 86Box's COM1 PTY passthrough plus
`86box-bridge`:

```
DOS code (UART 0x3F8)  ↔  86Box openpty() pair  ↔  86box-bridge
                                                       ↓
                                               /tmp/linux-com1 (raw PTY)
                                                       ↓
                                               your Linux daemon (pyserial /
                                               socat / whatever)
```

### Setup

The default `86box.cfg` already enables passthrough on serial1 (the
entrypoint generates it with `--serial1-passthrough`). To verify or
re-generate:

```bash
86box-gen-config --out /dos/c/86box.cfg --vhd dos.img --serial1-passthrough
```

### At test time

```bash
# Order: cold-boot 86Box first (so the slave path lands in its log),
# then bring up bridge + daemon. The bridge auto-discovers the slave.

86box-cmd "MYPROG.EXE COM1 9600" > /tmp/myprog.out 2>&1 &
CMD_PID=$!

86box-bridge start                 # waits for /tmp/linux-com1; idempotent
your-daemon /tmp/linux-com1 &      # opens the PTY via pyserial
DAEMON_PID=$!

wait "$CMD_PID"                    # 86Box exits after the BAT writes A:\DONE
kill "$DAEMON_PID"
```

### Tunables when bytes get dropped

86Box's emulated UART under QEMU-user on Apple Silicon occasionally
drops bytes on sustained host→guest bursts. Defaults that work for
the SerialDFS project:

| Knob | Default | Bump if … |
|---|---|---|
| `BOX86_BRIDGE_TX_DELAY_MS` | 4 ms | sustained transfers > 16 chunks lose data |
| your protocol's retry count | 5–10 | one retry isn't enough at scale |
| your protocol's per-attempt timeout | 3–5 s | host→guest > 1 s per chunk |

**Critical protocol design rule learned from SerialDFS:** retries must
be **idempotent**. If your client re-sends a request on timeout, the
server must produce the same response — never advance any cursor /
queue / state-machine. SerialDFS's `CMD_READ` initially used the
server's open-file position, so retries silently skipped chunks; the
fix was extending the request payload with an explicit offset and
using `pread()` instead of `read()` on the server.

---

## Test patterns that work

SerialDFS's `tests/e2e/` directory has four working patterns; copy and
adapt:

### Pattern 1: One-shot smoke test

```bash
86box-cmd "MYPROG.EXE" > /tmp/out.log 2>&1
grep -q "EXPECTED MESSAGE" /tmp/out.log || exit 1
```

### Pattern 2: Multi-step session inside one boot

```bash
86box-cmd <<'BAT' > /tmp/session.log 2>&1
MYTSR /INSTALL
DIR X:\
MYTSR /STATUS
MYTSR /U
BAT
```

TSR install + use + unload — no per-step boot cost. The whole BAT runs
in one ~30 s cold boot.

### Pattern 3: With Linux-side daemon

```bash
86box-cmd <<'BAT' > /tmp/session.log 2>&1 &
MYTSR /INSTALL COM1 9600
... ops on the redirected drive ...
MYTSR /U
BAT
CMD_PID=$!

86box-bridge start
your-daemon /tmp/linux-com1 &
DAEMON_PID=$!

wait "$CMD_PID"
kill "$DAEMON_PID"; 86box-run stop; 86box-bridge stop
```

### Pattern 4: Fault injection (kill daemon mid-test)

```bash
86box-cmd ... > /tmp/out.log 2>&1 &
CMD_PID=$!
86box-bridge start
your-daemon ... 2>/tmp/d.log &
DPID=$!

# Watcher: kill the daemon once the BAT has reached a known-good state
( deadline=$(($(date +%s) + 240))
  while [ $(date +%s) -lt $deadline ]; do
      grep -q 'first-known-good-marker' /tmp/d.log 2>/dev/null && break
      sleep 1
  done
  sleep 2
  kill -9 "$DPID" ) &

wait "$CMD_PID"
# assertions on /tmp/out.log: errors are visible, BAT still completed
```

This proves your TSR/program handles daemon disappearance without
hanging. SerialDFS's `fault_inject.sh` is the reference implementation.

---

## Watching DOS interactively

For debugging a hang, panic, or visual glitch, drive DOS by hand:

```bash
86box-run start /dos/c
86box-run wait-vnc

# Type at the DOS prompt
86box-keys line "DIR C:\\"
86box-keys press enter

# Read the screen as text
86box-screen
# or grab a PNG when the screen is in graphics mode
vncdo -s ::5901 capture /tmp/peek.png

# Stop when done
86box-run stop
```

Or just open `vnc://localhost:5901` from the host (entrypoint started
the headless display stack at container start, so it's always
reachable). No password, no shenanigans.

---

## DOS-specific pitfalls (most cost an hour each first time)

### `LASTDRIVE=Z`

DOS defaults to `LASTDRIVE=E`. Drive letters above E are simply not
allocated in the CDS — installing a redirector for X:/Y:/Z: fails with
"Unable to activate the local drive mapping." The container's
entrypoint patches `LASTDRIVE=Z` into `CONFIG.SYS` on first seed
(idempotent). If you reseed `dos.img` by hand, re-apply it.

### AUTOEXEC.BAT hook

`86box-cmd` works because `entrypoint.sh` patches `AUTOEXEC.BAT` to
run any `A:\RUN.BAT` it finds at boot. Re-applied on every container
start, so as long as you don't replace `AUTOEXEC.BAT` by hand, this
just works.

### Don't `qemu-img convert` `dos.img` back to VHD

It rewrites CHS geometry, breaks DOS boot. Keep `dos.img` raw.

### Don't graceful-stop 86Box

`SIGTERM` lets 86Box save its cfg, normalizing CHS away from the
template's geometry → boot fails. Always use `86box-run stop`
(SIGKILL). The cfg is `chmod 0444` while up as defense in depth.

### MEM /C interaction with redirector TSRs

A `MEM /C` immediately after a redirector TSR install in the same BAT
hangs DOS under 86Box+QEMU. SerialDFS's e2e_tsr.sh hit this and
worked around it by running MEM /C in a separate cold boot. Likely a
UMB/XMS enumeration ↔ CDS interaction; root cause not pinned down.

### Status-bar bytes leak into OUT.TXT

If your TSR draws a status bar via `INT 28h`/`INT 1Ch` hooks, those
writes go to video memory but the install banner is also a chunk of
text. When `86box-cmd` captures `A:\OUT.TXT`, the install message and
some screen bytes can be interleaved — `strings`/`grep -aF` in your
test scripts handles this fine. SerialDFS's tests use `grep -aF` for
all post-install content checks.

### Redirector TSRs and `INT 2Fh AH=11h`

The whole point of using **86Box** (not DOSBox-X) is real INT 2Fh
dispatch. A TSR installs a handler for INT 2Fh AH=11h, DOS calls it
for redirector subfunctions (AL_OPEN, AL_FINDFIRST, etc.). If you're
porting an EtherDFS-style redirector, vendor `etherdfs/` and copy its
`dosstruc.h` / `chint086.asm` / `chint.h` verbatim — those structures
are not something to retype. SerialDFS lives at `/dos/c/serdfs/` and
follows that pattern.

### DOS COMMAND.COM uses `AL_SPOPNFIL` for COPY/TYPE

Instead of `AL_OPEN` (0x16), DOS 6.22 COMMAND.COM dispatches COPY's
source-file open and TYPE's open via `AL_SPOPNFIL` (0x2E) with action
code `0x01` (which RBIL says is "fail-if-exists, create-if-not", an
exclusive create). Empirically DOS uses it as an existence probe and
expects the redirector to return either a file handle (treating it
as "open existing") or error 80. SerialDFS's handler probes via
`CMD_OPEN` first for this case and returns CX=1 — that's what makes
COPY/TYPE on a redirected drive actually work. If you're writing your
own redirector, do the same.

---

## When to break out of the toolkit

The provided `86box-*` tools cover the 95% case. Reach for raw tools
when you need to:

- **Debug a serial protocol byte-by-byte** → `86box-bridge --trace`
  hex-dumps every chunk both directions.
- **Inspect dos.img mid-test** → 86box must be stopped first.
  `mdir -i /dos/c/dos.img@@$((62*512)) ::` lists; `mtype` reads;
  `mcopy -o` writes.
- **Watch the actual VGA framebuffer** → `vncdo -s ::5901 capture
  /tmp/peek.png` and Read it. `86box-screen` ASCII-decodes text mode
  but falls back to the PNG path on graphics mode / unfamiliar font.
- **Step through emulated CPU** → 86Box has a built-in debugger
  reachable from its menu, but the menu is hidden behind VNC. Open
  `vnc://localhost:5901`, click the View menu, enable Debugger.
  (You'll have to disable the cfg-protection chmod to keep the
  debugger settings between runs.)

---

## Where to find each piece

| What | Where |
|---|---|
| Tool sources (`86box-*`) | `/workspace/tools/86box/` |
| Tool reference docs | `tools/86box/README.md` |
| Agent orientation | `AGENT.md` |
| Top-level project doc | `README.md` |
| The DOS template (read-only) | `/opt/dos-c-base/template_dos-c.vhd` |
| Open Watcom toolchain | `/opt/watcom/` |
| Extracted 86Box AppImage | `/opt/86box/` |
| ROMs | `/opt/86box/roms/` |
| Per-project DOS C: drive | `/dos/c/` |
| Per-project agent memory | `/home/coder/.claude/projects/.../memory/` |
| Reference DOS project | `/dos/c/serdfs/` (SerialDFS) |
