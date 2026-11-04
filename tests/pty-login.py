#!/usr/bin/env python3
"""Start an interactive shell on a fresh pty whose input was queued first.

ds-test uses this to check how the `ds init` auto-attach probe treats
typeahead that is already in the terminal when the shell starts. The input
is written to the pty master before the shell is forked, so there is no race
against shell startup (unlike `script` or `pty.fork()` followed by a write).

Usage: pty-login.py [--timeout SECS] INPUT -- SHELL [ARG...]

INPUT is written to the pty verbatim and must fit its input queue (a few KB;
larger input is an error, not a hang). The child runs with exactly the caller's
environment. The shell's pty output goes to stdout. Exits with the shell's
exit status, or 124 after killing a shell that is still running at the
deadline (its pty output then also goes to stderr).
"""

from __future__ import annotations

import argparse
import fcntl
import os
import select
import signal
import sys
import termios
import time

TIMEOUT_EXIT = 124


def _become_terminal(slave: int) -> None:
    """Make `slave` the child's controlling terminal and stdio, as a login has."""
    if hasattr(os, "login_tty"):
        os.login_tty(slave)
        return
    # Python < 3.11 lacks login_tty; this is its documented equivalent.
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    for fd in (0, 1, 2):
        os.dup2(slave, fd)
    if slave > 2:
        os.close(slave)


def spawn(argv: list[str], queued: bytes) -> tuple[int, int]:
    """Queue `queued` on a new pty, then fork `argv` onto it.

    Returns the child pid and the pty master fd.
    """
    master, slave = os.openpty()
    if queued:
        # Nothing reads the pty yet, so a blocking write of more than its
        # input queue holds would never return.
        os.set_blocking(master, False)
        written = os.write(master, queued)
        if written != len(queued):
            raise BlockingIOError(f"took {written} of {len(queued)} bytes")
        os.set_blocking(master, True)
    pid = os.fork()
    if pid == 0:
        try:
            os.close(master)
            _become_terminal(slave)
            os.execv(argv[0], argv)
        finally:
            os._exit(127)
    os.close(slave)
    return pid, master


def _drain(master: int) -> bytes:
    """Read whatever the exited child left in the pty, without blocking."""
    output = bytearray()
    while select.select([master], [], [], 0)[0]:
        try:
            chunk = os.read(master, 4096)
        except OSError:
            break
        if not chunk:
            break
        output += chunk
    return bytes(output)


def wait(pid: int, master: int, timeout: float) -> tuple[int | None, bytes]:
    """Drain pty output until the child exits or the deadline passes.

    Returns the child's exit code (None on timeout) and its pty output.
    """
    deadline = time.monotonic() + timeout
    output = bytearray()
    master_open = True
    while time.monotonic() < deadline:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            if master_open:
                output += _drain(master)
            return os.waitstatus_to_exitcode(status), bytes(output)
        if not master_open:
            # The child closed the pty but has not been reaped yet.
            select.select([], [], [], 0.01)
            continue
        ready, _, _ = select.select([master], [], [], 0.05)
        if ready:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                # Linux reports EIO once every slave descriptor is closed.
                chunk = b""
            if chunk:
                output += chunk
            else:
                master_open = False
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    return None, bytes(output)


def main() -> int:
    """Parse arguments, run the shell, and map its result to an exit status."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("input")
    parser.add_argument("argv", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    argv = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
    if not argv:
        parser.error("missing shell command after --")

    try:
        pid, master = spawn(argv, args.input.encode())
    except BlockingIOError as exc:
        sys.stderr.write(f"pty-login: input does not fit the pty input queue: {exc}\n")
        return 2
    try:
        code, output = wait(pid, master, args.timeout)
    finally:
        os.close(master)
    sys.stdout.write(output.decode(errors="replace"))
    if code is None:
        sys.stderr.write(f"pty-login: {argv[0]} still running after {args.timeout}s; output:\n")
        sys.stderr.write(output.decode(errors="replace") + "\n")
        return TIMEOUT_EXIT
    return code


if __name__ == "__main__":
    sys.exit(main())
