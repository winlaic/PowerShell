# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

"""Inspect Unix process limits without creating dumps.

Run: python3 DisableCoreDump.py /path/to/pwsh
Requires Linux or macOS and Python 3; no third-party packages or root access.
"""

import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import tempfile
import unittest


PWSH = str(Path(sys.argv.pop(1)).resolve())
FEATURE = "PSDisableCoreDump"


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


class CoreDumpTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pwsh-core-limit-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.output = self.directory / "limits.json"
        self.helper = self.directory / "probe.py"
        self.helper.write_text("""
import json, resource, sys
from pathlib import Path
limits = resource.getrlimit(resource.RLIMIT_CORE)
can_raise = None
if limits == (0, 0):
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (1, 1))
        can_raise = True
    except (ValueError, OSError):
        can_raise = False
Path(sys.argv[1]).write_text(json.dumps({'limits': limits, 'can_raise': can_raise}))
""")
        self.command = f"& {quote(sys.executable)} {quote(self.helper)} {quote(self.output)}"
        self.hard = resource.getrlimit(resource.RLIMIT_CORE)[1]
        if self.hard == 0:
            self.skipTest("Parent hard core limit is already zero; cannot test policy changes")
        self.soft = 1024 * 1024 if self.hard == resource.RLIM_INFINITY else min(self.hard, 1024 * 1024)
        self.environment = os.environ.copy()
        # Isolate user settings so they cannot override the -SettingsFile test configuration.
        self.environment["XDG_CONFIG_HOME"] = str(self.directory / "config")
        self.environment["XDG_CACHE_HOME"] = str(self.directory / "cache")

    def launch(self, settings, command=None, file=False, profile=False, interactive=False):
        self.output.unlink(missing_ok=True)
        config = self.directory / "settings.json"
        config.write_text(json.dumps(settings))
        args = [PWSH, "-SettingsFile", str(config), "-NoLogo"]
        if not profile:
            args.append("-NoProfile")
        if interactive:
            # Redirected console input still enters the interactive command loop.
            args += ["-NoExit", "-Command", "function prompt { '' }"]
        else:
            args.append("-NonInteractive")
            if file:
                script = self.directory / "test.ps1"
                script.write_text(command or self.command)
                args += ["-File", str(script)]
            else:
                args += ["-Command", command or self.command]

        def set_inherited_limit():
            resource.setrlimit(resource.RLIMIT_CORE, (self.soft, self.hard))

        parent_limits = resource.getrlimit(resource.RLIMIT_CORE)
        result = subprocess.run(
            args, env=self.environment, capture_output=True, text=True, timeout=30,
            input=self.command + "\nexit\n" if interactive else "",
            preexec_fn=set_inherited_limit,
        )
        self.assertEqual(parent_limits, resource.getrlimit(resource.RLIMIT_CORE))
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertTrue(self.output.exists(), result.stdout + result.stderr)
        return json.loads(self.output.read_text())

    def test_missing_feature_preserves_inherited_limits(self):
        self.assertEqual([self.soft, self.hard], self.launch({})["limits"])

    def test_disabled_feature_preserves_inherited_limits(self):
        result = self.launch({"ExperimentalFeatures": []})
        self.assertEqual([self.soft, self.hard], result["limits"])

    def test_enabled_command_sets_both_limits_and_children_cannot_raise_them(self):
        result = self.launch({"ExperimentalFeatures": [FEATURE]})
        self.assertEqual([0, 0], result["limits"])
        # Root can raise hard limits on some hosts; verify denial as an ordinary user.
        if os.geteuid() != 0:
            self.assertFalse(result["can_raise"])

    def test_enabled_file_sets_both_limits(self):
        result = self.launch({"ExperimentalFeatures": [FEATURE]}, file=True)
        self.assertEqual([0, 0], result["limits"])

    def test_enabled_interactive_console_sets_both_limits(self):
        result = self.launch({"ExperimentalFeatures": [FEATURE]}, interactive=True)
        self.assertEqual([0, 0], result["limits"])

    def test_limit_is_applied_before_user_profile(self):
        config = Path(self.environment["XDG_CONFIG_HOME"]) / "powershell"
        config.mkdir(parents=True)
        (config / "Microsoft.PowerShell_profile.ps1").write_text(self.command)
        result = self.launch({"ExperimentalFeatures": [FEATURE]}, command="'profile loaded'", profile=True)
        self.assertEqual([0, 0], result["limits"])

    def test_child_pwsh_inherits_limits_even_with_feature_disabled(self):
        disabled = self.directory / "child-settings.json"
        disabled.write_text('{"ExperimentalFeatures": []}')
        script = self.directory / "child.ps1"
        script.write_text(self.command)
        command = f"& {quote(PWSH)} -SettingsFile {quote(disabled)} -NoProfile -File {quote(script)}"
        result = self.launch({"ExperimentalFeatures": [FEATURE]}, command=command)
        self.assertEqual([0, 0], result["limits"])

    def test_enable_disable_persists_and_only_affects_new_sessions(self):
        enable = f"Enable-ExperimentalFeature {FEATURE} -Scope CurrentUser -WarningAction SilentlyContinue | Out-Null; "
        result = self.launch({}, command=enable + self.command)
        self.assertEqual([self.soft, self.hard], result["limits"])
        self.assertEqual([0, 0], self.launch({})["limits"])
        disable = f"Disable-ExperimentalFeature {FEATURE} -Scope CurrentUser -WarningAction SilentlyContinue | Out-Null; "
        result = self.launch({}, command=disable + self.command)
        self.assertEqual([0, 0], result["limits"])
        # The test harness is an unrestricted parent; launching here restores the baseline.
        self.assertEqual([self.soft, self.hard], self.launch({})["limits"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
