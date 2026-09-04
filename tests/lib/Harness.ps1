<#
.SYNOPSIS
    A dependency-free test framework for the yt-dlp archival pipeline.

.DESCRIPTION
    Deliberately NOT Pester. Pester is the obvious choice and was rejected
    for the same reason this repo has no package manifest: adding it makes
    "can I run the tests" depend on a module install that has to succeed on
    Windows, macOS and four Linux families before a single assertion runs.
    The whole point of this suite is to be the thing you reach for when you
    are not sure the environment is right -- it cannot itself be the part
    that fails to install. Everything here is stock pwsh 7.

    What it gives you is the small subset of a test framework this project
    actually uses: Describe/It for grouping, a set of assertions whose
    failure messages say what was expected and what was found, per-test
    output capture, and a skip mechanism (because "ffmpeg is not installed
    on this machine" must read as SKIP, not FAIL -- a suite that cries wolf
    on an optional dependency gets ignored, which is the failure mode this
    project already documented for checksums.sha256).

    Test files are dot-sourced by the runner, so everything defined here is
    in scope for them.
#>

Set-StrictMode -Version Latest

# Skips travel as a thrown string with this prefix rather than a custom
# exception type. A class defined in a dot-sourced script is awkward to
# reference from another dot-sourced script (the type is not visible until
# the defining file has been parsed AND run, which breaks if a suite is run
# on its own), and a sentinel string has none of that ordering fragility.
$script:SkipSentinel = '@@YTDLP_TEST_SKIP@@'

$script:Results      = [System.Collections.Generic.List[object]]::new()
$script:CurrentSuite = '(none)'
$script:CurrentFile  = ''
# Deliberately NOT named $script:Filter / $script:StopOnFail / $script:Verbose.
# This file is DOT-SOURCED by run-tests.ps1, which means these assignments
# land in the runner's own script scope -- the same scope its param() block
# lives in. A name collision there does not shadow the parameter, it
# OVERWRITES it, and it happens after binding, so `-Filter '*x*'` silently
# became $null and every test ran. The Test* prefix keeps the harness's
# state and the runner's parameters in separate namespaces.
$script:TestFilter      = $null
$script:StopOnFirstFail = $false
$script:ShowTestOutput  = $false

# ---------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------

function Describe {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Name,
        [Parameter(Mandatory = $true, Position = 1)][scriptblock]$Body
    )
    $previous = $script:CurrentSuite
    $script:CurrentSuite = $Name
    try {
        & $Body
    } catch {
        # A throw in the Describe body itself (outside any It) would
        # otherwise silently drop every remaining test in the file. Record
        # it as a failure attributed to the group so it cannot vanish.
        Add-Result -Name '(suite body)' -Status 'Fail' -DurationMs 0 `
                   -Message "The Describe body threw before its tests could run: $($_.Exception.Message)" `
                   -Detail ($_.ScriptStackTrace)
    } finally {
        $script:CurrentSuite = $previous
    }
}

function It {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Name,
        [Parameter(Mandatory = $true, Position = 1)][scriptblock]$Body
    )

    if ($script:TestFilter -and ("$($script:CurrentSuite) $Name" -notlike $script:TestFilter)) { return }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $captured = $null
    try {
        # *>&1 folds every stream (output, warning, verbose, information,
        # and native stderr) into one capture, so a test that fails because
        # a script wrote a warning has that warning attached to it in the
        # report rather than scrolling past in the console.
        $captured = & $Body *>&1 | ForEach-Object { "$_" }
        $sw.Stop()
        Add-Result -Name $Name -Status 'Pass' -DurationMs $sw.ElapsedMilliseconds -Output $captured
    } catch {
        $sw.Stop()
        $msg = "$($_.Exception.Message)"
        if ($msg.StartsWith($script:SkipSentinel)) {
            Add-Result -Name $Name -Status 'Skip' -DurationMs $sw.ElapsedMilliseconds `
                       -Message $msg.Substring($script:SkipSentinel.Length) -Output $captured
        } else {
            Add-Result -Name $Name -Status 'Fail' -DurationMs $sw.ElapsedMilliseconds `
                       -Message $msg -Detail ($_.ScriptStackTrace) -Output $captured
            if ($script:StopOnFirstFail) { throw "Stopping: -StopOnFail is set and '$Name' failed." }
        }
    }
}

