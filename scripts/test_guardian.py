#!/usr/bin/env python3
"""Disposable transport tests. Never invokes Mole or scans/deletes user files.

Usage: python3 scripts/test_guardian.py /absolute/path/to/MoPanelGuardian
The caller builds/signs the tested executable; this script never overwrites it.
"""
import os
import fcntl
import pathlib
import select
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest

GUARDIAN = pathlib.Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else pathlib.Path(".guardian-test").resolve()


def frame(kind, data=b""):
    return kind.encode("ascii") + struct.pack(">I", len(data)) + data


def launch(args, *, pty=False, timeout=5000, cooperative=False):
    return subprocess.Popen([str(GUARDIAN), "--pty" if pty else "--capture",
                             "--timeout-ms", str(timeout), *(["--cooperative"] if cooperative else []), "--", *args],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def collect(process, timeout=6):
    # Keep stdin open until the command exits: it is the parent's lifeline.
    deadline = time.monotonic() + timeout
    output = bytearray()
    errors = bytearray()
    readers = [process.stdout, process.stderr]
    while readers and time.monotonic() < deadline:
        ready, _, _ = select.select(readers, [], [], 0.05)
        for stream in ready:
            data = os.read(stream.fileno(), 65536)
            if not data:
                readers.remove(stream)
            elif stream is process.stdout:
                output.extend(data)
            else:
                errors.extend(data)
    if readers:
        process.kill()
        raise AssertionError("Guardian did not close its output pipes")
    code = process.wait(timeout=2)
    for stream in (process.stdin, process.stdout, process.stderr):
        if stream and not stream.closed:
            stream.close()
    return code, bytes(output), bytes(errors)


def read_until(process, token, timeout=4):
    deadline = time.monotonic() + timeout
    result = bytearray()
    while token not in result and time.monotonic() < deadline:
        if select.select([process.stdout], [], [], 0.05)[0]:
            value = os.read(process.stdout.fileno(), 65536)
            if not value:
                break
            result.extend(value)
    if token not in result:
        raise AssertionError(f"Missing fixture output token {token!r}: {result!r}")
    return bytes(result)


def active(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    stat = pathlib.Path(f"/proc/{pid}/stat")
    if stat.exists() and stat.read_text().rpartition(") ")[2].startswith("Z"):
        return False
    return True


class GuardianTests(unittest.TestCase):
    def test_exact_arguments_and_special_names(self):
        args = ["two words", "繁體中文", "$(touch SHOULD_NOT_EXIST)", "; exit 92", "line\nbreak", "'\"`"]
        p = launch([sys.executable, "-c", "import sys;sys.stdout.buffer.write(b'\\0'.join(x.encode() for x in sys.argv[1:]))", *args])
        code, out, err = collect(p)
        self.assertEqual(code, 0, err)
        self.assertEqual(out.split(b"\0"), [s.encode() for s in args])
        self.assertFalse(pathlib.Path("SHOULD_NOT_EXIST").exists())

    def test_exit_status_and_stderr(self):
        p = launch([sys.executable, "-c", "import sys;sys.stderr.write('fixture error');sys.exit(23)"])
        code, out, err = collect(p)
        self.assertEqual((code, out, err), (23, b"", b"fixture error"))

    def test_executable_not_found(self):
        code, _, err = collect(launch(["/mopanel-fixture-does-not-exist"]))
        self.assertEqual(code, 127)
        self.assertIn(b"exec failed", err)

    def test_permission_denied(self):
        with tempfile.TemporaryDirectory(prefix="mopanel-test-") as root:
            file = pathlib.Path(root, "not executable")
            file.write_text("fixture")
            code, _, _ = collect(launch([str(file)]))
            self.assertEqual(code, 126)

    def test_timeout_kills_ignoring_child(self):
        began = time.monotonic()
        p = launch([sys.executable, "-c", "import os,signal,time;signal.signal(signal.SIGINT,signal.SIG_IGN);print(os.getpid(),flush=True);time.sleep(60)"], timeout=150)
        code, out, _ = collect(p)
        self.assertEqual(code, 124)
        self.assertLess(time.monotonic() - began, 4)
        self.assertFalse(active(int(out)))

    def test_cancel_and_descendant_cleanup(self):
        script = "import subprocess,time; p=subprocess.Popen(['/bin/sleep','60']);print(p.pid,flush=True);time.sleep(60)"
        p = launch([sys.executable, "-c", script], timeout=0)
        pid = int(read_until(p, b"\n").strip())
        p.stdin.write(frame("C")); p.stdin.flush()
        code, _, _ = collect(p)
        self.assertEqual(code, 130)
        self.assertFalse(active(pid))

    def test_parent_death_pipe_eof(self):
        p = launch([sys.executable, "-c", "import os,time;print(os.getpid(),flush=True);time.sleep(60)"], timeout=0)
        pid = int(read_until(p, b"\n").strip())
        p.stdin.close()
        code, _, _ = collect(p)
        self.assertEqual(code, 130)
        self.assertFalse(active(pid))

    def test_cooperative_cancel_waits_for_atomic_boundary(self):
        script = "import signal,time;signal.signal(signal.SIGINT,lambda *args:None);print('READY',flush=True);time.sleep(2.5);print('COMMITTED',flush=True)"
        p = launch([sys.executable, "-c", script], timeout=0, cooperative=True)
        read_until(p, b"READY")
        p.stdin.write(frame("C")); p.stdin.flush()
        code, out, _ = collect(p)
        self.assertEqual(code, 130)
        self.assertIn(b"COMMITTED", out, "Do not SIGKILL an atomic transaction after the ordinary two-second grace")

    def test_closed_full_output_pipe_drains_cooperative_child(self):
        # A crashed GUI closes both its control writer and its output reader.
        # Fill the output pipe before launch so a lost reader cannot be mistaken
        # for writable output. The child owns only these disposable fixture files.
        with tempfile.TemporaryDirectory(prefix="mopanel-closed-output-") as root:
            ready = pathlib.Path(root, "ready")
            committed = pathlib.Path(root, "committed")
            reader, writer = os.pipe()
            flags = fcntl.fcntl(writer, fcntl.F_GETFL)
            fcntl.fcntl(writer, fcntl.F_SETFL, flags | os.O_NONBLOCK)
            try:
                while True:
                    os.write(writer, b"p" * 4096)
            except BlockingIOError:
                pass
            script = (
                "import os,pathlib,signal,sys,time;"
                "signal.signal(signal.SIGINT,lambda *args:None);"
                "signal.signal(signal.SIGALRM,lambda *args:os._exit(99));signal.alarm(5);"
                "pathlib.Path(sys.argv[1]).write_text(str(os.getpid()));"
                "data=b'x'*(4*1024*1024);offset=0\n"
                "while offset<len(data):offset+=os.write(1,data[offset:])\n"
                "time.sleep(2.3);pathlib.Path(sys.argv[2]).write_text('COMMITTED')\n"
            )
            p = subprocess.Popen([str(GUARDIAN), "--pty", "--timeout-ms", "0", "--cooperative", "--",
                                  sys.executable, "-c", script, str(ready), str(committed)],
                                 stdin=subprocess.PIPE, stdout=writer, stderr=subprocess.PIPE)
            os.close(writer)
            try:
                deadline = time.monotonic() + 3
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready.exists(), "Harmless PTY fixture did not start")
                began = time.monotonic()
                os.close(reader); reader = None
                p.stdin.close()
                pid, status, usage = os.wait4(p.pid, 0)
                p.returncode = os.waitstatus_to_exitcode(status)
                elapsed = time.monotonic() - began
                cpu = usage.ru_utime + usage.ru_stime
                print(f"closed-output fixture: exit={p.returncode}, elapsed={elapsed:.3f}s, "
                      f"cpu={cpu:.3f}s, committed={committed.exists()}", flush=True)
                self.assertEqual(pid, p.pid)
                self.assertEqual(p.returncode, 130)
                self.assertTrue(committed.exists(), "Closed output must be drained so the safe boundary can finish")
                self.assertGreater(elapsed, 2.1, "Cooperative cancellation must not force-kill before the safe boundary")
                self.assertLess(cpu, 0.75, "A closed output descriptor must not cause a busy poll loop")
            finally:
                if reader is not None:
                    os.close(reader)
                if p.poll() is None:
                    p.kill(); p.wait(timeout=2)
                for stream in (p.stdin, p.stderr):
                    if stream and not stream.closed:
                        stream.close()

    def test_detached_descendant_observed_and_cleaned(self):
        # This execution sandbox exposes host /proc but returns namespace PIDs.
        # macOS libproc and a normal Linux /proc mount do not have that mismatch.
        proc_self = pathlib.Path("/proc/self/stat")
        if proc_self.exists() and int(proc_self.read_text().split(" ", 1)[0]) != os.getpid():
            self.skipTest("Sandbox /proc uses host PIDs; getpid returns namespace PIDs")
        script = "import subprocess,time; p=subprocess.Popen(['/bin/sleep','60'],start_new_session=True);print(p.pid,flush=True);time.sleep(60)"
        p = launch([sys.executable, "-c", script], timeout=0)
        pid = int(read_until(p, b"\n").strip())
        p.stdin.close()
        code, _, _ = collect(p)
        self.assertEqual(code, 130)
        self.assertFalse(active(pid))

    def test_capture_has_no_interactive_stdin(self):
        p = launch([sys.executable, "-c", "import sys;print(sys.stdin.isatty(),repr(sys.stdin.read()))"])
        self.assertEqual(collect(p)[1], b"False ''\n")

    def test_pty_is_controlling_terminal(self):
        p = launch([sys.executable, "-c", "import os;print(os.isatty(0),os.tcgetpgrp(0)==os.getpgrp())"], pty=True)
        code, out, err = collect(p)
        self.assertEqual(code, 0, err)
        self.assertIn(b"True True", out)

    def test_pty_input_and_resize(self):
        script = "import os,fcntl,termios,struct;print('READY',flush=True);s=input();print('VALUE:'+s,flush=True);print(struct.unpack('HHHH',fcntl.ioctl(0,termios.TIOCGWINSZ,b'0'*8))[:2],flush=True)"
        p = launch([sys.executable, "-c", script], pty=True)
        read_until(p, b"READY")
        p.stdin.write(frame("R", struct.pack(">HH", 90, 24)))
        p.stdin.write(frame("I", "繁體 測試\r".encode())); p.stdin.flush()
        code, out, _ = collect(p)
        self.assertEqual(code, 0)
        self.assertIn("VALUE:繁體 測試".encode(), out)
        self.assertIn(b"(24, 90)", out)

    def test_password_echo_is_not_returned(self):
        script = "import termios; t=termios.tcgetattr(0);t[3]&=~termios.ECHO;termios.tcsetattr(0,termios.TCSANOW,t);print('PASSWORD',flush=True);s=input();print('ACCEPTED',flush=True)"
        p = launch([sys.executable, "-c", script], pty=True)
        read_until(p, b"PASSWORD")
        p.stdin.write(frame("I", b"test-secret-never-log\r")); p.stdin.flush()
        code, out, err = collect(p)
        self.assertEqual(code, 0)
        self.assertIn(b"ACCEPTED", out)
        self.assertNotIn(b"test-secret", out + err)

    def test_large_output_is_complete(self):
        size = 3 * 1024 * 1024
        p = launch([sys.executable, "-c", f"import sys;sys.stdout.buffer.write(b'x'*{size})"])
        code, out, _ = collect(p)
        self.assertEqual(code, 0)
        self.assertEqual(len(out), size)

    def test_pty_large_output_is_complete(self):
        size = 2 * 1024 * 1024
        p = launch([sys.executable, "-c", f"import sys;sys.stdout.buffer.write(b'x'*{size})"], pty=True)
        code, out, _ = collect(p)
        self.assertEqual(code, 0)
        self.assertEqual(len(out), size)

    def test_malformed_control_is_fail_closed(self):
        p = launch(["/bin/sleep", "60"], timeout=0)
        p.stdin.write(b"I" + struct.pack(">I", 9999999)); p.stdin.flush()
        code, _, _ = collect(p)
        self.assertEqual(code, 125)


if __name__ == "__main__":
    if not GUARDIAN.is_file() or not os.access(GUARDIAN, os.X_OK):
        raise SystemExit("A built MoPanelGuardian executable is required")
    unittest.main(verbosity=2)
