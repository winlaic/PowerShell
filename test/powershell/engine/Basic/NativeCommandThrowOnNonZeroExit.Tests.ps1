# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe 'Experimental native command nonzero exit policy' -Tags CI {
    BeforeAll {
        $powershell = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $exe = (Get-Command $(if ($IsWindows) { 'testexe.exe' } else { 'testexe' }) -CommandType Application).Source
        $enabledSettings = Join-Path $TestDrive 'enabled.json'
        $disabledSettings = Join-Path $TestDrive 'disabled.json'
        '{"ExperimentalFeatures":["PSNativeCommandThrowOnNonZeroExit"]}' | Set-Content $enabledSettings
        '{"ExperimentalFeatures":[]}' | Set-Content $disabledSettings

        function Invoke-NativeExitPolicy {
            param([string] $Command, [switch] $Enabled, [string] $File)
            $info = [Diagnostics.ProcessStartInfo]::new()
            $info.FileName = $powershell
            $info.UseShellExecute = $false
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $settings = if ($Enabled) { $enabledSettings } else { $disabledSettings }
            foreach ($a in @('-SettingsFile', $settings, '-NoLogo', '-NoProfile')) { $info.ArgumentList.Add($a) }
            if ($File) {
                $info.ArgumentList.Add('-File')
                $info.ArgumentList.Add($File)
            } else {
                $info.ArgumentList.Add('-Command')
                $info.ArgumentList.Add($Command)
            }
            $info.Environment['NATIVE_EXIT_TEST_EXE'] = $exe
            $process = [Diagnostics.Process]::Start($info)
            try {
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                if (!$process.WaitForExit(20000)) { throw 'Native exit policy test timed out' }
                [pscustomobject]@{
                    Output = $stdout.GetAwaiter().GetResult()
                    Error = $stderr.GetAwaiter().GetResult()
                    ExitCode = $process.ExitCode
                }
            } finally {
                if (!$process.HasExited) { $process.Kill($true) }
                $process.Dispose()
            }
        }
    }

    It 'Throws independently of preferences: native=<NativePreference>, error=<ErrorPreference>' -TestCases @(
        @{ NativePreference = '$true'; ErrorPreference = 'Continue' }
        @{ NativePreference = '$true'; ErrorPreference = 'Stop' }
        @{ NativePreference = '$true'; ErrorPreference = 'SilentlyContinue' }
        @{ NativePreference = '$true'; ErrorPreference = 'Ignore' }
        @{ NativePreference = '$false'; ErrorPreference = 'Continue' }
        @{ NativePreference = '$false'; ErrorPreference = 'Stop' }
        @{ NativePreference = '$false'; ErrorPreference = 'SilentlyContinue' }
        @{ NativePreference = '$false'; ErrorPreference = 'Ignore' }
    ) {
        param($NativePreference, $ErrorPreference)
        $command = '$PSNativeCommandUseErrorActionPreference = ' + $NativePreference + '; $ErrorActionPreference = ''' + $ErrorPreference + '''; ' + @'
$Error.Clear()
try {
    & $env:NATIVE_EXIT_TEST_EXE -returncode 17 > $null
    'UNREACHABLE'
} catch [System.Management.Automation.NativeCommandExitException] {
    "CAUGHT:$($_.Exception.ExitCode)/$LASTEXITCODE"
    "ID:$($_.FullyQualifiedErrorId)"
    "PATH:$($_.Exception.Path -eq $env:NATIVE_EXIT_TEST_EXE)"
    "PID:$($_.Exception.ProcessId -gt 0)"
} finally { 'FINALLY' }
"ERRORS:$($Error.Count)"
"PREFERENCES:$PSNativeCommandUseErrorActionPreference/$ErrorActionPreference"
'@
        $result = Invoke-NativeExitPolicy -Enabled -Command $command
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'CAUGHT:17/17'
        $result.Output | Should -Match 'ID:ProgramExitedWithNonZeroCode'
        $result.Output | Should -Match 'PATH:True'
        $result.Output | Should -Match 'PID:True'
        $result.Output | Should -Match 'FINALLY'
        $result.Output | Should -Match 'ERRORS:1'
        $result.Output | Should -Match "PREFERENCES:$($NativePreference -eq '$true')/$ErrorPreference"
        $result.Output | Should -Not -Match 'UNREACHABLE'
    }

    It 'Throws when the native preference variable is unset' {
        $result = Invoke-NativeExitPolicy -Enabled -Command 'Remove-Variable PSNativeCommandUseErrorActionPreference -ErrorAction Ignore; try { & $env:NATIVE_EXIT_TEST_EXE -returncode 7 > $null; "UNREACHABLE" } catch { "CAUGHT:$($_.Exception.ExitCode)" }'
        $result.Output | Should -Match 'CAUGHT:7'
        $result.Output | Should -Not -Match 'UNREACHABLE'
    }

    It 'Stops an unhandled command rather than just reporting an error' {
        $result = Invoke-NativeExitPolicy -Enabled -Command '$PSNativeCommandUseErrorActionPreference = $false; $ErrorActionPreference = "Continue"; & $env:NATIVE_EXIT_TEST_EXE -returncode 7 > $null; "UNREACHABLE"'
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Not -Match 'UNREACHABLE'
        $result.Error | Should -Match '7'
    }

    It 'Stops a script file and propagates failure out of a function' {
        $script = Join-Path $TestDrive 'failure.ps1'
        'function Invoke-Failure { & $env:NATIVE_EXIT_TEST_EXE -returncode 7 > $null; "FUNCTION UNREACHABLE" }; Invoke-Failure; "SCRIPT UNREACHABLE"' | Set-Content $script
        $result = Invoke-NativeExitPolicy -Enabled -File $script
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Not -Match 'UNREACHABLE'
    }

    It 'Checks a failing upstream pipeline member even when the final native command succeeds' {
        $result = Invoke-NativeExitPolicy -Enabled -Command 'try { & $env:NATIVE_EXIT_TEST_EXE -returncode 7 | & $env:NATIVE_EXIT_TEST_EXE -returncode 0; "UNREACHABLE" } catch { "CAUGHT:$($_.Exception.ExitCode)" }'
        $result.Output | Should -Match 'CAUGHT:7'
        $result.Output | Should -Not -Match 'UNREACHABLE'
    }

    It 'Does not suppress termination through redirection or pipeline chains' -TestCases @(
        @{ Suffix = '2>$null' }
        @{ Suffix = '2>&1 >$null' }
        @{ Suffix = '|| "FALLBACK"' }
    ) {
        param($Suffix)
        $result = Invoke-NativeExitPolicy -Enabled -Command ('try { & $env:NATIVE_EXIT_TEST_EXE -returncode 7 ' + $Suffix + '; "UNREACHABLE" } catch { "CAUGHT:$($_.Exception.ExitCode)" }')
        $result.Output | Should -Match 'CAUGHT:7'
        $result.Output | Should -Not -Match 'UNREACHABLE|FALLBACK'
    }

    It 'Supports normal trap handling' {
        $result = Invoke-NativeExitPolicy -Enabled -Command 'trap { "TRAPPED:$LASTEXITCODE"; continue }; & $env:NATIVE_EXIT_TEST_EXE -returncode 9 > $null; "AFTER TRAP"'
        $result.Output | Should -Match 'TRAPPED:9'
        $result.Output | Should -Match 'AFTER TRAP'
    }

    It 'Does not turn stderr with zero exit into an exit failure' {
        $result = Invoke-NativeExitPolicy -Enabled -Command '$PSNativeCommandUseErrorActionPreference = $false; $ErrorActionPreference = "Stop"; & $env:NATIVE_EXIT_TEST_EXE -stderr "expected stderr"; "AFTER:$LASTEXITCODE"'
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'AFTER:0'
        $result.Error | Should -Match 'expected stderr'
    }

    It 'Does not change ordinary PowerShell nonterminating errors' {
        $result = Invoke-NativeExitPolicy -Enabled -Command '$ErrorActionPreference = "Continue"; Write-Error "ordinary error"; "AFTER CMDLET"'
        $result.Output | Should -Match 'AFTER CMDLET'
        $result.Error | Should -Match 'ordinary error'
    }

    It 'Does not reinterpret a ps1 script exit as a native exit' {
        $script = Join-Path $TestDrive 'exit.ps1'
        'exit 19' | Set-Content $script
        $result = Invoke-NativeExitPolicy -Enabled -Command "& '$script'; 'AFTER SCRIPT'; exit 0"
        $result.Output | Should -Match 'AFTER SCRIPT'
        $result.ExitCode | Should -Be 0
    }

    It 'Retains the original no-error path when disabled' {
        $result = Invoke-NativeExitPolicy -Command '$PSNativeCommandUseErrorActionPreference = $false; $ErrorActionPreference = "Stop"; & $env:NATIVE_EXIT_TEST_EXE -returncode 7 > $null; "AFTER:$LASTEXITCODE"'
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'AFTER:7'
        $result.Error | Should -BeNullOrEmpty
    }

    It 'Retains the original nonterminating error path when disabled' {
        $result = Invoke-NativeExitPolicy -Command '$PSNativeCommandUseErrorActionPreference = $true; $ErrorActionPreference = "Continue"; & $env:NATIVE_EXIT_TEST_EXE -returncode 7 > $null; "AFTER:$LASTEXITCODE"'
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'AFTER:7'
        $result.Error | Should -Match '7'
    }
}