function Skip-Test {
    param([Parameter(Mandatory = $true, Position = 0)][string]$Reason)
    throw ($script:SkipSentinel + $Reason)
}

function Add-Result {
    param(
        [string]$Name,
        [ValidateSet('Pass', 'Fail', 'Skip')][string]$Status,
        [long]$DurationMs = 0,
        [string]$Message = '',
        [string]$Detail = '',
        $Output = $null
    )
    # Built OUTSIDE the hashtable literal, and typed [object[]]. Assigning
    # `if (...) { @() } else { @($Output) }` directly to a member unrolls
    # through the pipeline, so a single captured line arrives as a bare
    # string and $record.Output.Count then throws under StrictMode. Exactly
    # the array-unrolling trap ytdl.ps1's $rest and run_ytdlp.ps1's
    # $jsRuntimeArgs both carry comments about -- it is not a PowerShell
    # quirk you learn once.
    [object[]]$capturedLines = @()
    if ($null -ne $Output) { $capturedLines = @($Output) }

    $record = [pscustomobject]@{
        Suite      = $script:CurrentSuite
        File       = $script:CurrentFile
        Name       = $Name
        Status     = $Status
        DurationMs = $DurationMs
        Message    = $Message
        Detail     = $Detail
        Output     = $capturedLines
    }
    $script:Results.Add($record) | Out-Null

    $glyph = switch ($Status) { 'Pass' { 'PASS' } 'Fail' { 'FAIL' } 'Skip' { 'SKIP' } }
    $color = switch ($Status) { 'Pass' { 'Green' } 'Fail' { 'Red' } 'Skip' { 'DarkYellow' } }
    Write-Host ("  [{0}] {1}" -f $glyph, $Name) -ForegroundColor $color
    if ($Status -eq 'Fail') {
        foreach ($line in ($Message -split "`n")) { Write-Host ("         $line") -ForegroundColor Red }
    }
    if ($Status -eq 'Skip' -and $Message) {
        Write-Host ("         $Message") -ForegroundColor DarkYellow
    }
    if ($script:ShowTestOutput -and $record.Output.Count -gt 0) {
        foreach ($line in $record.Output) { Write-Host ("         | $line") -ForegroundColor DarkGray }
    }
}

# ---------------------------------------------------------------------
# Assertions
#
# Every failure message names the expectation AND the actual value. A bare
# "assertion failed" costs a debugging round-trip on a machine you may not
# be sitting at -- these tests are meant to be run on four platforms and
# reported back from three of them.
# ---------------------------------------------------------------------

function Assert-True {
    param([Parameter(Position = 0)]$Condition, [Parameter(Position = 1)][string]$Because = 'expected a true value')
    if (-not $Condition) { throw "Assert-True failed: $Because (got: '$Condition')" }
}

function Assert-False {
    param([Parameter(Position = 0)]$Condition, [Parameter(Position = 1)][string]$Because = 'expected a false value')
    if ($Condition) { throw "Assert-False failed: $Because (got: '$Condition')" }
}

function Assert-Equal {
    param([Parameter(Position = 0)]$Expected, [Parameter(Position = 1)]$Actual, [Parameter(Position = 2)][string]$Because = '')
    if ($Expected -ne $Actual) {
        throw ("Assert-Equal failed{0}`n  expected: [{1}]`n  actual:   [{2}]" -f `
               $(if ($Because) { ": $Because" } else { '' }), $Expected, $Actual)
    }
}

function Assert-NotEqual {
    param([Parameter(Position = 0)]$NotExpected, [Parameter(Position = 1)]$Actual, [Parameter(Position = 2)][string]$Because = '')
    if ($NotExpected -eq $Actual) {
        throw ("Assert-NotEqual failed{0}`n  both values were: [{1}]" -f `
               $(if ($Because) { ": $Because" } else { '' }), $Actual)
    }
}

