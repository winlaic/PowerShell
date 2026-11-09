# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Measures complete redirected console submissions, excluding startup and warmup.
# This is a manual benchmark: timing is environment-dependent, not a CI assertion.
[CmdletBinding()]
param(
    [string] $PowerShellPath = (Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })),
    [ValidateRange(1, 100000)] [int] $Iterations = 1000,
    [ValidateRange(1, 100)] [int] $Samples = 3
)

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('pwsh-hook-benchmark-' + [guid]::NewGuid())
$null = New-Item -ItemType Directory $temporary
try {
    $bootstrap = Join-Path $temporary 'bootstrap.ps1'
    @'
Remove-Module PSReadLine -ErrorAction Ignore
function prompt { '' }
if ($env:PS_HOOK_BENCHMARK_MODE -eq 'EmptyHandlers') {
    $null = Register-PSConsoleCommandLineHook -Name benchmark -Starting {} -Finished {}
}
'@ | Set-Content $bootstrap
    foreach ($mode in @('FeatureOff', 'NoRegistrations', 'EmptyHandlers')) {
        $settings = Join-Path $temporary "$mode.json"
        $(if ($mode -eq 'FeatureOff') { '{"ExperimentalFeatures":[]}' } else { '{"ExperimentalFeatures":["PSConsoleCommandLineHooks"]}' }) | Set-Content $settings
        for ($sample = 0; $sample -lt $Samples; $sample++) {
            $info = [Diagnostics.ProcessStartInfo]::new()
            $info.FileName = $PowerShellPath
            $info.UseShellExecute = $false
            $info.RedirectStandardInput = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            foreach ($a in @('-SettingsFile', $settings, '-NoLogo', '-NoProfile', '-NoExit', '-File', $bootstrap)) { $info.ArgumentList.Add($a) }
            $info.Environment['PS_HOOK_BENCHMARK_MODE'] = $mode
            $process = [Diagnostics.Process]::Start($info)
            try {
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                1..30 | ForEach-Object { $process.StandardInput.WriteLine('$null = 1') }
                $process.StandardInput.WriteLine('$global:benchAlloc = [GC]::GetTotalAllocatedBytes($true); $global:benchStart = [Diagnostics.Stopwatch]::GetTimestamp()')
                1..$Iterations | ForEach-Object { $process.StandardInput.WriteLine('$null = 1') }
                $process.StandardInput.WriteLine('[Console]::WriteLine("BENCH:{0}:{1}", [Diagnostics.Stopwatch]::GetElapsedTime($global:benchStart).TotalMilliseconds, ([GC]::GetTotalAllocatedBytes($true) - $global:benchAlloc))')
                $process.StandardInput.Close()
                if (!$process.WaitForExit(120000)) { throw "Benchmark timed out: $mode" }
                $output = $stdout.GetAwaiter().GetResult()
                $errors = $stderr.GetAwaiter().GetResult()
                if ($process.ExitCode -ne 0 -or $output -notmatch 'BENCH:([\d.,]+):(\d+)') { throw "Benchmark failed: $mode $errors" }
                [pscustomobject]@{
                    Mode = $mode
                    Sample = $sample + 1
                    Iterations = $Iterations
                    MicrosecondsPerSubmission = 1000 * [double]::Parse($Matches[1], [cultureinfo]::CurrentCulture) / $Iterations
                    AllocatedBytesPerSubmission = [long]$Matches[2] / $Iterations
                }
            }
            finally {
                if (!$process.HasExited) { $process.Kill($true) }
                $process.Dispose()
            }
        }
    }
}
finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
