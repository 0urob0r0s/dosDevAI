#!/usr/bin/env python3
"""86Box serial-PTY bridge with raw-mode pass-through.

86Box's serial passthrough creates an internal PTY pair via openpty() and
writes the slave path to its log:

    serial_passthrough: Slave side is /dev/pts/N

Opening that slave path directly with pyserial *almost* works, except that
the slave's default termios still has line-discipline cooking enabled
(IXON/IXOFF software flow control, OPOST, ICANON). Frame bytes that happen
to land on 0x11 (XON) / 0x13 (XOFF) or 0x0D / 0x0A trigger silent
mangling, breaking any binary protocol.

This bridge:
  * polls 86Box's log until the slave path appears
  * opens the slave with O_RDWR | O_NOCTTY and forces raw termios on it
  * creates a *new* PTY pair we control, forces raw on its master,
    and symlinks `/tmp/linux-com1` (configurable) → the new slave so
    application code keeps using a stable filename across 86Box restarts
  * shuttles raw bytes both directions
  * throttles host→86Box writes to ~1 ms/byte (line rate at 9600 baud).
    Without this, 86Box's UART RX register overflows under burst writes.

Called as `86box-bridge` (one-shot, daemonised by default).

Usage examples:
    86box-bridge              # background, waits for symlink, exits
    86box-bridge --stop       # kill the running bridge
    86box-bridge --status
    86box-bridge --foreground # stay in foreground, useful with --trace

Env: BOX86_LOG (/tmp/86box/86box.log), BOX86_BRIDGE_LINK (/tmp/linux-com1).
"""
from __future__ import annotations

import argparse
import os
import pty
import re
import select
import signal
import subprocess
import sys
import termios
import time
import tty


DEFAULT_LOG = '/tmp/86box/86box.log'
DEFAULT_LINK = '/tmp/linux-com1'
DEFAULT_PIDFILE = '/tmp/86box/bridge.pid'
DEFAULT_OUTLOG = '/tmp/86box/bridge.log'


# ---------- termios + shuttle ------------------------------------------------

def force_raw(fd: int) -> None:
    """8-bit raw, no flow control, no line discipline cooking."""
    tty.setraw(fd)
    a = termios.tcgetattr(fd)
    a[0] &= ~(termios.IXON | termios.IXOFF | termios.IXANY |
              termios.ICRNL | termios.INLCR | termios.IGNCR | termios.ISTRIP)
    a[1] &= ~termios.OPOST
    a[3] &= ~(termios.ECHO | termios.ECHOE | termios.ECHOK | termios.ECHONL |
              termios.ICANON | termios.ISIG | termios.IEXTEN)
    termios.tcsetattr(fd, termios.TCSANOW, a)


def wait_for_slave(log_path: str, timeout_s: float, port: int = 1) -> str:
    """Poll the 86Box log for the Nth 'Slave side is /dev/pts/N' line.

    86Box logs one such line per passthrough-enabled serial port, in the
    order it initialises them (serial1 first, then serial2, ...). `port=1`
    returns the first match; `port=2` returns the second, etc.
    """
    pat = re.compile(r'serial_passthrough:\s+Slave side is\s+(\S+)')
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            with open(log_path, 'r', errors='replace') as f:
                text = f.read()
        except FileNotFoundError:
            text = ''
        matches = pat.findall(text)
        if len(matches) >= port:
            slave = matches[port - 1]
            if os.path.exists(slave):
                return slave
        time.sleep(0.3)
    raise TimeoutError(
        f"86Box serial{port} slave PTY not found in {log_path} after "
        f"{timeout_s}s (is 86Box running? does its 86box.cfg have "
        f"serial{port}_passthrough_enabled=1?)")