function Assert-Match {
    param([Parameter(Position = 0)][string]$Pattern, [Parameter(Position = 1)]$Text, [Parameter(Position = 2)][string]$Because = '')
    $joined = ($Text | ForEach-Object { "$_" }) -join "`n"
    if ($joined -notmatch $Pattern) {
        throw ("Assert-Match failed{0}`n  pattern:  /{1}/`n  searched: {2}" -f `
               $(if ($Because) { ": $Because" } else { '' }), $Pattern, (Format-Excerpt $joined))
    }
}

function Assert-NotMatch {
    param([Parameter(Position = 0)][string]$Pattern, [Parameter(Position = 1)]$Text, [Parameter(Position = 2)][string]$Because = '')
    $joined = ($Text | ForEach-Object { "$_" }) -join "`n"
    if ($joined -match $Pattern) {
        throw ("Assert-NotMatch failed{0}`n  pattern must NOT appear: /{1}/`n  but matched: [{2}]" -f `
               $(if ($Because) { ": $Because" } else { '' }), $Pattern, $Matches[0])
    }
}

function Assert-PathExists {
    param([Parameter(Position = 0)][string]$Path, [Parameter(Position = 1)][string]$Because = '')
    if (-not (Test-Path -LiteralPath $Path)) {
        $parent = Split-Path $Path -Parent
        $siblings = if (Test-Path -LiteralPath $parent) {
            (Get-ChildItem -LiteralPath $parent -Force | Select-Object -First 25 -ExpandProperty Name) -join ', '
        } else { '(parent does not exist either)' }
        throw ("Assert-PathExists failed{0}`n  missing:  {1}`n  siblings: {2}" -f `
               $(if ($Because) { ": $Because" } else { '' }), $Path, $siblings)
    }
}

function Assert-PathMissing {
    param([Parameter(Position = 0)][string]$Path, [Parameter(Position = 1)][string]$Because = '')
    if (Test-Path -LiteralPath $Path) {
        throw ("Assert-PathMissing failed{0}`n  should not exist: {1}" -f `
               $(if ($Because) { ": $Because" } else { '' }), $Path)
    }
}

function Assert-FileMatches {
    param([Parameter(Position = 0)][string]$Path, [Parameter(Position = 1)][string]$Pattern, [Parameter(Position = 2)][string]$Because = '')
    Assert-PathExists $Path "the file to search was expected to exist"
    $content = Get-Content -LiteralPath $Path -Raw
    if ($content -notmatch $Pattern) {
        throw ("Assert-FileMatches failed{0}`n  file:     {1}`n  pattern:  /{2}/`n  contents: {3}" -f `
               $(if ($Because) { ": $Because" } else { '' }), $Path, $Pattern, (Format-Excerpt $content))
    }
}

function Assert-Throws {
    param([Parameter(Position = 0)][scriptblock]$Body, [Parameter(Position = 1)][string]$Pattern = '.', [Parameter(Position = 2)][string]$Because = '')
    $threw = $false
    $message = ''
    try { & $Body | Out-Null } catch { $threw = $true; $message = "$($_.Exception.Message)" }
    if (-not $threw) { throw "Assert-Throws failed$(if ($Because) { ": $Because" }): the block completed without throwing" }
    if ($message -notmatch $Pattern) {
        throw ("Assert-Throws failed{0}`n  expected message matching /{1}/`n  actual: {2}" -f `
               $(if ($Because) { ": $Because" } else { '' }), $Pattern, $message)
    }
}

function Format-Excerpt {
    param([string]$Text, [int]$Max = 900)
    if ($null -eq $Text) { return '(null)' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + "`n  ... (" + ($Text.Length - $Max) + " more characters)"
}

# ---------------------------------------------------------------------
# Capability probes
#
# Used by suites to Skip-Test rather than fail when an OPTIONAL tool is
# absent. yt-dlp is never probed for: the suite stubs it deliberately, so a
# real one being installed or not is irrelevant to every test except the
# opt-in live run.
# ---------------------------------------------------------------------

function Test-HasCommand {
    param([Parameter(Position = 0)][string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-PwshPath {
    # The absolute path of the interpreter currently running, so generated
    # stub shims invoke THIS pwsh rather than whatever a PATH lookup finds.
    # $PSHOME is the reliable cross-platform source; the process module
    # path is checked first because it is exact.
    try {
        $p = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    } catch { }
    $candidate = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return 'pwsh'
}
