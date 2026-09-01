<#
.SYNOPSIS
    Runs the whole yt-dlp archival pipeline test suite. One file, all
    platforms.

.DESCRIPTION
    The counterpart to the pipeline's own design: `tests/run-tests` (bash)
    and `tests/run-tests.cmd` are two-line shims that hand the command line
    to this file, so there is exactly one runner and one set of test bodies
    rather than a per-OS copy that drifts. Everything is stock pwsh 7 -- no
    Pester, no modules, nothing to install first.

    Nothing here touches a real archive. Every suite builds its own fixture
    tree under the system temp directory, points YTDLP_INSTALL_ROOT at it,
    and replaces yt-dlp with a recording stub, so a full run needs no
    network and finishes in seconds. The one exception is the live suite,
    which is opt-in behind -Live and does perform a real download.

.PARAMETER Live
    Also run suites/090-live.tests.ps1, which downloads one real, short
    YouTube video end to end with the real yt-dlp and asserts the resulting
    archive tree. Needs network and a working install. Minutes, not seconds.

.PARAMETER LiveUrl
    Which video the live suite archives. Defaults to the first video ever
    uploaded to YouTube: 19 seconds long, has comments, and has been in the
    same place since 2005, which is as close to a stable fixture as a real
    site gets.

.PARAMETER LiveMaxComments
    How many comments the live run fetches before stopping (default 100).
    The comments pass costs roughly one HTTP request per comment THREAD, so
    an uncapped run against a popular video is hours, and a test that takes
    hours is a test nobody runs. The cap is applied by a pass-through shim
    in front of the real yt-dlp; every other argument the pipeline builds
    reaches it untouched.

.PARAMETER LiveFullComments
    Remove the cap and fetch every comment, exactly as a real archive run
    would. Expect it to take as long as archiving that video normally does.

.PARAMETER Filter
    Wildcard matched against "<suite name> <test name>", e.g.
    -Filter '*comments*'. Suite files whose tests all filter out simply
    report nothing.

.PARAMETER Suite
    Wildcard matched against suite FILE names, e.g. -Suite '05*' to run
    only the postprocess suite. Cheaper than -Filter when you know which
    file you want, because the others are never loaded at all.

.PARAMETER ShowOutput
    Echo each test's captured output to the console as it runs. The HTML
    report always contains it either way; this is for watching a hang.

.PARAMETER StopOnFail
    Stop at the first failure instead of running the rest.

.PARAMETER ReportPath
    Where the HTML report goes. Defaults to tests/results/results.html
    beside this script.

.PARAMETER NoReport
    Skip writing the HTML report (console output only).

.EXAMPLE
    ./tests/run-tests

.EXAMPLE
    ./tests/run-tests -Suite '05*' -ShowOutput

.EXAMPLE
    ./tests/run-tests -Live
#>

param(
    [switch]$Live,
    [string]$LiveUrl = 'https://www.youtube.com/watch?v=jNQXAC9IVRw',
    [int]$LiveMaxComments = 100,
    [switch]$LiveFullComments,
    [string]$Filter,
    [string]$Suite = '*',
    [switch]$ShowOutput,
    [switch]$StopOnFail,
    [string]$ReportPath,
    [switch]$NoReport
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "This suite needs PowerShell 7 (running $($PSVersionTable.PSVersion)). The pipeline itself does too -- run it with pwsh, not powershell.exe." -ForegroundColor Red
    exit 2
}

$TestsDir = $PSScriptRoot
$RepoRoot = Split-Path $TestsDir -Parent

# Sanity check the checkout before doing anything else. A missing source
# file would otherwise surface as a dozen unrelated failures deep inside
# individual suites.
$requiredSources = @(
    'scripts/run_ytdlp.ps1', 'scripts/postprocess.ps1', 'scripts/ytdl.ps1',
    'scripts/ytdl', 'scripts/ytdl.cmd', 'scripts/setup-common.ps1',
    'scripts/archive-viewer.py', 'config/yt-dlp.conf', 'setup.sh', 'setup.ps1'
)
$missing = @($requiredSources | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepoRoot $_)) })
if ($missing.Count -gt 0) {
    Write-Host "Run this from a full checkout -- these repo files are missing relative to $RepoRoot :" -ForegroundColor Red
    foreach ($m in $missing) { Write-Host "  $m" -ForegroundColor Red }
    exit 2
}

. (Join-Path $TestsDir 'lib/Harness.ps1')
. (Join-Path $TestsDir 'lib/Fixtures.ps1')
. (Join-Path $TestsDir 'lib/Report.ps1')

$script:TestFilter      = $Filter
$script:StopOnFirstFail = [bool]$StopOnFail
$script:ShowTestOutput  = [bool]$ShowOutput

# Visible to every suite (they are dot-sourced into this scope).
$script:RepoRoot    = $RepoRoot
$script:TestsDir    = $TestsDir
$script:IncludeLive      = [bool]$Live
$script:LiveUrl          = $LiveUrl
$script:LiveMaxComments  = $LiveMaxComments
$script:LiveFullComments = [bool]$LiveFullComments

$platform = if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'macOS' } else { 'Linux' }

