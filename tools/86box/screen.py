#!/usr/bin/env python3
"""Capture the 86Box VNC screen and decode the VGA text-mode region to ASCII.

Strategy:
1. vncdo capture → PNG of the entire x11vnc desktop (Xvfb). The 86Box Qt window
   includes a top menu bar, optional toolbar, the emulator viewport (typically
   720x400 for VGA text mode 03h), and a status bar at the bottom.
2. Find the emulator viewport: scan for the largest contiguous black/dark
   rectangle whose width == 80*char_w and height == 25*char_h. We try common
   VGA cell sizes (8x16, 9x16, 8x14, 9x14).
3. For each character cell, sample its pixels into a small fingerprint
   (down-sampled binary grid) and look up against a pre-built table of
   codepage-437 glyphs.
4. Print 80x25 lines of ASCII. Codepage-437 graphics chars are rendered as
   reasonable Unicode equivalents for legibility.

If the framebuffer doesn't contain a recognizable text-mode region (e.g.,
graphics mode, BIOS splash), exits 2 and writes the raw PNG path to stderr
so a caller can fall back to image-to-model.

Usage:
    86box-screen [--out -|file.txt] [--png /tmp/86box.png] [--debug]

Env: BOX86_VNC_HOST/BOX86_VNC_PORT (defaults 127.0.0.1:5901)
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# Codepage 437 → Unicode mapping for printable graphics (subset).
# Most "weird" chars become "?" or their nearest visual equivalent.
CP437 = (
    " ☺☻♥♦♣♠•◘○◙♂♀♪♫☼"
    "►◄↕‼¶§▬↨↑↓→←∟↔▲▼"
    " !\"#$%&'()*+,-./"
    "0123456789:;<=>?"
    "@ABCDEFGHIJKLMNO"
    "PQRSTUVWXYZ[\\]^_"
    "`abcdefghijklmno"
    "pqrstuvwxyz{|}~⌂"
    "ÇüéâäàåçêëèïîìÄÅ"
    "ÉæÆôöòûùÿÖÜ¢£¥₧ƒ"
    "áíóúñÑªº¿⌐¬½¼¡«»"
    "░▒▓│┤╡╢╖╕╣║╗╝╜╛┐"
    "└┴┬├─┼╞╟╚╔╩╦╠═╬╧"
    "╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀"
    "αßΓπΣσµτΦΘΩδ∞φε∩"
    "≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ "
)


def vnc_capture(out_png: str) -> None:
    """Take a VNC snapshot via vncdotool."""
    host = os.environ.get("BOX86_VNC_HOST", "127.0.0.1")
    port = os.environ.get("BOX86_VNC_PORT", "5901")
    vnc = shutil.which("vncdo") or os.path.expanduser("~/.local/bin/vncdo")
    if not Path(vnc).exists():
        sys.exit("vncdo not found; install vncdotool")
    subprocess.run(
        [vnc, "-s", f"{host}::{port}", "capture", out_png],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def find_text_region(img):
    """Find the 80×25 character grid in the screenshot.

    Returns (x0, y0, char_w, char_h) or None.

    Approach: scan candidate cell sizes (8x16, 9x16, 8x14, 9x14). For each,
    look for an 80×25 region whose total dimensions match a horizontal
    span starting from a likely viewport origin (just below the toolbar).
    The 86Box window in our setup centers the emulator at roughly the
    top-left, with the menu bar consuming ~30 px and the toolbar ~30 px more.
    """
    from PIL import Image
    px = img.load()
    w, h = img.size

    # Common VGA text-mode cell sizes
    candidates = [(8, 16), (9, 16), (8, 14), (9, 14)]

    # Search horizontally between x in [0, 32], vertically between y in
    # [40, 100] (just below the typical 86Box menu+toolbar) for a region
    # whose contents look text-like (mostly dark, with bright glyph pixels).
    for cw, ch in candidates:
        target_w = 80 * cw
        target_h = 25 * ch
        if target_w > w or target_h > h:
            continue
        # Try a few origin candidates
        for y0 in range(40, 110, 2):
            for x0 in range(0, 24, 2):
                if x0 + target_w > w or y0 + target_h > h:
                    continue
                # Sample border luminance; text regions have a black bg
                # with sparse white-ish pixels
                bg_score = 0
                fg_score = 0
                for sx in range(x0, x0 + target_w, 16):
                    for sy in range(y0, y0 + target_h, 8):
                        r, g, b = px[sx, sy][:3]
                        lum = (r + g + b) // 3
                        if lum < 60:
                            bg_score += 1
                        elif lum > 160:
                            fg_score += 1
                # Heuristic: heavily black background, some bright pixels
                if bg_score > 50 and fg_score > 5:
                    return (x0, y0, cw, ch)
    return None


def cell_fingerprint(img, x: int, y: int, cw: int, ch: int) -> int:
    """Hash a single character cell to a 64-bit fingerprint.

    Down-sample the cell to an 8×8 binary grid (luminance threshold) and
    pack into 64 bits. Robust to anti-aliasing and minor scaling.
    """
    px = img.load()
    bits = 0
    sx_step = max(1, cw // 8)
    sy_step = max(1, ch // 8)
    bit = 1
    for j in range(8):
        sy = y + min(ch - 1, j * sy_step)
        for i in range(8):
            sx = x + min(cw - 1, i * sx_step)
            r, g, b = px[sx, sy][:3]
            if (r + g + b) // 3 > 80:
                bits |= bit
            bit <<= 1
    return bits


# Pre-built fingerprint table: built lazily from the running 86Box display
# the first time we see a known anchor (the prompt "C:\>"). For now, we
# implement a simpler approach: assume the emulator is using the standard
# VGA 8x16 BIOS font and use a built-in glyph table.
#
# To keep this file self-contained, the glyph table is shipped in fontmap.py
# as a precomputed dict[fingerprint -> char].
def load_fontmap():
    here = Path(__file__).resolve().parent
    fm_path = here / "fontmap.py"
    if not fm_path.exists():
        return None
    ns: dict = {}
    exec(fm_path.read_text(), ns)
    return ns.get("FINGERPRINTS")


def decode_text(img, region) -> str:
    x0, y0, cw, ch = region
    fmap = load_fontmap()
    out_lines: list[str] = []
    for row in range(25):
        line_chars: list[str] = []
        for col in range(80):
            cx = x0 + col * cw
            cy = y0 + row * ch
            fp = cell_fingerprint(img, cx, cy, cw, ch)
            if fmap and fp in fmap:
                line_chars.append(fmap[fp])
            elif fp == 0:
                line_chars.append(" ")
            else:
                # Unknown glyph — emit '?' but keep alignment
                line_chars.append("?")
        out_lines.append("".join(line_chars).rstrip())
    return "\n".join(out_lines)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out", default="-",
                   help="output text file (default: stdout)")
    p.add_argument("--png", default=None,
                   help="keep a copy of the raw PNG at this path")
    p.add_argument("--debug", action="store_true",
                   help="print region detection details to stderr")
    args = p.parse_args()

    try:
        from PIL import Image
    except ImportError:
        sys.exit("Pillow not installed (apt: python3-pil, or pip: Pillow)")

    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
        png_path = args.png or f.name
    try:
        vnc_capture(png_path)
        img = Image.open(png_path).convert("RGB")
        region = find_text_region(img)
        if args.debug:
            print(f"region: {region}", file=sys.stderr)
        if not region:
            print(f"no text region detected; raw PNG at {png_path}",
                  file=sys.stderr)
            return 2
        text = decode_text(img, region)
    finally:
        if not args.png and Path(png_path).exists():
            try: os.unlink(png_path)
            except OSError: pass

    if args.out == "-":
        sys.stdout.write(text + "\n")
    else:
        Path(args.out).write_text(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
