# Experimental foreground termination on Ctrl+Z

`PSConsoleForceKillOnCtrlZ` is disabled by default. Enable it once and restart:

```powershell
Enable-ExperimentalFeature PSConsoleForceKillOnCtrlZ
```

In an interactive local ConsoleHost on Linux or macOS, Ctrl+Z then stops the
current console submission and forcefully terminates its registered native
processes, including native pipeline members. Descendant cleanup uses .NET's
process-tree termination and is best effort. The shell remains running and
accepts another command. This also works after Ctrl+C has become blocked waiting
for a standalone native program that ignores SIGINT. External programs do not get
an opportunity to save data or run exit handlers when forcefully terminated.

This feature adds an explicit escape path to the existing console execution
flow. When disabled, PowerShell installs no SIGTSTP handler and retains its
existing suspension and cancellation behavior. Enabling it replaces the default
SIGTSTP suspension action within the interactive ConsoleHost; it provides no
paused-job table, `fg` or `bg` operation. It never kills the shell's process group,
which can be shared with unrelated commands.

Only processes launched through the native-command engine during the active
primary console submission are registered. Jobs, parallel runspaces, remoting,
debugger/nested prompts, startup/profile scripts, direct `-Command` or `-File`
execution, and processes launched through APIs such as `Start-Process` are not
registered for force termination. NonInteractive sessions do not register the
signal handler. At an idle prompt or inside an excluded nested/debugger context,
an enabled handler suppresses suspension without terminating processes.

Stopping the pipeline uses PowerShell's existing cooperative stop mechanism.
Managed code or cmdlets that block indefinitely in their own code cannot be
safely force-aborted in the shell process. Native children that detach, change
ownership, or race with process enumeration may survive. Processes stuck in an
uninterruptible kernel wait may not exit immediately even after SIGKILL.

The terminal must deliver SIGTSTP to PowerShell. The default terminal Ctrl+Z
binding normally does this while native applications use terminal signal
processing. An application that disables ISIG, changes the suspend character, or
consumes Ctrl+Z in raw mode can prevent the keystroke from delivering the signal.
Sending `kill -TSTP <pwsh-pid>` from another terminal invokes the same handler.

On force cancellation, the host restores the termios state captured before the
submission, including echo and input modes. It does not reconstruct a killed
application's alternate screen or undo every terminal escape sequence. Signals
capture the active submission/pipeline; an asynchronous worker never looks up
whichever command happens to be running later. Repeated signals for the same
submission are idempotent, and completion joins its termination worker before
accepting another command.

With `PSConsoleCommandLineHooks` enabled, cancellation during user execution
reports `Outcome = Cancelled`. Native exit codes remain observations rather than
a synthetic cancellation code and may be absent. Callback processes are excluded
from the native kill registry; starting callbacks receive cooperative pipeline
cancellation. Finished callbacks run after the foreground termination scope has
closed. Ordinary Ctrl+C behavior remains unchanged.

Disable and restart to restore the existing Ctrl+Z behavior:

```powershell
Disable-ExperimentalFeature PSConsoleForceKillOnCtrlZ
```

Real terminal tests (Python standard library only) can be run on Linux/macOS:

```sh
python3 test/powershell/Host/ConsoleForceKillOnCtrlZ.py /path/to/built/pwsh
```