def shuttle(box_fd: int, mid_master_fd: int, *, trace: bool,
            tx_byte_delay_s: float,
            eof_retry_s: float = 0.05,
            eof_max_consecutive: int = 12000) -> None:
    """Shuttle raw bytes between 86Box slave fd and intermediate master fd.

    * tx_byte_delay_s throttles host→86Box writes to one byte at a time,
      sleeping the given seconds between bytes. 86Box pushes host writes
      straight into the UART RX without respecting baud, so bursts overrun.
    * Transient EOF (86Box briefly closes its master during BIOS init or
      between UART operations) is treated as transient and retried;
      sustained EOF (eof_max_consecutive ≈ 10 min) means 86Box really
      is gone, so we exit.
    """
    eof_count = 0
    while True:
        try:
            ready, _, _ = select.select([box_fd, mid_master_fd], [], [], 1.0)
        except (OSError, ValueError):
            return
        any_data = False
        for r in ready:
            try:
                data = os.read(r, 512)
            except OSError:
                return
            if not data:
                continue
            any_data = True
            other = mid_master_fd if r == box_fd else box_fd
            if trace:
                tag = '86Box->host' if r == box_fd else 'host->86Box'
                print(f'  [{tag}] {len(data)} B: {data.hex()}', flush=True)
            try:
                if r == mid_master_fd and tx_byte_delay_s > 0:
                    for b in data:
                        os.write(other, bytes([b]))
                        time.sleep(tx_byte_delay_s)
                else:
                    os.write(other, data)
            except OSError:
                return
        if ready and not any_data:
            eof_count += 1
            if eof_count >= eof_max_consecutive:
                return
            time.sleep(eof_retry_s)
        else:
            eof_count = 0


# ---------- subcommands ------------------------------------------------------

def _pid_alive(pidfile: str) -> int | None:
    try:
        pid = int(open(pidfile).read().strip())
    except (OSError, ValueError):
        return None
    try:
        os.kill(pid, 0)
        return pid
    except OSError:
        return None


def cmd_status(args) -> int:
    pid = _pid_alive(args.pidfile)
    if pid:
        link = os.readlink(args.link) if os.path.islink(args.link) else '?'
        print(f'86box-bridge: up (PID {pid}, {args.link} → {link})')
        return 0
    print('86box-bridge: down')
    return 0


def cmd_stop(args) -> int:
    pid = _pid_alive(args.pidfile)
    if pid:
        os.kill(pid, signal.SIGTERM)
        for _ in range(20):
            if _pid_alive(args.pidfile) is None:
                break
            time.sleep(0.1)
        else:
            os.kill(pid, signal.SIGKILL)
    try:
        os.unlink(args.pidfile)
    except FileNotFoundError:
        pass
    try:
        os.unlink(args.link)
    except FileNotFoundError:
        pass
    print('86box-bridge: stopped')
    return 0


def cmd_foreground(args) -> int:
    """Run the bridge in the current process. Blocks until shuttle ends."""
    print(f'waiting for 86Box serial{args.port} slave path in {args.log}...',
          flush=True)
    try:
        slave_path = wait_for_slave(args.log, args.connect_timeout, args.port)
    except TimeoutError as e:
        print(f'ERROR: {e}', file=sys.stderr, flush=True)
        return 1
    print(f'found 86Box slave: {slave_path}', flush=True)

    box_fd = os.open(slave_path, os.O_RDWR | os.O_NOCTTY)
    force_raw(box_fd)

    mid_master_fd, mid_slave_fd = pty.openpty()
    mid_slave_path = os.ttyname(mid_slave_fd)
    force_raw(mid_master_fd)
    force_raw(mid_slave_fd)
    # Keep mid_slave_fd open: if we close it and the daemon is between
    # opens, the slave node disappears and the symlink becomes dangling.

    try:
        os.unlink(args.link)
    except FileNotFoundError:
        pass
    os.symlink(mid_slave_path, args.link)
    print(f'PTY slave: {mid_slave_path} → {args.link}', flush=True)
    print(f'shuttle: 86Box {slave_path} <-> {mid_slave_path}', flush=True)

    # Write the pid file once we're ready so a parent `start` can poll it.
    try:
        os.makedirs(os.path.dirname(args.pidfile), exist_ok=True)
        with open(args.pidfile, 'w') as f:
            f.write(str(os.getpid()))
    except OSError:
        pass

    try:
        shuttle(box_fd, mid_master_fd, trace=args.trace,
                tx_byte_delay_s=args.tx_byte_delay_ms / 1000.0)
    finally:
        try:
            os.unlink(args.link)
        except OSError:
            pass
        try:
            os.unlink(args.pidfile)
        except OSError:
            pass
        os.close(box_fd)
        os.close(mid_master_fd)
        os.close(mid_slave_fd)

    print('bridge: shuttle ended (86Box closed PTY?)', flush=True)
    return 0


