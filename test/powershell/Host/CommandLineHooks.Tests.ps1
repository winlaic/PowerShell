# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe 'Experimental console command line hooks' -Tags CI {
    BeforeAll {
        $powershell = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $enabledSettings = Join-Path $TestDrive 'enabled.json'
        $disabledSettings = Join-Path $TestDrive 'disabled.json'
        $nativeExitSettings = Join-Path $TestDrive 'native-exit.json'
        '{"ExperimentalFeatures":["PSConsoleCommandLineHooks"]}' | Set-Content $enabledSettings
        '{"ExperimentalFeatures":[]}' | Set-Content $disabledSettings
        '{"ExperimentalFeatures":["PSConsoleCommandLineHooks","PSNativeCommandThrowOnNonZeroExit"]}' | Set-Content $nativeExitSettings
        $bootstrap = Join-Path $TestDrive 'bootstrap.ps1'
        @'
# Redirected-input tests use the built-in reader; real terminal tests exercise PSReadLine separately.
Remove-Module PSReadLine -ErrorAction Ignore
function prompt { 'HOOKTEST> ' }
function Save-HookEvent {
    param($kind, $eventArgs)
    $record = @{ Kind = $kind; Data = $eventArgs }
    [IO.File]::AppendAllText($env:HOOK_TEST_FILE, ($record | ConvertTo-Json -Depth 5 -Compress -EnumsAsStrings) + "`n")
}
if ($env:HOOK_TEST_MODE -eq 'FeatureOff') {
    "AVAILABLE:$([bool](Get-Command Register-PSConsoleCommandLineHook -ErrorAction Ignore))"
    return
}
if ($env:HOOK_TEST_MODE -eq 'Disabled') { return }
$null = Register-PSConsoleCommandLineHook -Name first -Starting {
    param($e)
    Save-HookEvent Starting $e
    if ($env:HOOK_TEST_MODE -like 'Noisy*') {
        'HOOK OUTPUT'
        & $env:HOOK_TEST_PWSH -NoProfile -Command 'exit 92'
        Write-Error 'HOOK NONTERMINATING ERROR'
        throw 'HOOK FAILURE'
    }
    if ($env:HOOK_TEST_MODE -eq 'Exit') { exit 91 }
    if ($env:HOOK_TEST_MODE -eq 'CancelStarting' -and $e.CommandLine -eq "'skipped'") {
        [IO.File]::WriteAllText($env:HOOK_TEST_GATE, 'ready')
        Start-Sleep -Seconds 30
    }
} -Finished {
    param($e)
    Save-HookEvent Finished $e
    if ($env:HOOK_TEST_MODE -like 'Noisy*') {
        'HOOK OUTPUT'
        & $env:HOOK_TEST_PWSH -NoProfile -Command 'exit 93'
        Write-Error 'HOOK NONTERMINATING ERROR'
        throw 'HOOK FAILURE'
    }
    if ($env:HOOK_TEST_MODE -eq 'Exit') { exit 92 }
    if ($env:HOOK_TEST_MODE -eq 'CancelFinished' -and $e.CommandLine -eq "'cancel finish'") {
        [IO.File]::WriteAllText($env:HOOK_TEST_GATE, 'ready')
        Start-Sleep -Seconds 30
    }
}
if ($env:HOOK_TEST_MODE -in @('Ordered', 'Noisy', 'CancelStarting', 'CancelFinished')) {
    $null = Register-PSConsoleCommandLineHook -Name second -Starting {
        param($e) Save-HookEvent StartingSecond $e
    } -Finished { param($e) Save-HookEvent FinishedSecond $e }
}
if ($env:HOOK_TEST_MODE -in @('StartingOnly', 'FinishedOnly')) {
    Get-PSConsoleCommandLineHook | Unregister-PSConsoleCommandLineHook
    if ($env:HOOK_TEST_MODE -eq 'StartingOnly') {
        $null = Register-PSConsoleCommandLineHook -Name start -Starting { param($e) Save-HookEvent Starting $e }
    } else {
        $null = Register-PSConsoleCommandLineHook -Name finish -Finished { param($e) Save-HookEvent Finished $e }
    }
}
$global:LASTEXITCODE = 0
if ($env:HOOK_TEST_MODE -eq 'NoisyUnset') { Remove-Variable LASTEXITCODE -Scope Global }
$Error.Clear()
'@ | Set-Content -LiteralPath $bootstrap

        function Invoke-HookedConsole {
            param([string[]] $Lines, [string] $Mode = '', [switch] $CancelFirst)

            $eventsFile = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.jsonl')
            $gateFile = "$eventsFile.gate"
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $powershell
            $settings = if ($Mode -eq 'FeatureOff') { $disabledSettings } elseif ($Mode -eq 'NativeExitPolicy') { $nativeExitSettings } else { $enabledSettings }
            foreach ($argument in @('-SettingsFile', $settings, '-NoLogo', '-NoProfile', '-NoExit', '-File', $bootstrap)) {
                $startInfo.ArgumentList.Add($argument)
            }
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.Environment['HOOK_TEST_FILE'] = $eventsFile
            $startInfo.Environment['HOOK_TEST_GATE'] = $gateFile
            $startInfo.Environment['HOOK_TEST_MODE'] = $Mode
            $startInfo.Environment['HOOK_TEST_PWSH'] = $powershell
            $process = [Diagnostics.Process]::Start($startInfo)
            try {
                $outputTask = $process.StandardOutput.ReadToEndAsync()
                $errorTask = $process.StandardError.ReadToEndAsync()
                for ($index = 0; $index -lt $Lines.Count; $index++) {
                    $process.StandardInput.WriteLine($Lines[$index])
                    if ($CancelFirst -and $index -eq 0) {
                        $process.StandardInput.Flush()
                        $deadline = [DateTime]::UtcNow.AddSeconds(20)
                        # Signal only after the target phase explicitly announces readiness.
                        while (!(Test-Path -LiteralPath $gateFile)) {
                            if ($process.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw 'Cancellation gate not observed' }
                            Start-Sleep -Milliseconds 10
                        }
                        & /bin/kill -s INT $process.Id
                        do {
                            if ($process.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw 'Finish not observed after Ctrl+C' }
                            Start-Sleep -Milliseconds 10
                            $finished = [IO.File]::ReadAllText($eventsFile).Contains('"Kind":"Finished"')
                        } until ($finished)
                    }
                }
                $process.StandardInput.Close()
                if (!$process.WaitForExit(30000)) { throw 'Console hook test timed out' }
                $events = if (Test-Path -LiteralPath $eventsFile) {
                    Get-Content -LiteralPath $eventsFile | ForEach-Object { $_ | ConvertFrom-Json }
                }
                [pscustomobject]@{
                    Events = @($events)
                    Output = $outputTask.GetAwaiter().GetResult()
                    Error = $errorTask.GetAwaiter().GetResult()
                    ExitCode = $process.ExitCode
                    ProcessId = $process.Id
                }
            }
            finally {
                if (!$process.HasExited) {
                    $process.Kill($true)
                    $null = $process.WaitForExit(5000)
                }
                $process.Dispose()
            }
        }
    }

    It 'Reports complete input, paired IDs, host PID, UTC times and monotonic duration' {
        $line = "'first' | ForEach-Object { `$_; 'second' }; 'third'"
        $result = Invoke-HookedConsole -Lines @($line)
        $result.Events.Count | Should -Be 2
        $start, $finish = $result.Events
        $start.Kind | Should -BeExactly Starting
        $finish.Kind | Should -BeExactly Finished
        $start.Data.CommandLine | Should -BeExactly $line
        $finish.Data.CommandLine | Should -BeExactly $line
        $start.Data.ProcessId | Should -Be $result.ProcessId
        $finish.Data.ProcessId | Should -Be $result.ProcessId
        $finish.Data.InvocationId | Should -BeExactly $start.Data.InvocationId
        ([DateTimeOffset]$start.Data.Timestamp).Offset | Should -Be ([TimeSpan]::Zero)
        ([DateTimeOffset]$finish.Data.ExecutionEndedAt) | Should -BeGreaterOrEqual ([DateTimeOffset]$finish.Data.ExecutionStartedAt)
        $finish.Data.Duration.Ticks | Should -BeGreaterOrEqual 0
        $finish.Data.ExecutionStarted | Should -BeTrue
        $finish.Data.Outcome | Should -BeExactly Succeeded
        $finish.Data.NativeExitCode | Should -BeNullOrEmpty
        $finish.Data.ScriptExitCode | Should -BeNullOrEmpty
        $finish.Data.ShellExitCode | Should -BeNullOrEmpty
    }

    It 'Ignores blank input, incomplete blocks, prompts and bootstrap code' {
        $result = Invoke-HookedConsole -Lines @('', 'if ($true) {', "'multiline'", '}', '')
        $result.Events.Count | Should -Be 2
        $result.Events[0].Data.CommandLine | Should -BeExactly "if (`$true) {`n'multiline'`n}"
    }

    It 'Observes actual native exits without stale values or variable-assignment guesses' {
        $native = '& $env:HOOK_TEST_PWSH -NoProfile -Command "exit 7"'
        $result = Invoke-HookedConsole -Lines @($native, '$global:LASTEXITCODE = 99', "Write-Error 'test failure'")
        $finished = @($result.Events | Where-Object Kind -EQ Finished)
        $finished.Count | Should -Be 3
        $finished[0].Data.Outcome | Should -BeExactly Failed
        $finished[0].Data.NativeExitCode | Should -Be 7
        $finished[1].Data.Outcome | Should -BeExactly Succeeded
        $finished[1].Data.NativeExitCode | Should -BeNullOrEmpty
        $finished[1].Data.ScriptExitCode | Should -BeNullOrEmpty
        $finished[2].Data.Outcome | Should -BeExactly Failed
        $finished[2].Data.NativeExitCode | Should -BeNullOrEmpty
    }

    It 'Reports native policy termination and accepts the next interactive command' {
        $result = Invoke-HookedConsole -Mode NativeExitPolicy -Lines @(
            '& $env:HOOK_TEST_PWSH -NoProfile -Command "exit 7"; "UNREACHABLE"'
            '"AFTER:$LASTEXITCODE"'
        )
        $result.Events.Count | Should -Be 4
        $result.Events[1].Data.Outcome | Should -BeExactly Failed
        $result.Events[1].Data.NativeExitCode | Should -Be 7
        $result.Events[3].Data.Outcome | Should -BeExactly Succeeded
        $result.Events[3].Data.NativeExitCode | Should -BeNullOrEmpty
        $result.Output | Should -Match 'AFTER:7'
        $result.Output | Should -Not -Match '(?m)^UNREACHABLE\r?$'
    }

    It 'Distinguishes script exit, native exit and shell exit' {
        $script = Join-Path $TestDrive 'exit-script.ps1'
        'exit 17' | Set-Content $script
        $result = Invoke-HookedConsole -Lines @("& '$script'", 'exit 23')
        $result.Events[1].Data.ScriptExitCode | Should -Be 17
        $result.Events[1].Data.NativeExitCode | Should -BeNullOrEmpty
        $result.Events[1].Data.ShellExitCode | Should -BeNullOrEmpty
        $result.Events[3].Data.Outcome | Should -BeExactly ShellExit
        $result.Events[3].Data.ShellExitCode | Should -Be 23
        $result.ExitCode | Should -Be 23
    }

    It 'Reports terminating errors and resumes input' {
        $result = Invoke-HookedConsole -Lines @("throw 'test failure'", "'after failure'")
        $result.Events.Count | Should -Be 4
        $result.Events[1].Data.Outcome | Should -BeExactly Failed
        $result.Events[3].Data.Outcome | Should -BeExactly Succeeded
        $result.Output | Should -Match 'after failure'
    }

    It 'Reports complete parse errors without claiming user execution' {
        $result = Invoke-HookedConsole -Lines @('1 + * 2', "'after parse error'")
        $result.Events.Count | Should -Be 4
        $result.Events[1].Data.Outcome | Should -BeExactly ParseError
        $result.Events[1].Data.ExecutionStarted | Should -BeFalse
        $result.Events[1].Data.Duration | Should -BeNullOrEmpty
        $result.Events[3].Data.Outcome | Should -BeExactly Succeeded
    }

    It 'Isolates errors, output and status while running subsequent handlers' {
        $result = Invoke-HookedConsole -Mode Noisy -Lines @('& $env:HOOK_TEST_PWSH -NoProfile -Command "exit 7"', '"STATUS:$?/$LASTEXITCODE/ERRORS:$($Error.Count)"; "DIAGS:$(@(Get-PSConsoleCommandLineHook -Diagnostic).Count)"')
        $result.Events.Count | Should -Be 8
        ($result.Events.Kind -join ',') | Should -BeExactly 'Starting,StartingSecond,Finished,FinishedSecond,Starting,StartingSecond,Finished,FinishedSecond'
        $result.Events[2].Data.NativeExitCode | Should -Be 7
        $result.Output | Should -Match 'STATUS:False/7/ERRORS:0'
        $result.Output | Should -Match 'DIAGS:[1-9]'
        $result.Output | Should -Not -Match 'HOOK OUTPUT'
        $result.Error | Should -Not -Match 'HOOK FAILURE|HOOK NONTERMINATING ERROR'
    }

    It 'Restores an initially absent LASTEXITCODE after callback native execution' {
        $result = Invoke-HookedConsole -Mode NoisyUnset -Lines @('"EXISTS:$(Test-Path variable:global:LASTEXITCODE)/ERRORS:$($Error.Count)"')
        $result.Output | Should -Match 'EXISTS:False/ERRORS:0'
        $result.Events.Count | Should -Be 2
        $result.Events[1].Data.NativeExitCode | Should -BeNullOrEmpty
    }

    It 'Contains callback exit without exiting the console' {
        $result = Invoke-HookedConsole -Mode Exit -Lines @("'still running'", 'exit 23')
        $result.ExitCode | Should -Be 23
        $result.Events.Count | Should -Be 4
        $result.Events[1].Data.Outcome | Should -BeExactly Succeeded
        $result.Events[3].Data.ShellExitCode | Should -Be 23
        $result.Output | Should -Match 'still running'
    }

    It 'Uses registration order and an invocation snapshot when unregistering' {
        $result = Invoke-HookedConsole -Mode Ordered -Lines @('Get-PSConsoleCommandLineHook | Unregister-PSConsoleCommandLineHook', "'disabled'")
        ($result.Events.Kind -join ',') | Should -BeExactly 'Starting,StartingSecond,Finished,FinishedSecond'
        $result.Output | Should -Match 'disabled'
    }

    It 'Supports independently registering either phase' {
        $result = Invoke-HookedConsole -Mode StartingOnly -Lines @("'start only'")
        $result.Events.Count | Should -Be 1
        $result.Events[0].Kind | Should -BeExactly Starting
        $result = Invoke-HookedConsole -Mode FinishedOnly -Lines @("'finish only'")
        $result.Events.Count | Should -Be 1
        $result.Events[0].Kind | Should -BeExactly Finished
        $result.Events[0].Data.Outcome | Should -BeExactly Succeeded
    }

    It 'Keeps the original execution path without registrations' {
        $result = Invoke-HookedConsole -Mode Disabled -Lines @("'no hooks'", 'exit 23')
        $result.Events.Count | Should -Be 0
        $result.Output | Should -Match 'no hooks'
        $result.ExitCode | Should -Be 23
    }

    It 'Hides the new commands when the experimental feature is disabled' {
        $result = Invoke-HookedConsole -Mode FeatureOff -Lines @("'feature off'")
        $result.Events.Count | Should -Be 0
        $result.Output | Should -Match 'AVAILABLE:False'
        $result.Output | Should -Match 'feature off'
    }

    It 'Excludes nested prompts and their exit codes' {
        $result = Invoke-HookedConsole -Lines @('$host.EnterNestedPrompt()', '& $env:HOOK_TEST_PWSH -NoProfile -Command "exit 7"', 'exit', "'back at main prompt'")
        $result.Events.Count | Should -Be 4
        $result.Events[0].Data.CommandLine | Should -BeExactly '$host.EnterNestedPrompt()'
        $result.Events[1].Data.NativeExitCode | Should -BeNullOrEmpty
        $result.Events[2].Data.CommandLine | Should -BeExactly "'back at main prompt'"
    }

    It 'Rejects registrations in other runspaces and excludes parallel work' {
        $line = '$ps = [powershell]::Create(); try { $null = $ps.AddScript("Register-PSConsoleCommandLineHook -Name invalid -Starting {}").Invoke(); "REJECTED:$($ps.HadErrors)" } finally { $ps.Dispose() }; 1..2 | ForEach-Object -Parallel { $_ + 1 }'
        $result = Invoke-HookedConsole -Lines @($line)
        $result.Events.Count | Should -Be 2
        $result.Output | Should -Match 'REJECTED:True'
    }

    It 'Validates registration, rejects nested callers and supports WhatIf' {
        $line = 'try { Register-PSConsoleCommandLineHook -Name invalid -ErrorAction Stop } catch { "MISSING:$($_.FullyQualifiedErrorId)" }; Get-PSConsoleCommandLineHook | Unregister-PSConsoleCommandLineHook -WhatIf; "COUNT:$(@(Get-PSConsoleCommandLineHook).Count)"'
        $result = Invoke-HookedConsole -Lines @($line, '$host.EnterNestedPrompt()', 'try { Register-PSConsoleCommandLineHook -Name nested -Starting {} -ErrorAction Stop } catch { "NESTED:$($_.FullyQualifiedErrorId)" }', 'exit')
        $result.Output | Should -Match 'MISSING:ConsoleCommandLineHookHandlerRequired'
        $result.Output | Should -Match 'COUNT:1'
        $result.Output | Should -Match 'NESTED:ConsoleCommandLineHooksUnsupportedHost'
        $result.Events.Count | Should -Be 4
    }

    It 'Preserves module handler state without recursive notifications' {
        $line = '$m = New-Module { $script:counter = 0; Register-PSConsoleCommandLineHook -Name module -Finished { param($e) $script:counter++; [Console]::WriteLine("MODULE:$script:counter") }; Export-ModuleMember }; Import-Module $m'
        $result = Invoke-HookedConsole -Lines @($line, "'one'", "'two'")
        $result.Events.Count | Should -Be 6
        $result.Output | Should -Match 'MODULE:1'
        $result.Output | Should -Match 'MODULE:2'
        $result.Output | Should -Not -Match 'MODULE:3'
    }

    It 'Releases handler objects after unregistration even when metadata is retained' {
        $line = '$b = { param($e) }.GetNewClosure(); $w = [WeakReference]::new($b); $token = Register-PSConsoleCommandLineHook -Name transient -Starting $b; $b = $null; $token | Unregister-PSConsoleCommandLineHook'
        $result = Invoke-HookedConsole -Lines @($line, '[GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect(); "ALIVE:$($w.IsAlive)"; "TOKEN:$($token.HasStartingHandler)"')
        $result.Output | Should -Match 'ALIVE:False'
        $result.Output | Should -Match 'TOKEN:True'
    }

    It 'Disables registration and notifications in NonInteractive mode' {
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $powershell
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        foreach ($a in @('-SettingsFile', $enabledSettings, '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'try { Register-PSConsoleCommandLineHook -Name invalid -Starting {} -ErrorAction Stop } catch { "REJECTED:$($_.FullyQualifiedErrorId)" }')) { $info.ArgumentList.Add($a) }
        $p = [Diagnostics.Process]::Start($info)
        try {
            $outTask = $p.StandardOutput.ReadToEndAsync()
            $errTask = $p.StandardError.ReadToEndAsync()
            $p.WaitForExit(15000) | Should -BeTrue
            $outTask.GetAwaiter().GetResult() | Should -Match 'REJECTED:ConsoleCommandLineHooksUnsupportedHost'
        } finally {
            if (!$p.HasExited) { $p.Kill($true) }
            $p.Dispose()
        }
    }

    It 'Bounds retained diagnostics without retaining command text' {
        $line = '1..150 | ForEach-Object { Register-PSConsoleCommandLineHook -Name fault -Finished { throw "sensitive text" } | Out-Null }'
        $result = Invoke-HookedConsole -Lines @($line, "'trigger'", '$d = @(Get-PSConsoleCommandLineHook -Diagnostic); "COUNT:$($d.Count)"; "LEAK:$([bool](($d | ConvertTo-Json -Compress) -match ''sensitive text''))"')
        $result.Output | Should -Match 'COUNT:128'
        $result.Output | Should -Match 'LEAK:False'
    }

    It 'Cancels execution after an explicit readiness signal and accepts the next command' -Skip:(!($IsLinux -or $IsMacOS)) {
        $line = '[IO.File]::WriteAllText($env:HOOK_TEST_GATE, "ready"); Start-Sleep -Seconds 30'
        $result = Invoke-HookedConsole -CancelFirst -Lines @($line, "'after cancel'")
        $result.Events.Count | Should -Be 4
        $result.Events[1].Data.Outcome | Should -BeExactly Cancelled
        $result.Events[1].Data.ExecutionStarted | Should -BeTrue
        $result.Events[3].Data.Outcome | Should -BeExactly Succeeded
        $result.Output | Should -Match 'after cancel'
    }

    It 'Skips user execution and remaining start handlers when start is cancelled' -Skip:(!($IsLinux -or $IsMacOS)) {
        $result = Invoke-HookedConsole -Mode CancelStarting -CancelFirst -Lines @("'skipped'", '"CANCELSTATUS:$?"; "after cancel"')
        $result.Events.Count | Should -Be 7
        $result.Events[0].Kind | Should -BeExactly Starting
        $result.Events[1].Kind | Should -BeExactly Finished
        $result.Events[1].Data.Outcome | Should -BeExactly Cancelled
        $result.Events[1].Data.ExecutionStarted | Should -BeFalse
        $result.Events[1].Data.Duration | Should -BeNullOrEmpty
        $result.Events[2].Kind | Should -BeExactly FinishedSecond
        $result.Output | Should -Match 'CANCELSTATUS:False'
        $result.Events[6].Data.Outcome | Should -BeExactly Succeeded
    }

    It 'Preserves the user result and skips remaining finish handlers when finish is cancelled' -Skip:(!($IsLinux -or $IsMacOS)) {
        $result = Invoke-HookedConsole -Mode CancelFinished -CancelFirst -Lines @("'cancel finish'", "'after cancel'")
        $result.Events.Count | Should -Be 7
        $result.Events[2].Data.Outcome | Should -BeExactly Succeeded
        $result.Events[3].Kind | Should -BeExactly Starting
        $result.Events[6].Data.Outcome | Should -BeExactly Succeeded
    }
}
