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
└── test.sh             ← end-to-end smoke: build → install → run
```

## Run it

```bash
bash /workspace/examples/hello/test.sh
```

Expected output (last few lines):

```
=== hello example: build → install → test ===
  PASS: HELLO.EXE built
  PASS: HELLO.EXE in dos.img
  PASS: DOS prints greeting
  PASS: DOS echoes argv[1]=alpha

Results: 4 passed, 0 failed
```

Total runtime ~40 s (mostly the 86Box cold boot).

## What it demonstrates

1. **Cross-compiling DOS .EXEs on Linux** with Open Watcom:
   ```bash
   wcl -bt=dos -ms -0 -os -fe=build/HELLO.EXE src/hello.c
   ```
2. **Installing artifacts into the DOS image** with the toolkit:
   ```bash
   86box-run stop                             # required: no concurrent writes
   86box-install-dos --to 'C:\HELLO' build/HELLO.EXE
   ```
3. **Running a DOS program and capturing its stdout** via `86box-cmd`:
   ```bash
   86box-cmd 'C:\HELLO\HELLO.EXE alpha beta'
   # → "Hello from DOS!\nargc=3\nargv[1]=alpha\nargv[2]=beta\n"
   ```
4. **Asserting on captured output** in a portable shell test (the
   `check()` helper pattern is the same one SerialDFS's `tests/e2e/`
   uses).

## When you've outgrown this

Read [`PROJECTS.md`](../../PROJECTS.md) for:
- Multi-step BAT patterns (TSR install + ops + unload in one boot)
- COM1 serial bridge usage (when your DOS program talks to a Linux daemon)
- Fault-injection test recipe
- DOS-specific pitfalls that have already cost time elsewhere

For a heavyweight reference (a serial-driven INT 2Fh redirector with
~13 KB resident TSR, daemon, frame protocol), see `/dos/c/serdfs/`
inside this container — it's the project the toolkit was built for.
