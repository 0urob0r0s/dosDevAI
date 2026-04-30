# `hello/` — minimal DOS reference example

The smallest possible DOS program that exercises the full sandbox loop.
Use as a template / sanity-check / copy-paste starting point for your
own DOS project.

```
hello/
├── README.md           ← you are here
├── makefile            ← Open Watcom build (`wmake`)
├── src/
│   └── hello.c         ← prints a greeting + echoes argv
├── build/              ← `wmake` output (gitignored)
└── test.sh             ← end-to-end smoke (dosemu2 fast path; 86Box optional)
```

## Run it

```bash
bash /workspace/examples/hello/test.sh
```

Expected output (last few lines):

```
=== hello example (dosemu2 path): build → run ===
  PASS: HELLO.EXE built
  PASS: DOS prints greeting (dosemu2)
  PASS: DOS echoes argv[1]=alpha (dosemu2)

Results: 3 passed, 0 failed
```

Total runtime ~10 s on the dosemu2 path. Set
`EXAMPLE_HELLO_INCLUDE_86BOX=1` to also exercise the slower 86Box path:

```bash
EXAMPLE_HELLO_INCLUDE_86BOX=1 bash /workspace/examples/hello/test.sh
```

That adds ~40 s for the 86Box cold boot.

## What it demonstrates

1. **Cross-compiling DOS .EXEs on Linux** with Open Watcom:
   ```bash
   wcl -bt=dos -ms -0 -os -fe=build/HELLO.EXE src/hello.c
   ```

2. **Running a DOS program via dosemu2 hostfs mount** — no install step:
   ```bash
   dosemu-cmd --mount /workspace/examples/hello/build \
              "G:" "G:\\HELLO.EXE alpha beta"
   # → "Hello from DOS!\nargc=3\nargv[1]=alpha\nargv[2]=beta\n"
   ```
   The `--mount` flag exposes the host build directory as DOS drive
   `G:` (next free letter after FDPP's bundled C:/D:/E:/F:). The
   freshly-built `.EXE` is reachable immediately — no `mcopy`, no
   stop-the-emulator step.

3. **(Optional) Installing into a 86Box dos.img and running** — for
   when you specifically need real-BIOS / real-IDE behavior:
   ```bash
   86box-run stop
   86box-install-dos --to 'C:\HELLO' build/HELLO.EXE
   86box-cmd 'C:\HELLO\HELLO.EXE alpha beta'
   ```

4. **Asserting on captured output** in a portable shell test (the
   `check()` helper pattern is the same one SerialDFS's `tests/e2e/`
   uses).

## When you've outgrown this

Read [`PROJECTS.md`](../../PROJECTS.md) for:
- Multi-step session patterns (TSR install + ops + unload in one boot)
- COM1 serial usage (when your DOS program talks to a Linux daemon —
  raw PTY on dosemu2, bridge on 86Box)
- Fault-injection test recipe
- DOS-specific pitfalls that have already cost time elsewhere

For a heavyweight reference (a serial-driven INT 2Fh redirector with
~13 KB resident TSR, daemon, frame protocol), see `/dos/c/serdfs/`
inside this container — it's the project the toolkits were built
for. Open issues and hand-off notes at `/dos/c/serdfs/todos.md`.

For toolkit-internal reference docs:
- [`/workspace/tools/dosemu/README.md`](../../tools/dosemu/README.md) — primary emulator, dev quirks, debugger usage
- [`/workspace/tools/86box/README.md`](../../tools/86box/README.md) — alternative emulator
