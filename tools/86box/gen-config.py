#!/usr/bin/env python3
"""Generate an 86Box config file for a project's VM.

Default machine is `ninja` (i486DX2/66 + S3 Stealth64v PCI + IDE PCI),
matching the VM the bundled MS-DOS 6.22 template VHD was created on.

Usage:
    gen-config.py --out 86box.cfg --vhd dos.img \
        [--machine ninja] [--cpu i486dx2] [--mhz 66] \
        [--mem-mb 8] [--gfx stealth64v_pci] \
        [--serial1-passthrough]

`--serial1-passthrough` enables 86Box's host-PTY passthrough on COM1.
86Box opens an internal openpty() pair and writes "Slave side is /dev/pts/N"
to its log; `86box-bridge` discovers the path and exposes a stable
symlink at /tmp/linux-com1. (The legacy `--serial1-tcp PORT` flag still
works as an alias but is misleading: 86Box v5.3 b8200 ignores
serial*_passthrough_mode = tcp_server in this build and falls back to
PTY mode regardless.)

Override any [Section]:key via --set "Section:key=value" (repeatable).
"""
from __future__ import annotations
import argparse
import sys
from pathlib import Path

# Default config sections, keyed by section name. Order is preserved.
# This matches the working ninja machine + the template VHD's IDE channel.
DEFAULTS: dict[str, dict[str, str]] = {
    "General": {
        "vid_renderer": "qt_software",
    },
    "Machine": {
        "machine": "ninja",
        "cpu_family": "i486dx2",
        "cpu_speed": "66666666",
        "cpu_multi": "2",
        "cpu_use_dynarec": "0",
        "fpu_type": "internal",
        "mem_size": "8192",
        "time_sync": "local",
    },
    "Video": {
        "gfxcard": "stealth64v_pci",
    },
    "Input devices": {
        "keyboard_type": "keyboard_at",
        "mouse_type": "none",
    },
    "Sound": {
        "sndcard": "none",
    },
    "Network": {
        "net_01_link": "0",
    },
    "Storage controllers": {
        # Floppy controller is required so 86box-cmd can hand commands to DOS
        # via a virtual A: drive image (AGENT.IMG).
        "fdc": "internal",
        "hdc_1": "ide_pci",
    },
    "Hard disks": {
        # Default to a raw flat image (.img). Fixed-format VHD also works.
        # Dynamic VHD does NOT round-trip cleanly through mtools/qemu-img
        # for AUTOEXEC.BAT edits — qemu-img rewrites the CHS geometry,
        # which breaks DOS boot on the next start. See entrypoint.sh.
        "hdd_01_fn": "dos.img",
        "hdd_01_ide_channel": "0:0",
        # Sectors-per-track, heads, cylinders. This must match the values the
        # template was installed with; changing it breaks DOS boot.
        "hdd_01_parameters": "62, 4, 1930, 0, ide",
        "hdd_01_speed": "BF12A011",
        "hdd_01_vhd_blocksize": "4096",
    },
    "Floppy and CD-ROM drives": {
        "fdd_01_type": "35_2hd",
        "fdd_02_type": "525_2hd",
    },
    "Ports (COM & LPT)": {
        "serial1_enabled": "1",
    },
}


def parse_set(items: list[str]) -> list[tuple[str, str, str]]:
    out: list[tuple[str, str, str]] = []
    for s in items:
        if "=" not in s or ":" not in s.split("=", 1)[0]:
            sys.exit(f"--set must be Section:key=value, got: {s!r}")
        sk, val = s.split("=", 1)
        section, key = sk.split(":", 1)
        out.append((section.strip(), key.strip(), val.strip()))
    return out


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out", default="86box.cfg",
                   help="output path (default: 86box.cfg)")
    p.add_argument("--vhd", default="dos.vhd",
                   help="HD image filename (relative to vm-path)")
    p.add_argument("--machine", default=None,
                   help="86Box machine type (default: ninja)")
    p.add_argument("--cpu", default=None,
                   help="cpu_family (default: i486dx2)")
    p.add_argument("--mhz", type=int, default=None,
                   help="CPU clock in MHz (default: 66)")
    p.add_argument("--mem-mb", type=int, default=None,
                   help="memory in MB (default: 8)")
    p.add_argument("--gfx", default=None,
                   help="video card (default: stealth64v_pci)")
    p.add_argument("--serial1-passthrough", action="store_true",
                   help="enable host PTY passthrough on COM1 — 86Box opens "
                        "an internal PTY pair and `86box-bridge` exposes "
                        "the slave at /tmp/linux-com1")
    p.add_argument("--serial2-passthrough", action="store_true",
                   help="enable host PTY passthrough on COM2 — used by "
                        "`86box-pcmd` for the persistent-DOS REPL channel "
                        "(see tools/86box/dos/pcmdd.c). Coexists with "
                        "--serial1-passthrough so SerialDFS can keep COM1.")
    p.add_argument("--serial1-tcp", type=int, default=0,
                   help="LEGACY ALIAS for --serial1-passthrough. The PORT "
                        "argument is recorded in cfg but ignored by 86Box "
                        "v5.3 b8200 — it falls back to PTY mode anyway.")
    p.add_argument("--set", action="append", default=[], metavar="SECTION:KEY=VAL",
                   help="override or add a config entry (repeatable)")
    args = p.parse_args()

    cfg: dict[str, dict[str, str]] = {s: dict(v) for s, v in DEFAULTS.items()}

    # Apply CLI overrides for common knobs.
    if args.machine:
        cfg["Machine"]["machine"] = args.machine
    if args.cpu:
        cfg["Machine"]["cpu_family"] = args.cpu
    if args.mhz is not None:
        cfg["Machine"]["cpu_speed"] = str(args.mhz * 1_000_000)
    if args.mem_mb is not None:
        cfg["Machine"]["mem_size"] = str(args.mem_mb * 1024)
    if args.gfx:
        cfg["Video"]["gfxcard"] = args.gfx
    if args.vhd:
        cfg["Hard disks"]["hdd_01_fn"] = args.vhd

    # Serial passthrough — 86Box opens a host openpty() pair when
    # serial%d_passthrough_enabled = 1. The slave path appears in the
    # 86Box log as "serial_passthrough: Slave side is /dev/pts/N".
    # Discovered + raw-termios bridged by `86box-bridge`.
    if args.serial1_passthrough or args.serial1_tcp:
        com = cfg["Ports (COM & LPT)"]
        com["serial1_enabled"] = "1"
        com["serial1_passthrough_enabled"] = "1"
        if args.serial1_tcp:
            # Record what the user asked for so the legacy flag is at least
            # visible; 86Box itself ignores tcp_server in this build.
            com["serial1_passthrough_mode"] = "tcp_server"
            com["serial1_passthrough_data_host"] = "0.0.0.0"
            com["serial1_passthrough_data_port"] = str(args.serial1_tcp)
    if args.serial2_passthrough:
        com = cfg["Ports (COM & LPT)"]
        com["serial2_enabled"] = "1"
        com["serial2_passthrough_enabled"] = "1"

    # Apply --set last so they win.
    for section, key, val in parse_set(args.set):
        cfg.setdefault(section, {})[key] = val

    out_lines: list[str] = []
    for section, kv in cfg.items():
        out_lines.append(f"[{section}]")
        for k, v in kv.items():
            out_lines.append(f"{k} = {v}")
        out_lines.append("")
    Path(args.out).write_text("\n".join(out_lines))
    print(f"wrote {args.out} ({sum(len(v) for v in cfg.values())} keys)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
