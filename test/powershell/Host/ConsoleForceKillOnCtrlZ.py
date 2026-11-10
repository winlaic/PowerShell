# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

"""Unix PTY integration tests. Run: python3 ConsoleForceKillOnCtrlZ.py /path/to/pwsh.

Each console owns a new terminal/session. Tests never signal the invoking shell.
Requires Linux or macOS, Python 3 and /bin/bash. No third-party Python packages.
"""

import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest


PWSH = str(Path(sys.argv.pop(1)).resolve())
FEATURE = "PSConsoleForceKillOnCtrlZ"


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


HELPER = r"""
import json, os, signal, subprocess, sys, termios, time
from pathlib import Path
mode, directory = sys.argv[1:]
signal.signal(signal.SIGINT, signal.SIG_IGN)
if mode == 'tree':
    subprocess.Popen([sys.executable, __file__, 'child', directory])
if mode == 'terminal':
    # Change echo but retain ISIG so the terminal can still deliver Ctrl+Z.
    state = termios.tcgetattr(0)
    state[3] &= ~termios.ECHO
    termios.tcsetattr(0, termios.TCSANOW, state)
Path(directory, mode + '.json').write_text(json.dumps({'pid':os.getpid(),'pgid':os.getpgrp()}))
while True:
    time.sleep(.1)
"""