Write-Host ''
Write-Host '=======================================================================' -ForegroundColor Cyan
Write-Host ' yt-dlp archival pipeline -- test suite' -ForegroundColor Cyan
Write-Host '=======================================================================' -ForegroundColor Cyan
Write-Host (" platform : {0} ({1})" -f $platform, $PSVersionTable.OS)
Write-Host (" pwsh     : {0}" -f $PSVersionTable.PSVersion)
Write-Host (" repo     : {0}" -f $RepoRoot)
foreach ($tool in @('yt-dlp', 'ffmpeg', 'ffprobe', 'python3', 'deno')) {
    $found = Get-Command $tool -ErrorAction SilentlyContinue
    $where = if ($found) { $found.Source } else { 'not on PATH' }
    Write-Host (" {0,-9}: {1}" -f $tool, $where)
}
if ($Live) { Write-Host " live run : ENABLED -- $LiveUrl" -ForegroundColor Yellow }
Write-Host ''

$suiteFiles = @(Get-ChildItem -LiteralPath (Join-Path $TestsDir 'suites') -Filter '*.tests.ps1' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like $Suite -or $_.BaseName -like $Suite } |
                Sort-Object Name)

if ($suiteFiles.Count -eq 0) {
    Write-Host "No suite files matched -Suite '$Suite' under $(Join-Path $TestsDir 'suites')." -ForegroundColor Red
    exit 2
}

$overall = [System.Diagnostics.Stopwatch]::StartNew()
$savedPath = $env:PATH
$savedInstallRoot = $env:YTDLP_INSTALL_ROOT

try {
    foreach ($file in $suiteFiles) {
        $script:CurrentFile = $file.Name
        Write-Host ("-- {0}" -f $file.Name) -ForegroundColor Cyan
        # PATH and the install root are restored between suite files so one
        # suite's stubs can never leak into the next one's environment --
        # the single most likely way for this harness to produce a result
        # that depends on which order the files ran in.
        $env:PATH = $savedPath
        $env:YTDLP_INSTALL_ROOT = $savedInstallRoot
        try {
            . $file.FullName
        } catch {
            if ("$($_.Exception.Message)".StartsWith('Stopping: -StopOnFail')) { throw }
            $script:CurrentSuite = $file.BaseName
            Add-Result -Name '(suite file)' -Status 'Fail' -DurationMs 0 `
                       -Message "The suite file threw while loading: $($_.Exception.Message)" `
                       -Detail ($_.ScriptStackTrace)
        }
        Write-Host ''
    }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Yellow
} finally {
    $env:PATH = $savedPath
    $env:YTDLP_INSTALL_ROOT = $savedInstallRoot
    Remove-AllTestRoots
}
$overall.Stop()

$results = @($script:Results)
$passed  = @($results | Where-Object { $_.Status -eq 'Pass' }).Count
$failed  = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
$skipped = @($results | Where-Object { $_.Status -eq 'Skip' }).Count

Write-Host '=======================================================================' -ForegroundColor Cyan
Write-Host (" {0} passed   {1} failed   {2} skipped   in {3:N1}s" -f `
    $passed, $failed, $skipped, $overall.Elapsed.TotalSeconds) `
    -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })

if ($failed -gt 0) {
    Write-Host ''
    Write-Host ' Failures:' -ForegroundColor Red
    foreach ($f in ($results | Where-Object { $_.Status -eq 'Fail' })) {
        Write-Host ("   {0} > {1}" -f $f.Suite, $f.Name) -ForegroundColor Red
    }
}
Write-Host '=======================================================================' -ForegroundColor Cyan

if (-not $NoReport) {
    if (-not $ReportPath) { $ReportPath = Join-Path $TestsDir 'results/results.html' }
    $envInfo = [ordered]@{
        'Platform'        = "$platform ($($PSVersionTable.OS))"
        'PowerShell'      = "$($PSVersionTable.PSVersion)"
        'Repository'      = $RepoRoot
        'Machine'         = [System.Environment]::MachineName
        'yt-dlp'          = $(if ($c = Get-Command yt-dlp  -ErrorAction SilentlyContinue) { "$($c.Source)  ($(& yt-dlp --version 2>$null))" } else { 'not on PATH' })
        'ffmpeg'          = $(if ($c = Get-Command ffmpeg  -ErrorAction SilentlyContinue) { $c.Source } else { 'not on PATH -- some tests skipped' })
        'ffprobe'         = $(if ($c = Get-Command ffprobe -ErrorAction SilentlyContinue) { $c.Source } else { 'not on PATH -- some tests skipped' })
        'python3'         = $(if ($c = Get-Command python3 -ErrorAction SilentlyContinue) { $c.Source } else { 'not on PATH -- viewer tests skipped' })
        'deno'            = $(if ($c = Get-Command deno    -ErrorAction SilentlyContinue) { $c.Source } else { 'not on PATH' })
        'Live suite'      = $(if ($Live) { "enabled -- $LiveUrl" + $(if ($LiveFullComments) { ' (all comments)' } else { " (comments capped at $LiveMaxComments)" }) } else { 'skipped (pass -Live to include it)' })
        'Suite filter'    = $Suite
        'Test filter'     = $(if ($Filter) { $Filter } else { '(none)' })
    }
    $written = Write-HtmlReport -Results $results -Path $ReportPath -Environment $envInfo -TotalSeconds $overall.Elapsed.TotalSeconds
    Write-Host ''
    Write-Host " HTML report: $written"
    Write-Host ''
}

# A non-zero exit on failure is what makes this usable from a git hook or
# CI later without any change here.
exit $(if ($failed -gt 0) { 1 } else { 0 })
