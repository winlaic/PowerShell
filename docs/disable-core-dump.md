# Experimental Unix core dump suppression

`PSDisableCoreDump` is disabled by default. Enable it once, then start a new pwsh:

```powershell
Enable-ExperimentalFeature PSDisableCoreDump
```

On Linux and macOS, ConsoleHost sets the process's `RLIMIT_CORE` soft and hard
limits to zero before loading profiles or executing commands. This applies to
interactive, noninteractive, `-Command`, `-File`, and server modes. It requires
no root permissions. If setting the limit fails, startup reports an error and
returns exit code 70 rather than silently continuing without the requested limit.

This is an optional startup policy. With the feature absent or disabled, the
host does not change the inherited limits. Existing configuration files and
launch commands keep their previous behavior. Windows and applications that
embed the PowerShell engine without ConsoleHost are unaffected.

All child processes inherit the zero limits, including native commands, jobs,
and programs launched with `Start-Process`. An unprivileged process cannot raise
the hard limit again. Disabling the feature does not restore the limit in an
already restricted process or its descendants:

```powershell
Disable-ExperimentalFeature PSDisableCoreDump
```

After disabling, exit the restricted shell and launch pwsh from an unrestricted
parent (for example, a fresh terminal). This avoids inheriting zero limits from
the old shell. Enabling the feature also requires a new pwsh; it does not alter
the current session's limits.

This policy prevents kernel core files written directly to disk, such as those
selected by `/home/core/core.%e.%p.%t`. Linux ignores `RLIMIT_CORE` when
`core_pattern` pipes dumps to a collector, so such collectors can still receive
dumps. Explicit .NET diagnostic dumps, debugger dumps, and dumps produced before
managed startup reaches ConsoleHost are outside this policy. It does not fix
crashes or remove existing core files.

The integration tests inspect real process limits without deliberately crashing
processes or creating core files. Run on Linux or macOS with Python 3:

```sh
python3 test/powershell/Host/DisableCoreDump.py /path/to/pwsh
```