class Console:
    def __init__(self, enabled=True, hooks=False, psreadline=False, noninteractive=False):
        self.temporary = tempfile.TemporaryDirectory(prefix="pwsh-ctrl-z-test-")
        self.directory = Path(self.temporary.name)
        self.helper = self.directory / "helper.py"
        self.helper.write_text(HELPER)
        self.events = self.directory / "events.jsonl"
        settings = self.directory / "settings.json"
        features = [FEATURE] if enabled else []
        if hooks:
            features += ["PSConsoleCommandLineHooks", "PSNativeCommandThrowOnNonZeroExit"]
        settings.write_text(json.dumps({"ExperimentalFeatures": features}))
        bootstrap = self.directory / "bootstrap.ps1"
        script = "" if psreadline else "Remove-Module PSReadLine -ErrorAction Ignore\n"
        script += "function prompt { 'CTRLZ_TEST> ' }\n"
        if hooks:
            script += """
Register-PSConsoleCommandLineHook -Name test -Finished {
    param($e)
    [IO.File]::AppendAllText(EVENTS, ($e | ConvertTo-Json -Depth 5 -Compress -EnumsAsStrings) + "`n")
} | Out-Null
""".replace("EVENTS", quote(self.events))
        script += "[IO.File]::WriteAllText(" + quote(self.directory / "shell.pid") + ", [string]$PID)\n"
        bootstrap.write_text(script)
        self.groups = set()
        self.transcript = ""
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ["PS1"] = "PARENT_TEST> "
            os.environ["TERM"] = "xterm"
            os.execv("/bin/bash", ["bash", "--noprofile", "--norc", "-i"])
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        try:
            self.wait_output("PARENT_TEST> ")
            args = [PWSH, "-SettingsFile", str(settings), "-NoLogo", "-NoProfile", "-NoExit", "-File", str(bootstrap)]
            if noninteractive:
                args.insert(1, "-NonInteractive")
            import shlex
            self.send(" ".join(shlex.quote(arg) for arg in args))
            self.wait_file("shell.pid")
            self.shell_pid = int((self.directory / "shell.pid").read_text())
            self.group = os.getpgid(self.shell_pid)
            if self.group in (os.getpgrp(), os.getpgid(self.pid)):
                raise AssertionError("Test console did not get an isolated process group")
            self.groups.add(self.group)
            if "CTRLZ_TEST> " not in self.transcript:
                self.wait_output("CTRLZ_TEST> ")
        except BaseException:
            self.close()
            raise

    def send(self, line):
        os.write(self.fd, (line + "\r").encode())

    def read(self, duration=.1):
        end = time.monotonic() + duration
        output = b""
        while time.monotonic() < end:
            ready, _, _ = select.select([self.fd], [], [], max(0, min(.05, end - time.monotonic())))
            if ready:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output += chunk
                if b"\x1b[6n" in chunk:
                    os.write(self.fd, b"\x1b[1;1R")
        text = output.decode(errors="replace")
        self.transcript += text
        return text

    def wait_output(self, text, timeout=12):
        end = time.monotonic() + timeout
        output = ""
        while time.monotonic() < end:
            output += self.read()
            if text in output:
                return output
        raise AssertionError(f"Missing {text!r}: {self.transcript[-3000:]!r}")

    def wait_file(self, name, timeout=12):
        end = time.monotonic() + timeout
        file = self.directory / name
        while time.monotonic() < end:
            self.read()
            if file.exists() and file.stat().st_size:
                return file
        raise AssertionError(f"Missing file {name}: {self.transcript[-2000:]!r}")

    def native(self, mode, suffix=""):
        return f"& {quote(sys.executable)} {quote(self.helper)} {quote(mode)} {quote(self.directory)} {suffix}"

    def marker(self, name):
        return f"[IO.File]::WriteAllText({quote(self.directory / name)}, 'done')"

    def ctrl_z(self):
        os.write(self.fd, b"\x1a")

    def assert_dead(self, mode):
        pid = json.loads((self.directory / (mode + ".json")).read_text())["pid"]
        end = time.monotonic() + 5
        while time.monotonic() < end:
            result = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
            if not result.stdout.strip() or result.stdout.lstrip().startswith("Z"):
                return
            self.read()
        raise AssertionError(f"Native process {pid} ({mode}) survived force termination")

    def next_command(self):
        self.send(self.marker("next"))
        self.wait_file("next")

    def close(self):
        for group in self.groups:
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        # This group contains only the test's parent bash, in its own PTY session.
        try:
            os.killpg(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.close(self.fd)
        os.waitpid(self.pid, 0)
        self.temporary.cleanup()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class ForceKillTests(unittest.TestCase):
    def test_disabled_preserves_parent_shell_job_control(self):
        with Console(enabled=False) as console:
            console.send(console.native("plain"))
            console.wait_file("plain.json")
            console.ctrl_z()
            console.wait_output("PARENT_TEST> ")

    def test_noninteractive_preserves_suspend(self):
        with Console(noninteractive=True) as console:
            console.send(console.native("plain"))
            console.wait_file("plain.json")
            console.ctrl_z()
            console.wait_output("PARENT_TEST> ")

    def test_force_kill_after_ignored_ctrl_c(self):
        with Console() as console:
            console.send(console.native("plain", "; " + console.marker("unreachable")))
            console.wait_file("plain.json")
            os.write(console.fd, b"\x03")
            self.assertNotIn("CTRLZ_TEST> ", console.read(.5))
            console.ctrl_z()
            console.wait_output("CTRLZ_TEST> ")
            console.assert_dead("plain")
            self.assertFalse((console.directory / "unreachable").exists())
            console.next_command()

    def test_terminates_native_pipeline(self):
        with Console() as console:
            console.send(console.native("left") + " | " + console.native("right"))
            console.wait_file("left.json")
            console.wait_file("right.json")
            console.ctrl_z()
            console.wait_output("CTRLZ_TEST> ")
            console.assert_dead("left")
            console.assert_dead("right")
            console.next_command()

    def test_terminates_descendants(self):
        with Console() as console:
            console.send(console.native("tree"))
            console.wait_file("tree.json")
            console.wait_file("child.json")
            console.ctrl_z()
            console.wait_output("CTRLZ_TEST> ")
            console.assert_dead("tree")
            console.assert_dead("child")
            console.next_command()

    def test_repeated_signals_and_idle_do_not_kill_next_command(self):
        with Console() as console:
            console.send(console.native("first"))
            console.wait_file("first.json")
            os.kill(console.shell_pid, signal.SIGTSTP)
            os.kill(console.shell_pid, signal.SIGTSTP)
            console.wait_output("CTRLZ_TEST> ")
            os.kill(console.shell_pid, signal.SIGTSTP)
            console.read(.2)
            console.send(console.native("second"))
            console.wait_file("second.json")
            self.assertNotIn("CTRLZ_TEST> ", console.read(.5))
            console.ctrl_z()
            console.wait_output("CTRLZ_TEST> ")
            console.assert_dead("second")
            console.next_command()

    def test_terminal_echo_is_restored(self):
        with Console() as console:
            before = termios.tcgetattr(console.fd)
            console.send(console.native("terminal"))
            console.wait_file("terminal.json")
            self.assertFalse(termios.tcgetattr(console.fd)[3] & termios.ECHO)
            console.ctrl_z()
            console.wait_output("CTRLZ_TEST> ")
            after = termios.tcgetattr(console.fd)
            self.assertEqual(before[3] & termios.ECHO, after[3] & termios.ECHO)
            console.next_command()

    def test_hooks_report_cancelled_with_native_exit_policy(self):
        with Console(hooks=True) as console:
            console.send(console.native("plain", "; " + console.marker("unreachable")))
            console.wait_file("plain.json")
            console.ctrl_z()
            console.wait_output("CTRLZ_TEST> ")
            console.next_command()
            records = [json.loads(line) for line in console.events.read_text().splitlines()]
            self.assertEqual("Cancelled", records[0]["Outcome"])
            self.assertFalse((console.directory / "unreachable").exists())

    def test_psreadline_accepts_input_after_force_kill(self):
        with Console(psreadline=True) as console:
            console.send(console.native("plain"))
            console.wait_file("plain.json")
            console.ctrl_z()
            console.wait_output("CTRLZ_TEST> ")
            console.next_command()


if __name__ == "__main__":
    unittest.main(verbosity=2)
