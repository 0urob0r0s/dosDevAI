# `tools/dosemu/` — the dosemu2 helper toolkit (primary emulator)

These scripts wrap **dosemu2** (with **FDPP** as the DOS core) for
headless, agent-driven, reproducible use inside the DOS Dev Sandbox
container. They are the **primary** development+testing path; the
86Box toolkit at `tools/86box/` is kept as an alternative for
hardware-fidelity scenarios (real BIOS, full IDE controller, etc.).

> **Read this first if you're new:** [`/workspace/AGENT.md`](../../AGENT.md)
> for orientation, [`/workspace/PROJECTS.md`](../../PROJECTS.md) for
> the project-development walkthrough.

---

## Why dosemu2 (and when to use 86Box instead)

| | **dosemu2** (preferred) | 86Box |
|---|---|---|
| Boot time per call | ~2–3 s | ~30 s |
| BIOS / IDE accuracy | host syscalls, no real BIOS | real BIOS + IDE |
| COM1 transport | raw PTY (`pts /tmp/dos-com1`) — no bridge | openpty + `86box-bridge` (4 ms/byte throttle) |
| Hostfs mount | `dosemu -d /path` → next free DOS letter | mtools `mcopy` into `dos.img` (offline) |
| Live VNC | fluxbox + xterm + dumb video → port 5901 | Qt window via Xvfb → port 5901 |
| Headless dumb mode | yes (`-dumb`, stdin/stdout) | no (always Qt) |
| Apple Silicon (linux/amd64 under qemu-user) | works in pure-emu (`$_cpuemu = (1)`) | works (slow) |
| Best for | iterative dev, redirector / TSR projects, CI-style testing | BIOS testing, IDE-quirk debugging, full-PC emulation |

**Default to dosemu2.** Switch to 86Box only when you specifically
need real BIOS, real IDE timing, or a behavior you've already
verified differs between the two emulators.

---

## What's installed

The image's Dockerfile installs (via `setup.sh`):

- **dosemu2** (`/usr/bin/dosemu`, `/usr/bin/dosdebug`)
- **FDPP** (`/usr/share/fdpp/fdppkrnl.*.elf`) — FreeDOS-derived 64-bit DOS core
- **fluxbox** + **xterm** — used by the VNC mode
- **xdotool** — focuses the xterm window after launch

User-side configs go to `$HOME`:

- `~/.dosemurc` — default, dumb-video, PTY COM1 baseline.
- `~/.dosemu-vnc.rc` — used by the VNC mode (currently identical
  content; kept separate so the two paths can diverge).

The `~/.dosemu/drive_c/` is dosemu's own boot drive (FDPP system files
+ `fdppconf.sys`). **Don't put project files there** — use `-d
/your/path` to mount instead, which assigns the next free DOS letter
(typically `G:`).

---

## The four scripts

All under `/usr/local/bin/dosemu-*` after image build. Source in
`/workspace/tools/dosemu/`.

### `cmd` → `dosemu-cmd`

The cleanroom non-interactive runner. Equivalent of `86box-cmd` but
~10× faster per call (boot time ~2–3 s vs 30 s).

```bash
# Quick one-shot
dosemu-cmd "DIR C:"

# Multi-line session
dosemu-cmd "VER" "DIR C:" "MEM /C"

# Mount a directory as G: and run a TSR test
dosemu-cmd --mount /dos/c/serdfs/dos/build \
           "G:" "SERDFS X /COM1 /BAUD:9600" "X:" "DIR X:" "SERDFS /U"

# Run a Linux-side daemon alongside (e.g. SerialDFS)
dosemu-cmd \
    --mount /dos/c/serdfs/dos/build \
    --daemon "cd /dos/c/serdfs && python3 -m linux.serdfsd \
              --serial /tmp/dos-com1 --baud 9600 \
              --root /workspace/DOS --log-level DEBUG" \
    --tail-sleep 8 \
    "G:" "SERDFS X /COM1 /BAUD:9600" "X:" "DIR X:" "EXIT"
