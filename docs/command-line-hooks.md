# Experimental console command line hooks

`PSConsoleCommandLineHooks` adds synchronous lifecycle notifications for complete
input submitted to the primary local ConsoleHost input loop. It is disabled by
default. Enable it and restart PowerShell before registering handlers:

```powershell
Enable-ExperimentalFeature PSConsoleCommandLineHooks
# Restart pwsh, then put the following registration in your profile if desired.
$hook = Register-PSConsoleCommandLineHook -Name TerminalIntegration -Starting {
    param($e)
    [Console]::WriteLine("Starting PID {0} at {1}: {2}",
        $e.ProcessId, $e.Timestamp, $e.CommandLine)
} -Finished {
    param($e)
    [Console]::WriteLine("Finished: {0}; native={1}; script={2}; shell={3}; duration={4}",
        $e.Outcome, $e.NativeExitCode, $e.ScriptExitCode, $e.ShellExitCode, $e.Duration)
}

Get-PSConsoleCommandLineHook
Get-PSConsoleCommandLineHook -Diagnostic
Unregister-PSConsoleCommandLineHook -Id $hook.Id
# Alternatively: Get-PSConsoleCommandLineHook | Unregister-PSConsoleCommandLineHook
```

Registrations have independent IDs; labels need not be unique. Either handler may
be omitted, but at least one is required. Handlers run in registration order from
a snapshot taken before starting notifications. Changes made during a submission
apply to the next submission, including changes made from a handler. Registration
metadata exposes no script blocks. Commands reject unsupported hosts/runspaces,
nested/debugger prompts and `-NonInteractive` sessions.

## Notification contract

A single invocation represents one complete submitted input, including multiple
statements, pipelines and embedded newlines. Starting and finished notifications
share `InvocationId`, `CommandLine`, `ProcessId` and `AcceptedAt`. `CommandLine` is
unexpanded input; `ProcessId` identifies the host, since one input can launch many
children. `AcceptedAt` and notification `Timestamp` are UTC `DateTimeOffset` values.
The public metadata properties are read-only.

Finished metadata adds:

| Property | Meaning |
| --- | --- |
| `ExecutionStarted` | Whether user pipeline invocation began. |
| `ExecutionStartedAt`, `ExecutionEndedAt` | UTC execution boundaries, nullable when not invoked. |
| `Duration` | Monotonic elapsed execution time, including cancellation cleanup, excluding handlers; nullable when not invoked. |
| `Outcome` | `Succeeded`, `Failed`, `Cancelled`, `ParseError`, or `ShellExit`. |
| `NativeExitCode` | Last actual native process exit observed in this execution, otherwise null. |
| `ScriptExitCode` | Last script exit observed in this execution, otherwise null. |
| `ShellExitCode` | Requested shell exit code, otherwise null. |

Ordinary success/failure follows the final PowerShell execution status (`$?`),
not an aggregate of all statements. There is no synthetic universal exit code.
Exit codes are observed at execution paths, not inferred from assignments to
`$LASTEXITCODE`, and can coexist in a submission. A successful PowerShell command
after native exit 7 has a null native code even though `$LASTEXITCODE` remains 7.
Background/parallel work, handlers, and nested prompt input do not contribute codes.
A complete syntax error reports `ParseError` with `ExecutionStarted = false`.

Blank input, incomplete input, prompts, completion, profiles, initial
`-Command`/`-File` execution, debugger/nested prompts, remote sessions and background
runspaces do not notify. Redirected input processed by the console input loop is
supported; `-NonInteractive` disables the facility. No registrations means the
original execution path, without additional parsing or invocation metadata.

## Isolation and cancellation

Callbacks run synchronously in the primary runspace with local scope. Pipeline
output is discarded. Automatic error recording is redirected to bounded diagnostics;
ordinary callback errors do not add entries to `$Error`, abort the user command or
prevent subsequent handlers. `$?` and `$LASTEXITCODE` are restored after each handler.
Callbacks are not a security boundary: explicit console/file writes, global variable
changes, `$Error.Clear()`, native side effects and directory changes remain possible.
A handler's `exit` is contained and diagnosed rather than exiting the host.

Ctrl+C during starting notifications skips the remaining starting handlers and the
user command, sets `$?` to false, then attempts finished notifications with `Cancelled` and no execution
timestamps. Ctrl+C during execution waits for pipeline cancellation before finished
notifications. Ctrl+C during finished notifications skips the remaining handlers;
the already captured user result is preserved. A separate cancellation scope is
used for finished notifications. Handlers have no automatic timeout and can block
input; Ctrl+C cancellation is cooperative, as for ordinary PowerShell code.

Forceful process termination (including SIGKILL and `Environment.Exit`), runtime
failure and machine shutdown cannot guarantee a finished notification. Hook
notifications are best-effort integration signals, not durable audit records.

Diagnostics retain at most the most recent 128 failures per console host. Records
contain registration/invocation IDs, phase, timestamp, host-defined diagnostic ID and exception type;
they do not retain the exception, message, script block or command text. Diagnostics are queried
explicitly and are not written to the terminal automatically.

## Validation and release scope

The automated suite covers feature gating, metadata, errors and parse errors,
actual native/script/shell exits, callback isolation, registration snapshots,
nested/parallel exclusions, bounded diagnostics, and Unix cancellation in each
phase using readiness signals. The common tests are written for Windows, Linux
and macOS; signal delivery tests require Linux or macOS. Validate the native
ConsoleHost and terminal integration on each supported platform before promoting
this preview API to a stable release.

Local validation built the self-contained `linux-x64` publish output with .NET
SDK 11.0.100-rc.1.26425.128. On the available Linux ARM64 machine, a .NET 11 ARM64
test host loaded the built managed assemblies with ARM64 native support: all 23
hook tests and all 9 working-directory regression tests passed. A real PTY with
PSReadLine also passed native exit, five consecutive execution cancellations,
status restoration and shell exit checks. The x64 native executable was built but
could not be executed on that machine; Windows/macOS execution remains unverified.

For a repeatable manual allocation/timing comparison of the disabled feature,
enabled feature without registrations, and two empty handlers, run:

```powershell
./test/perf/ConsoleCommandLineHooks.ps1 -PowerShellPath /path/to/pwsh
```

The benchmark excludes startup and warms up the input loop. It measures whole
console submissions, not only hook dispatch; timings need a stable test machine.
