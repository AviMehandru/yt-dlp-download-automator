<#
    scripts/ytdl.ps1 -- the single argument parser for every platform.

    Tested by substituting a recording stand-in for run_ytdlp.ps1 whose
    param() block is a byte-for-byte copy of the real one, then reading back
    exactly which parameters the launcher produced. That mirroring is not
    incidental: it means these tests also fail if ytdl.ps1 ever emits an
    argument run_ytdlp.ps1 could not bind, which is the actual failure the
    user would see and which no amount of reading either file in isolation
    would reveal.

    The single-extra-argument case has its own test because it is a
    regression, not a hypothetical: `ytdl <url> /some/path` used to crash
    with "[System.Char] has no method StartsWith", because a one-element
    branch of an if-expression unrolls to a bare string and $rest[0] then
    indexes a CHARACTER. It was found by running the thing, not by reading
    it, which is precisely the argument for having this file.
#>

Describe 'ytdl.ps1 argument parsing' {

    $root = New-TestRoot -Label 'launcher'
    Install-PipelineInto -TestRoot $root -RepoRoot $script:RepoRoot

    $capturePath = Join-Path $root.Root 'launcher-capture.json'
    $env:YTDL_TEST_CAPTURE = $capturePath

    # The stand-in. Its param() block deliberately duplicates run_ytdlp.ps1's
    # own, including [ValidateRange(1,64)] on -Workers, so a launcher that
    # emitted an out-of-range or misspelled parameter fails here the same way
    # it would in production.
    $standIn = @'
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $false)][string]$DataRoot = "",
    [Parameter(Mandatory = $false)][switch]$BreakOnExisting,
    [Parameter(Mandatory = $false)][string]$PlaylistItems = "",
    [Parameter(Mandatory = $false)][string]$DateAfter = "",
    [Parameter(Mandatory = $false)][switch]$LazyPlaylist,
    [Parameter(Mandatory = $false)][ValidateRange(1, 64)][int]$Workers = 1
)
[ordered]@{
    Url             = $Url
    DataRoot        = $DataRoot
    BreakOnExisting = [bool]$BreakOnExisting
    PlaylistItems   = $PlaylistItems
    DateAfter       = $DateAfter
    LazyPlaylist    = [bool]$LazyPlaylist
    Workers         = $Workers
} | ConvertTo-Json | Set-Content -LiteralPath $env:YTDL_TEST_CAPTURE
'@
    Set-Content -LiteralPath (Join-Path $root.InstallRoot 'scripts/run_ytdlp.ps1') -Value $standIn -Encoding utf8

    function Invoke-Launcher {
        param([AllowEmptyCollection()][string[]]$Arguments = @())
        if (Test-Path -LiteralPath $capturePath) { Remove-Item -LiteralPath $capturePath -Force }
        $result = Invoke-YtdlLauncher -TestRoot $root -Arguments $Arguments
        $captured = if (Test-Path -LiteralPath $capturePath) {
            Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
        } else { $null }
        $result | Add-Member -NotePropertyName Params -NotePropertyValue $captured -Force
        return $result
    }

    $url = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'

    It 'prints usage and exits 1 with no arguments' {
        $r = Invoke-Launcher -Arguments @()
        Assert-Equal 1 $r.ExitCode 'no URL is a usage error, not a crash'
        Assert-Match 'Usage: ytdl' $r.Output
        # Write-Error would render a multi-line ERROR RECORD with a caret
        # diagram for "you forgot the URL". [Console]::Error keeps it to one
        # line, and that difference is the whole reason Write-Usage exists.
        Assert-NotMatch 'CategoryInfo|FullyQualifiedErrorId' $r.Output `
            'usage text must not come out as a PowerShell error record'
    }

    It 'passes a bare URL through untouched' {
        $r = Invoke-Launcher -Arguments @($url)
        Assert-Equal 0 $r.ExitCode
        Assert-True ($null -ne $r.Params) 'run_ytdlp.ps1 was never reached'
        Assert-Equal $url $r.Params.Url 'the "=" in a watch URL must survive the shims'
        Assert-Equal '' $r.Params.DataRoot
        Assert-Equal 1 $r.Params.Workers
        Assert-False $r.Params.BreakOnExisting
    }

    It 'accepts the legacy positional path as the only extra argument' {
        # The regression case. Exactly ONE argument after the URL is what
        # collapsed $rest from an array into a bare string.
        $r = Invoke-Launcher -Arguments @($url, '/tmp/some archive path')
        Assert-Equal 0 $r.ExitCode 'a single positional path must not crash the parser'
        Assert-NotMatch 'StartsWith|System\.Char' $r.Output `
            'the array-unrolling guard on $rest has regressed'
        Assert-Equal '/tmp/some archive path' $r.Params.DataRoot 'a path with spaces must survive as one argument'
    }

    It 'accepts --path as the explicit form' {
        $r = Invoke-Launcher -Arguments @($url, '--path', '/tmp/explicit root')
        Assert-Equal 0 $r.ExitCode
        Assert-Equal '/tmp/explicit root' $r.Params.DataRoot
    }

    It 'translates --sync to -BreakOnExisting' {
        $r = Invoke-Launcher -Arguments @($url, '--sync')
        Assert-Equal 0 $r.ExitCode
        Assert-True $r.Params.BreakOnExisting
    }

    It 'translates --items to -PlaylistItems' {
        $r = Invoke-Launcher -Arguments @($url, '--items', '5,8,10-15')
        Assert-Equal 0 $r.ExitCode
        Assert-Equal '5,8,10-15' $r.Params.PlaylistItems
    }

    It 'translates --after to -DateAfter' {
        $r = Invoke-Launcher -Arguments @($url, '--after', '20250101')
        Assert-Equal 0 $r.ExitCode
        Assert-Equal '20250101' $r.Params.DateAfter
    }

    It 'translates --lazy to -LazyPlaylist' {
        $r = Invoke-Launcher -Arguments @($url, '--lazy')
        Assert-Equal 0 $r.ExitCode
        Assert-True $r.Params.LazyPlaylist
    }

    It 'translates --workers to -Workers' {
        $r = Invoke-Launcher -Arguments @($url, '--workers', '4')
        Assert-Equal 0 $r.ExitCode
        Assert-Equal 4 $r.Params.Workers
    }

    It 'accepts every option at once, in any order, after a positional path' {
        $r = Invoke-Launcher -Arguments @(
            $url, '/tmp/mixed root', '--workers', '3', '--sync',
            '--after', '20240301', '--items', '1-20', '--lazy'
        )
        Assert-Equal 0 $r.ExitCode
        Assert-Equal '/tmp/mixed root' $r.Params.DataRoot
        Assert-Equal 3      $r.Params.Workers
        Assert-Equal '1-20' $r.Params.PlaylistItems
        Assert-Equal '20240301' $r.Params.DateAfter
        Assert-True $r.Params.BreakOnExisting
        Assert-True $r.Params.LazyPlaylist
    }

    It 'rejects --workers 0 and non-numeric worker counts before starting anything' {
        foreach ($bad in @('0', 'abc', '-1', '2.5')) {
            $r = Invoke-Launcher -Arguments @($url, '--workers', $bad)
            Assert-Equal 1 $r.ExitCode "--workers $bad should be rejected"
            Assert-Match 'requires a positive integer' $r.Output
            Assert-True ($null -eq $r.Params) `
                "--workers $bad reached run_ytdlp.ps1 -- validation must happen in the launcher so the message is readable"
        }
    }

    It 'rejects an option given without its value' {
        foreach ($opt in @('--items', '--after', '--workers', '--path')) {
            $r = Invoke-Launcher -Arguments @($url, $opt)
            Assert-Equal 1 $r.ExitCode "$opt with no value should be a usage error"
            Assert-Match 'requires' $r.Output
        }
    }

    It 'rejects an unknown option instead of forwarding it' {
        $r = Invoke-Launcher -Arguments @($url, '--turbo')
        Assert-Equal 1 $r.ExitCode
        Assert-Match 'Unknown option: --turbo' $r.Output
        Assert-Match 'Usage: ytdl' $r.Output 'an unknown option should also show usage'
    }

    It 'propagates run_ytdlp.ps1 exit codes rather than always reporting success' {
        Set-Content -LiteralPath (Join-Path $root.InstallRoot 'scripts/run_ytdlp.ps1') `
                    -Value "param([string]`$Url)`nexit 42" -Encoding utf8
        try {
            $r = Invoke-YtdlLauncher -TestRoot $root -Arguments @($url)
            Assert-Equal 42 $r.ExitCode 'the launcher must pass the child exit code through'
        } finally {
            Set-Content -LiteralPath (Join-Path $root.InstallRoot 'scripts/run_ytdlp.ps1') -Value $standIn -Encoding utf8
        }
    }
}

