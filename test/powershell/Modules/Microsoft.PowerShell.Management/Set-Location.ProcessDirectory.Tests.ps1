# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe 'Linux/macOS console working directory synchronization' -Tags CI {
    BeforeAll {
        $originalLocation = Get-Location
        $originalLocationChangedAction = $ExecutionContext.InvokeCommand.LocationChangedAction

        function Get-PhysicalDirectory {
            param([string] $Path)

            # macOS commonly exposes /tmp through the /private/tmp symlink.
            # Query the physical path in a child so the test does not change process state.
            $info = [Diagnostics.ProcessStartInfo]::new('/bin/pwd')
            $info.ArgumentList.Add('-P')
            $info.WorkingDirectory = $Path
            $info.UseShellExecute = $false
            $info.RedirectStandardOutput = $true
            $process = [Diagnostics.Process]::Start($info)
            try {
                $output = $process.StandardOutput.ReadToEnd()
                $process.WaitForExit()
                $process.ExitCode | Should -Be 0
                $output.TrimEnd("`r", "`n")
            }
            finally {
                $process.Dispose()
            }
        }

        function Assert-SynchronizedDirectory {
            param([string] $Expected)

            (Get-Location).ProviderPath | Should -BeExactly $Expected
            [Environment]::CurrentDirectory | Should -BeExactly (Get-PhysicalDirectory $Expected)
            $env:PWD | Should -BeExactly $Expected
        }
    }

    BeforeEach {
        $ExecutionContext.InvokeCommand.LocationChangedAction = $null
        Set-Location -LiteralPath $TestDrive
    }

    AfterEach {
        $ExecutionContext.InvokeCommand.LocationChangedAction = $originalLocationChangedAction
        Set-Location -LiteralPath $originalLocation.Path
    }

    It 'Synchronizes literal filesystem paths and relative .NET file access' -Skip:(!($IsLinux -or $IsMacOS)) {
        $directory = New-Item -ItemType Directory -Path "$TestDrive/literal[directory]"
        Set-Location -LiteralPath $directory.FullName

        Assert-SynchronizedDirectory $directory.FullName
        [IO.File]::WriteAllText('relative.txt', 'synchronized')
        Get-Content -LiteralPath "$($directory.FullName)/relative.txt" | Should -BeExactly 'synchronized'
        (& /bin/pwd -P) | Should -BeExactly (Get-PhysicalDirectory $directory.FullName)
    }

    It 'Synchronizes custom filesystem drives using their provider paths' -Skip:(!($IsLinux -or $IsMacOS)) {
        $directory = New-Item -ItemType Directory -Path "$TestDrive/drive-root"
        $drive = New-PSDrive -Name SyncDirectoryTest -PSProvider FileSystem -Root $directory.FullName
        try {
            Set-Location "$($drive.Name):/"
            Assert-SynchronizedDirectory "$($directory.FullName)/"
        }
        finally {
            Set-Location -LiteralPath $TestDrive
            Remove-PSDrive -Name $drive.Name
        }
    }

    It 'Keeps the provider path in PWD while the process resolves directory symlinks' -Skip:(!($IsLinux -or $IsMacOS)) {
        $target = New-Item -ItemType Directory -Path "$TestDrive/symlink-target"
        $link = New-Item -ItemType SymbolicLink -Path "$TestDrive/symlink-directory" -Target $target.FullName
        Set-Location -LiteralPath $link.FullName

        Assert-SynchronizedDirectory $link.FullName
        [Environment]::CurrentDirectory | Should -BeExactly (Get-PhysicalDirectory $target.FullName)
        [IO.File]::WriteAllText('through-link.txt', 'synchronized')
        Get-Content -LiteralPath "$($target.FullName)/through-link.txt" | Should -BeExactly 'synchronized'
    }

    It 'Synchronizes Push-Location, Pop-Location, and location history' -Skip:(!($IsLinux -or $IsMacOS)) {
        $first = New-Item -ItemType Directory -Path "$TestDrive/first"
        $second = New-Item -ItemType Directory -Path "$TestDrive/second"
        Set-Location -LiteralPath $first.FullName

        Push-Location -LiteralPath $second.FullName
        try {
            Assert-SynchronizedDirectory $second.FullName
        }
        finally {
            Pop-Location
        }

        Assert-SynchronizedDirectory $first.FullName
        Set-Location -
        Assert-SynchronizedDirectory $second.FullName
        Set-Location +
        Assert-SynchronizedDirectory $first.FullName
    }

    It 'Keeps the filesystem directory when entering another provider' -Skip:(!($IsLinux -or $IsMacOS)) {
        $directory = [Environment]::CurrentDirectory
        $pwdValue = $env:PWD
        Set-Location Env:

        (Get-Location).Provider.Name | Should -BeExactly 'Environment'
        [Environment]::CurrentDirectory | Should -BeExactly $directory
        $env:PWD | Should -BeExactly $pwdValue
    }

    It 'Synchronizes before invoking the user location callback' -Skip:(!($IsLinux -or $IsMacOS)) {
        $directory = New-Item -ItemType Directory -Path "$TestDrive/callback"
        $observed = [System.Collections.Generic.List[string]]::new()
        $ExecutionContext.InvokeCommand.LocationChangedAction = {
            $observed.Add([Environment]::CurrentDirectory)
            $observed.Add($env:PWD)
        }.GetNewClosure()

        Set-Location -LiteralPath $directory.FullName
        $observed.Count | Should -Be 2
        $observed[0] | Should -BeExactly (Get-PhysicalDirectory $directory.FullName)
        $observed[1] | Should -BeExactly $directory.FullName
    }

    It 'Keeps all directory state after a failed location change' -Skip:(!($IsLinux -or $IsMacOS)) {
        $directory = (Get-Location).ProviderPath
        { Set-Location -LiteralPath "$TestDrive/missing" -ErrorAction Stop } | Should -Throw
        Assert-SynchronizedDirectory $directory
    }

    It 'Restores the PowerShell location when chdir is denied' -Skip:(!($IsLinux -or $IsMacOS) -or ((& id -u) -eq '0')) {
        $directory = (Get-Location).ProviderPath
        $denied = New-Item -ItemType Directory -Path "$TestDrive/denied"
        try {
            & chmod 600 $denied.FullName
            { Set-Location -LiteralPath $denied.FullName -ErrorAction Stop } | Should -Throw
            Assert-SynchronizedDirectory $directory
        }
        finally {
            & chmod 700 $denied.FullName
        }
    }

    It 'Does not synchronize another runspace with the process' -Skip:(!($IsLinux -or $IsMacOS)) {
        $directory = (Get-Location).ProviderPath
        $other = New-Item -ItemType Directory -Path "$TestDrive/other-runspace"
        $powerShell = [powershell]::Create()
        try {
            $null = $powerShell.AddScript('param($path) Set-Location -LiteralPath $path; (Get-Location).ProviderPath').AddArgument($other.FullName)
            $result = $powerShell.Invoke()
            $powerShell.HadErrors | Should -BeFalse
            $result[0] | Should -BeExactly $other.FullName
            Assert-SynchronizedDirectory $directory
        }
        finally {
            $powerShell.Dispose()
        }
    }

    It 'Does not synchronize parallel runspaces with the process' -Skip:(!($IsLinux -or $IsMacOS)) {
        $directory = (Get-Location).ProviderPath
        $other = New-Item -ItemType Directory -Path "$TestDrive/parallel-runspaces"
        $otherPath = $other.FullName
        $result = 1..2 | ForEach-Object -Parallel {
            Set-Location -LiteralPath $using:otherPath
            (Get-Location).ProviderPath
        }

        $result.Count | Should -Be 2
        $result[0] | Should -BeExactly $otherPath
        $result[1] | Should -BeExactly $otherPath
        Assert-SynchronizedDirectory $directory
    }
}