```

What every call does:

1. Reaps all stale dosemu / qemu-x86_64-wrapping-dosemu / serdfsd
   processes from prior runs.
2. Cleans `/tmp/dos-com1`, the FIFO, and `$XDG_RUNTIME_DIR/dosemu2/*`
   (dosemu's debug FIFOs accumulate per-PID and never auto-clean).
3. Spawns a fresh dosemu under stdin/stdout via a named FIFO.
4. Waits for `Welcome to dosemu2` in the captured stdout (boot done).
5. If `--daemon` was given, waits for `/tmp/dos-com1` PTY symlink,
   then spawns each daemon as a background process.
6. Feeds DOS commands one-per-line, sleep `--cmd-sleep` (default 3s)
   between them. Last command gets `--tail-sleep` (default 6s) — bump
   this if the command's behavior includes long retry/timeout windows
   (e.g. a TSR's serial RPC retry of 10×5 s = 50 s).
7. Prints the captured DOS screen to stdout and tears down everything.

Use `--keep` to leave the session running for inspection (useful for
debugging the cleanup logic itself).

### `run.sh` → `dosemu-run`

Lower-level start/stop/status. Three modes:

```bash
dosemu-run display-up           # bring up Xvfb + x11vnc only
dosemu-run dumb [-d <dir>]      # foreground dumb dosemu, attached to current tty
dosemu-run vnc  [-d <dir>]      # background fluxbox+xterm+dosemu on VNC :99
dosemu-run stop                 # kill dosemu/fluxbox/xterm; leave Xvfb+x11vnc
dosemu-run kill-all             # also stop the display stack
dosemu-run status               # what's up
```

`dumb` mode is what `dosemu-cmd` uses internally; you rarely call it
directly. `vnc` mode is the live-debug path documented below.

### `vnc-start.sh` → `dosemu-vnc-start`

Project-friendly wrapper around `dosemu-run vnc`. Takes a mount dir
(default `/dos/c`) and optional `--daemon` invocations.

```bash
dosemu-vnc-start                                  # mount /dos/c, no daemons
dosemu-vnc-start /dos/c/serdfs/dos/build          # mount that path as G:
dosemu-vnc-start --daemon "linux-redirector ..." /dos/c/proj
```

Then `open vnc://localhost:5901` from the host. You'll see fluxbox
with a single 100×36 xterm window titled `DOSEMU2`, running
dosemu in dumb video — type at the DOS prompt, watch the screen
update. **No GUI tokens** are consumed if you observe via VNC
yourself (this is for human use; AI agents should prefer `dosemu-cmd`
and read its captured stdout).

### `vnc-stop.sh` → `dosemu-vnc-stop`

Stops the VNC session (dosemu + fluxbox + xterm + any project-side
daemons). Leaves Xvfb + x11vnc up so the next session is fast.

---

## How to do common things

### Run a DOS command and capture output (AI / batch)

```bash
dosemu-cmd "DIR C:" "VER" "MEM"
```

Cold-spawn-to-output is ~5 s for a single command. Multi-command runs
share one boot, so 3 commands ≈ 5 + 3·`--cmd-sleep` = ~14 s.

### Build a DOS .EXE on Linux and test it via dosemu

```bash
# Linux side
wcl -bt=dos -ms -0 -os -fe=BUILD/HELLO.EXE src/hello.c

# Run it inside DOS — no `mcopy` step. dosemu's `-d` flag mounts the
# host directory as a DOS drive, so the just-built EXE is reachable
# immediately.
dosemu-cmd --mount $(pwd)/BUILD "G:" "G:\\HELLO.EXE arg1 arg2"
```

Compare to 86Box, where every test cycle requires `86box-run stop` →
`mcopy` into `dos.img` → `86box-cmd`. dosemu's hostfs mount eliminates
the install step entirely.

### Debug a TSR / redirector with a Linux-side daemon

```bash
dosemu-cmd \
    --mount /dos/c/serdfs/dos/build \
    --daemon "python3 -m linux.serdfsd \
                --serial /tmp/dos-com1 --baud 9600 \
                --root /workspace/DOS --log-level DEBUG \
                > /tmp/serdfsd.log 2>&1" \
    --tail-sleep 10 \
    "G:" \
    "SERDFS X /COM1 /BAUD:9600" \
    "X:" \
    "DIR X:" \
    "COPY X:\\HELLO.EXE C:\\HELLO.OUT"

# Inspect the daemon trace afterwards:
grep -E 'rx cmd|READ' /tmp/serdfsd.log | head
```

The `pts /tmp/dos-com1` config in `~/.dosemurc` makes COM1 a raw PTY
that the daemon attaches to directly — **no `86box-bridge`-style
shuttle, no per-byte throttling**, no TX_DELAY tuning. dosemu's UART
emulation is at host speed.

### Watch DOS interactively (live human testing)

```bash
dosemu-vnc-start /dos/c/serdfs/dos/build
# now connect from the host:
#   open vnc://localhost:5901            (macOS)
#   any VNC client → localhost:5901      (everything else)
```

You'll see the fluxbox desktop with one xterm window. Type at the
prompt, watch the screen, switch focus with the WM. When done:

```bash
dosemu-vnc-stop
```

### Drive dosemu programmatically without dosemu-cmd

If you need full control (custom rc, debugger flags, etc.):

```bash
dosemu -dumb -n -f ~/.dosemurc -d /path/to/proj < cmds.txt > out.txt 2>&1
```

`-dumb` = no graphical output (text into stdout). `-n` = no terminal
init. `-f` = which rc file. `-d` = mount host dir.

For interactive live-step debugging via dosemu's built-in debugger:

```bash
dosemu -D+B -dumb -n &      # enables `dosdebug trace` (B flag)
dosdebug                    # interactive debugger client
# inside dosdebug: bp <seg>:<off>, c, r, m, etc.
```

---

## Cleanroom testing — a hard-learned lesson

dosemu2's emulated UART (and the qemu-user-mode wrapping it on Apple
Silicon) **accumulates state** across runs in ways that are hard to
isolate: `/tmp` PTY symlinks survive process death, FIFO files build
up under `$XDG_RUNTIME_DIR/dosemu2/`, daemon processes wrapping
qemu-x86_64 don't always die when their parent shell dies. The same
binary that produces N successful RPCs on one run can fail to install
on the next run, with no source change.

**Always use `dosemu-cmd` (or the same teardown logic) per test.**
Don't reuse a long-lived dosemu instance across unrelated tests. Don't
write your own ad-hoc driver that skips the cleanup steps.

The cleanroom contract is:

1. Kill prior dosemu / qemu-wrapped-dosemu / project daemons.
2. `rm -f /tmp/dos-com1 /tmp/dos-stdin*`
3. `rm -rf $XDG_RUNTIME_DIR/dosemu2; mkdir -p ...`
4. Spawn fresh dosemu.
5. Run the test.
6. Tear down everything you spawned + run steps 1–3 again.

Skipping any of these has produced "same binary, different result"
within minutes of a previous successful run.

---

## Development quirks discovered the hard way

These are dosemu2-specific behaviors worth knowing when porting a DOS
project here.

### 1. UART buffer saturation around 5 KB sustained transfer

Sustained back-to-back RPC traffic (a TSR redirector pushing chunked
file reads, ~512 bytes each) tends to fail somewhere in the
4.6–5.2 KB range. The pattern: 9–10 RPCs work fine, the 10th or 11th
hangs the TX or drops a reply. This is the dosemu equivalent of
86Box's "5th-RPC trap" (which fails sooner under different config).

If your protocol crosses this threshold, build it idempotent (offset
in every request, retries safe to repeat) and add a multi-attempt
retry budget (10 retries × 5 s timeout each is what SerialDFS uses).
A TSR-internal pause between RPCs (drain UART, reset 16550 FCR FIFOs)
also helps.

Same protocol design rule as 86Box: **retries must be idempotent**.
Server must produce the same response on a repeat request, never
advance any cursor / queue / offset.

### 2. Install-time binary-size threshold (TSR projects)

Watcom-built TSRs that use `#pragma code_seg("BEGTEXT", "CODE")` to
keep code resident hit a **byte-exact-fragile threshold**: even
+8–16 bytes of BEGTEXT growth can break parseargv at install time
(SERDFS prints the help message instead of installing). Adding 32
bytes of pure NOP padding to BEGTEXT — no functional change, no libc
pull-in, no DGROUP shift — is enough to trigger it.

Suspected cause: a relocation, far-jump, or fixed-offset assumption
somewhere in the resident image's load path under FDPP. Math of the
TSR keep-paragraph calculation has been verified correct.

This is open. If you're hitting it on a new project, see
`/dos/c/serdfs/todos.md` for the full investigation notes and the
phased plan.

### 3. Function-call additions can drag in libc helpers

Adding even one new `(void)serial_rpc(...)` call site to a previously
slim TSR can cause Watcom to link in malloc / sbrk / heap helpers,
inflating the binary by ~1.5 KB and triggering a "*** NULL assignment
detected" message at exit (the libc runtime sentinel detects writes
to DGROUP:0..0x1F).

Workaround: restructure to avoid the new call site, OR explicitly
exclude the libc symbol via wlink options.

### 4. FDPP loader EXE truncation (open issue)

EXEC of an EXE > ~5 KB through a SerialDFS-style network redirector
truncates the load image. The daemon serves all bytes correctly, but
DOS only loads the first 9–10 chunks (~4.6–5.1 KB) before the
internal AL_READFIL loop exits. Partial code crashes with `Invalid
Opcode`. COPY of the same files works fine (uses different code path
in COMMAND.COM). See `/dos/c/serdfs/todos.md`.

### 5. dosemu's `qemu-x86_64` wrapper layer (Apple Silicon hosts)

On Apple Silicon, the linux/amd64 container runs under
`qemu-x86_64 user-mode emulation`. dosemu binaries appear in `ps` as
`/usr/bin/qemu-x86_64 /usr/libexec/dosemu2/dosemu2.bin ...`. Plain
`pkill -f dosemu` matches the wrapper but not the wrapped binary
(which has its own PID). Always reap by **process tree**, not by
single-pattern pkill — see `cmd`'s reap loop:

```bash
ps -eo pid,ppid,args | awk '
    $2==1 && /dosemu2\.bin|\/usr\/bin\/dosemu/ {print $1}
' | xargs -r kill -9
pkill -9 -f 'qemu-x86_64.*dosemu' || true
```

### 6. dosemu's debug FIFOs (`$XDG_RUNTIME_DIR/dosemu2/`)

dosemu creates `dosemu.dbgin.<PID>` and `dosemu.dbgout.<PID>` FIFOs
under `$XDG_RUNTIME_DIR/dosemu2/` for the dosdebug client to attach
to. **They are not cleaned up on process death.** Stale FIFOs from
previous runs accumulate; in extreme cases they can block new dosemu
launches. `dosemu-cmd` removes them at start and end. If you write
your own driver, do the same.

### 7. Headless dumb mode does NOT render to video memory

Direct writes to `0xB8000` (VGA text-mode framebuffer) from inside a
DOS program have **no observable effect** in dumb mode — there is no
video device, dumb mode renders the DOS screen by translating DOS
INT 21h / BIOS calls into ASCII on stdout. If you're using video-
memory writes as cheap diagnostic beacons (a common pattern), they
won't show up in `dosemu-cmd` output. Use serial-channel side
diagnostics instead (extend an RPC payload, or an extra CMD_PING
with state encoded in the payload).

### 8. dosemu2's CPU emulation downgrade message

You'll see `CONF: emulated CPU forced down to real CPU: 386` on every
boot under qemu-user. This is normal — dosemu's `$_cpu_vm = "emulated"`
restricts to 386 instructions because the DPMI host (qemu-user) can't
handle the broader instruction sets dosemu wants to JIT. Doesn't
affect functionality.

### 9. `MFS: failed to get xattrs` warnings

Hostfs mounts via `-d` print one xattr-read warning per file. Benign
— the underlying filesystem (Docker overlay or qemu-9p) doesn't
expose extended attributes. Ignore.

### 10. Drive-letter assignment under FDPP

FDPP defaults to four bundled hard drives (`C:` / `D:` / `E:` / `F:`),
all backed by image files in `~/.dosemu/drive_c/`. The first
`-d /host/path` you pass goes to **`G:`**; subsequent ones to
`H:`, `I:`, etc. Boot drive is `E:` (FDPP's `command.com`).

If you're testing redirector TSRs that map to letters > F:, double-check
`fdppconf.sys` has `lastdrive=Z` (default does) so DOS's CDS table
allocates the slots.

---

## When to break out of the toolkit

The wrappers cover the 95% case. Reach for raw `dosemu` when you
need:

- **Step debugger** → `dosemu -D+B -dumb -n -f ~/.dosemurc &`,
  then `/usr/bin/dosdebug` in another terminal. Set breakpoints with
  `bp seg:off`, single-step with `t`, dump regs/memory.
- **Two COM ports** → uncomment `$_com2 = "pts /tmp/dos-com2"` in
  `~/.dosemurc` and run a second daemon on the new symlink.
- **Custom config** → copy `dosemurc.template` to a new file, tweak,
  pass `--rc /path/to/your.rc` to `dosemu-cmd` or `dosemu -f` directly.

---

## Tests

Place toolkit smoke tests under `/workspace/tools/dosemu/tests/`. Run
manually with `bash tools/dosemu/tests/<name>.sh`. Add a new test
when a new tool lands or a new quirk is discovered.

---

## Versioning

- dosemu2: tracked from Ubuntu universe (no version pin yet — bump if
  upstream ships a regression).
- FDPP: same.
- fluxbox / xterm: same.
- The dosemurc / dosemu-vnc.rc templates live in this directory and
  are seeded into `$HOME` on first `setup.sh` run.

---

## See also

- [`/workspace/AGENT.md`](../../AGENT.md) — agent orientation across both toolkits
- [`/workspace/PROJECTS.md`](../../PROJECTS.md) — DOS project walkthrough
- [`/workspace/tools/86box/README.md`](../86box/README.md) — alternative emulator
- [`/dos/c/serdfs/todos.md`](../../../dos/c/serdfs/todos.md) — open SerialDFS issues that exposed several of the quirks above
- dosemu2 upstream: <https://github.com/dosemu2/dosemu2>
- FDPP upstream: <https://github.com/dosemu2/fdpp>