Describe 'POSIX ytdl shim' {

    It 'reports a clear error when the launcher is missing' {
        if ($IsWindows) { Skip-Test 'scripts/ytdl is the Linux/macOS shim; ytdl.cmd is the Windows one.' }
        if (-not (Test-HasCommand 'bash')) { Skip-Test 'bash is not on PATH.' }
        $empty = New-TestRoot -Label 'shim-empty'
        $shim = Join-Path $script:RepoRoot 'scripts/ytdl'
        $out = & bash -c "YTDLP_INSTALL_ROOT='$($empty.InstallRoot)' '$shim' https://example.invalid 2>&1"
        Assert-Equal 1 $LASTEXITCODE
        Assert-Match 'launcher not found' $out
        Assert-Match 'YTDLP_INSTALL_ROOT' $out 'the error should say how to point at a non-default install'
        Remove-TestRoot $empty
    }

    It 'honours YTDLP_INSTALL_ROOT when locating ytdl.ps1' {
        if ($IsWindows) { Skip-Test 'POSIX shim only.' }
        if (-not (Test-HasCommand 'bash')) { Skip-Test 'bash is not on PATH.' }
        $r = New-TestRoot -Label 'shim-root'
        Install-PipelineInto -TestRoot $r -RepoRoot $script:RepoRoot
        # A run_ytdlp.ps1 that just announces itself, so reaching it proves
        # the whole shim -> ytdl.ps1 -> run_ytdlp.ps1 chain resolved.
        Set-Content -LiteralPath (Join-Path $r.InstallRoot 'scripts/run_ytdlp.ps1') `
                    -Value "param([string]`$Url)`nWrite-Output `"REACHED:`$Url`"" -Encoding utf8
        $shim = Join-Path $script:RepoRoot 'scripts/ytdl'
        $out = & bash -c "YTDLP_INSTALL_ROOT='$($r.InstallRoot)' '$shim' https://youtu.be/abc123 2>&1"
        Assert-Match 'REACHED:https://youtu.be/abc123' $out
        Remove-TestRoot $r
    }
}