def cmd_start(args) -> int:
    """Spawn the bridge in the background. Idempotent if already healthy."""
    pid = _pid_alive(args.pidfile)
    if pid and os.path.islink(args.link) and os.path.exists(args.link):
        link = os.readlink(args.link)
        print(f'86box-bridge already running (PID {pid}, '
              f'{args.link} → {link})')
        return 0

    # Either no bridge, or it's in a degraded state (process dead, link
    # dangling, or 86Box was killed and the shuttle is on its way out).
    # Stop any leftover and start fresh.
    if pid:
        cmd_stop(args)

    # Drop any stale symlink before launching, so the wait below doesn't
    # accept a dangling link from a previous run.
    try:
        os.unlink(args.link)
    except FileNotFoundError:
        pass

    os.makedirs(os.path.dirname(args.outlog), exist_ok=True)
    # Global flags (--log, --link, ...) must come BEFORE the subcommand
    # name with argparse's subparsers; --trace too.
    cmd = [sys.executable, os.path.realpath(__file__),
           '--log', args.log,
           '--link', args.link,
           '--port', str(args.port),
           '--connect-timeout', str(args.connect_timeout),
           '--tx-byte-delay-ms', str(args.tx_byte_delay_ms),
           '--pidfile', args.pidfile,
           '--outlog', args.outlog]
    if args.trace:
        cmd.append('--trace')
    cmd.append('foreground')
    out = open(args.outlog, 'a')
    subprocess.Popen(cmd, stdout=out, stderr=out, stdin=subprocess.DEVNULL,
                     start_new_session=True)

    # Wait up to 60 s for /tmp/linux-com1 to point at a live PTY.
    deadline = time.monotonic() + 60.0
    while time.monotonic() < deadline:
        if os.path.exists(args.link):  # follows the symlink
            link = os.readlink(args.link) if os.path.islink(args.link) else '?'
            print(f'86box-bridge: ready ({args.link} → {link})')
            return 0
        time.sleep(0.3)
    print(f'ERROR: bridge did not create {args.link} after 60 s '
          f'(see {args.outlog})', file=sys.stderr)
    return 1


# ---------- dispatch ---------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(description='86Box serial PTY bridge',
                                allow_abbrev=False)
    p.add_argument('--log',     default=os.environ.get('BOX86_LOG', DEFAULT_LOG))
    p.add_argument('--link',    default=os.environ.get('BOX86_BRIDGE_LINK', DEFAULT_LINK))
    p.add_argument('--port',    type=int,
                   default=int(os.environ.get('BOX86_BRIDGE_PORT', 1)),
                   help='which serial port (Nth Slave-side-is log line) '
                        'to bridge. 1 = COM1 (default), 2 = COM2.')
    p.add_argument('--pidfile', default=DEFAULT_PIDFILE)
    p.add_argument('--outlog',  default=DEFAULT_OUTLOG)
    p.add_argument('--connect-timeout', type=float,
                   default=float(os.environ.get('BOX86_BRIDGE_CONNECT_TIMEOUT', 90.0)),
                   help='seconds to wait for 86Box slave path '
                        '(default 90, env BOX86_BRIDGE_CONNECT_TIMEOUT)')
    p.add_argument('--tx-byte-delay-ms', type=float,
                   default=float(os.environ.get('BOX86_BRIDGE_TX_DELAY_MS', 4.0)),
                   help='ms between bytes on host→86Box writes '
                        '(default 4 ms ≈ 2400 baud effective; env '
                        'BOX86_BRIDGE_TX_DELAY_MS). 86Box\'s emulated UART '
                        'under QEMU-user on Apple Silicon drops bytes on '
                        'sustained bursts faster than this; sustained '
                        'transfers (16+ chunks) need this pacing for '
                        'clean reads. Raise if you still see TSR retries; '
                        'lower (down to ~1.04 ms = 9600 baud theoretical) '
                        'only for short interactions.')
    p.add_argument('--trace', action='store_true',
                   help='hex-dump every chunk through the bridge')
    sub = p.add_subparsers(dest='action')
    sub.add_parser('start',      help='spawn in background (default)')
    sub.add_parser('stop',       help='kill the running bridge')
    sub.add_parser('status',     help='show pid / link state')
    sub.add_parser('foreground', help='run shuttle in this process')
    args = p.parse_args()

    action = args.action or 'start'
    return {
        'start':      cmd_start,
        'stop':       cmd_stop,
        'status':     cmd_status,
        'foreground': cmd_foreground,
    }[action](args)


if __name__ == '__main__':
    sys.exit(main())
