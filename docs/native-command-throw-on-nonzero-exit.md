# Experimental native command exit policy

`PSNativeCommandThrowOnNonZeroExit` is disabled by default. Enable it once and
restart PowerShell; the choice persists across sessions:

```powershell
Enable-ExperimentalFeature PSNativeCommandThrowOnNonZeroExit
# Restart pwsh.
try {
    git -C /directory/that/does/not/exist status
    'This statement is skipped when git exits nonzero.'
} catch [System.Management.Automation.NativeCommandExitException] {
    "Failed: $($_.Exception.Path), exit code $($_.Exception.ExitCode)"
}
```

The policy adds a check at native process completion, in the engine, not in the
interactive input loop. It works in scripts, functions, pipelines and local
runspaces, independently of console command line hooks. When an observed native
exit code is nonzero, PowerShell generates a terminating error with ID
`ProgramExitedWithNonZeroCode` and a `NativeCommandExitException` containing the
executable path, exit code and child PID. `$LASTEXITCODE` is updated before the
error is raised. `try/catch`, `finally` and `trap` use normal PowerShell error
handling; an unhandled failure stops the current script/command, not the
interactive shell process. A script process exits according to PowerShell's
existing unhandled-error rules, not necessarily with the native exit code.

The feature forces the existing native exit error through the `Stop` path,
regardless of `$PSNativeCommandUseErrorActionPreference` and
`$ErrorActionPreference`. It does not change either variable or the handling of
ordinary cmdlet errors. Stream redirection (`2>$null`, `2>&1`) does not suppress
the terminating error. Catch expected nonzero results explicitly, including tools
such as `rg` and `diff` that use nonzero status for ordinary negative results.
Pipeline chains such as `native-command || fallback` do not suppress this policy;
use `try/catch` for fallback handling while it is enabled.

Zero exits and stderr alone do not trigger this policy. PowerShell functions,
cmdlets and `.ps1` script `exit` are outside its scope; commands launched as a
native `pwsh` process are still native processes. Commands for which PowerShell
does not wait for completion (such as some detached GUI applications) have no
observed exit code to check. Cancellation retains existing pipeline-stop behavior.

Disable it and restart to restore the existing native error preference behavior:

```powershell
Disable-ExperimentalFeature PSNativeCommandThrowOnNonZeroExit
```

With the feature disabled, the existing combination remains available without
custom features, but also makes ordinary PowerShell errors stop execution:

```powershell
$PSNativeCommandUseErrorActionPreference = $true
$ErrorActionPreference = 'Stop'
```
