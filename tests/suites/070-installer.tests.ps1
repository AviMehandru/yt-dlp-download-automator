<#
    The installer: setup.sh / setup.ps1 (the native bootstraps, steps 1-6)
    and scripts/setup-common.ps1 (the shared half, steps 7-12).

    Two kinds of test here.

    The STATIC ones enforce invariants that live only in comments today and
    have no other guard: that the three files agree on how many steps there
    are, that every file the installer downloads is also one it installs
    (and vice versa), that the keep-going error handling has not been
    replaced with `set -e`, and that nothing pipes curl into a shell.

    The DRY RUN actually executes the shared half against a temporary
    install root with -SourceDir pointing at a repo copy, which is the path
    where the two v0.72 installer bugs were found -- neither was visible by
    reading the code. It is deliberately hermetic: python and yt-dlp are
    stubbed, deno is pre-placed so its network installer is skipped, and
    $LocalBin is pre-added to PATH so the shell-profile append is skipped.
    On Windows the user PATH registry value is snapshotted and restored,
    because the installer legitimately writes to it and a test must not
    leave that behind.
#>

Describe 'Installer invariants' {

    $setupSh     = Join-Path $script:RepoRoot 'setup.sh'
    $setupPs1    = Join-Path $script:RepoRoot 'setup.ps1'
    $setupCommon = Join-Path $script:RepoRoot 'scripts/setup-common.ps1'

    It 'all three halves agree on the total number of steps' {
        # The bootstrap passes its final CURRENT_STEP to the shared half as
        # -StartStep so the progress bar continues rather than restarting.
        # A disagreement here shows up as a bar that jumps or overshoots.
        $shTotal = [int]([regex]::Match((Get-Content -LiteralPath $setupSh -Raw), '(?m)^TOTAL_STEPS=(\d+)').Groups[1].Value)
        $psTotal = [int]([regex]::Match((Get-Content -LiteralPath $setupPs1 -Raw), '(?m)^\$TotalSteps\s*=\s*(\d+)').Groups[1].Value)
        $commonDefault = [int]([regex]::Match((Get-Content -LiteralPath $setupCommon -Raw), '\$TotalSteps\s*=\s*(\d+)').Groups[1].Value)

        Assert-True ($shTotal -gt 0) 'setup.sh should declare TOTAL_STEPS'
        Assert-Equal $shTotal $psTotal      'setup.sh and setup.ps1 must declare the same TOTAL_STEPS'
        Assert-Equal $shTotal $commonDefault 'setup-common.ps1''s -TotalSteps default must match the bootstraps'
    }

    It 'the declared step count matches the number of steps actually taken' {
        # log() / Write-Step is the ONLY thing that increments the counter,
        # which is what keeps the bar and the "Step N/12" text from
        # drifting. So counting those calls counts the steps.
        $shTotal = [int]([regex]::Match((Get-Content -LiteralPath $setupSh -Raw), '(?m)^TOTAL_STEPS=(\d+)').Groups[1].Value)

        $shSteps     = @(Get-Content -LiteralPath $setupSh     | Where-Object { $_ -match '^\s*log "' }).Count
        $psSteps     = @(Get-Content -LiteralPath $setupPs1    | Where-Object { $_ -match '^\s*Write-Step ' }).Count
        $commonSteps = @(Get-Content -LiteralPath $setupCommon | Where-Object { $_ -match '^\s*Write-Step ' }).Count

        Assert-Equal $shTotal ($shSteps + $commonSteps) `
            "setup.sh takes $shSteps step(s) and setup-common.ps1 takes $commonSteps, which is $($shSteps + $commonSteps) -- but TOTAL_STEPS says $shTotal"
        Assert-Equal $shTotal ($psSteps + $commonSteps) `
            "setup.ps1 takes $psSteps step(s) and setup-common.ps1 takes $commonSteps, which is $($psSteps + $commonSteps) -- but `$TotalSteps says $shTotal"
        Assert-Equal $shSteps $psSteps `
            'the two bootstraps must cover the same steps as each other, or one platform silently skips work'
    }

    It 'every downloaded project file is also installed, and vice versa' {
        # "A file downloaded but never copied is dead weight, and a file
        # copied but never downloaded only works when it happens to sit
        # beside the installer" -- the second is the nastier failure,
        # because it works perfectly for whoever is running from a clone.
        $text = Get-Content -LiteralPath $setupCommon -Raw

        $listBlock = [regex]::Match($text, '(?s)\$ProjectFiles\s*=\s*@\((?<body>.*?)\)')
        Assert-True $listBlock.Success 'could not find the $ProjectFiles list'
        $declared = @([regex]::Matches($listBlock.Groups['body'].Value, '"([^"]+)"') |
                      ForEach-Object { $_.Groups[1].Value })
        # $LauncherSrc is a variable in the list, resolved per platform.
        $launcherPaths = @([regex]::Matches($text, '\$LauncherSrc\s*=\s*"([^"]+)"') |
                           ForEach-Object { $_.Groups[1].Value })
        Assert-True ($launcherPaths.Count -ge 2) 'both launcher sources should be assigned in the platform block'

        $installed = @([regex]::Matches($text, 'Install-ProjectFile\s+-RepoPath\s+"([^"]+)"') |
                       ForEach-Object { $_.Groups[1].Value })
        $installsLauncherVariable = $text -match 'Install-ProjectFile\s+-RepoPath\s+\$LauncherSrc'

        foreach ($file in $declared) {
            Assert-True ($installed -contains $file) `
                "$file is downloaded by Step 9 but never installed by Step 11 -- it is dead weight"
        }
        foreach ($file in $installed) {
            Assert-True ($declared -contains $file) `
                "$file is installed by Step 11 but is not in Step 9's `$ProjectFiles -- it only works when it happens to sit beside the installer"
        }
        Assert-True $installsLauncherVariable `
            'the per-platform launcher (ytdl / ytdl.cmd) must be installed via $LauncherSrc'

        foreach ($file in ($declared + $launcherPaths)) {
            Assert-PathExists (Join-Path $script:RepoRoot $file) `
                "the installer fetches '$file' from the repo, but no such file exists in this checkout"
        }
    }

    It 'keeps the deliberate keep-going error handling' {
        # No `set -e`, and no global stop-on-error in either PowerShell half:
        # the folder-structure and file-placement steps must always run, and
        # a half-placed install is worse than a complete one with warnings.
        $shLines = @(Get-Content -LiteralPath $setupSh | Where-Object { $_ -notmatch '^\s*#' })
        foreach ($line in $shLines) {
            Assert-NotMatch '^\s*set\s+-e' $line `
                'setup.sh must not use set -e -- every fallible command warns and continues on purpose'
        }
        Assert-FileMatches $setupCommon '\$ErrorActionPreference\s*=\s*"Continue"' `
            'setup-common.ps1 must keep going past a failed step'
    }

    It 'never pipes a downloaded script straight into a shell' {
        # `curl ... | sh` returns the SHELL's exit code, not curl's, so a
        # failed download feeds sh an empty script, sh exits 0, and the
        # failure is misreported as a successful install of nothing.
        #
        # Checked as real PIPELINES, not as text. Both PowerShell halves
        # print "Retry manually: curl -fsSL ... | sh" inside a warning
        # message, which is advice to a human and not something the script
        # executes -- a text match flags that and makes the test cry wolf
        # about the very guidance that exists to help when the safe path
        # failed. The syntax tree tells the two apart exactly.
        foreach ($rel in @('setup.ps1', 'scripts/setup-common.ps1')) {
            $path = Join-Path $script:RepoRoot $rel
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
            foreach ($pipeline in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.PipelineAst] }, $true)) {
                $elements = @($pipeline.PipelineElements)
                for ($i = 0; $i -lt $elements.Count - 1; $i++) {
                    $from = $elements[$i]
                    $to   = $elements[$i + 1]
                    if ($from -isnot [System.Management.Automation.Language.CommandAst]) { continue }
                    if ($to   -isnot [System.Management.Automation.Language.CommandAst]) { continue }
                    $fromName = "$($from.GetCommandName())"
                    $toName   = "$($to.GetCommandName())"
                    if ($fromName -in @('curl', 'wget', 'Invoke-WebRequest', 'Invoke-RestMethod', 'irm', 'iwr') -and
                        $toName   -in @('sh', 'bash', 'iex', 'Invoke-Expression')) {
                        throw "$rel line $($pipeline.Extent.StartLineNumber) pipes a download straight into a shell: $($pipeline.Extent.Text)`nDownload to a file and then run it -- a pipeline reports the shell's exit code, not the downloader's."
                    }
                }
            }
        }

        # setup.sh has no syntax tree available here, so quoted text is
        # stripped before matching -- same intent, cruder tool.
        foreach ($line in (Get-Content -LiteralPath $setupSh)) {
            if ($line -match '^\s*#') { continue }
            $stripped = $line -replace '"[^"]*"', '""' -replace "'[^']*'", "''"
            if ($stripped -match 'curl[^|#]*\|\s*(sh|bash)\b') {
                throw "setup.sh pipes curl into a shell: $($line.Trim())`nDownload to a file and then run it -- a pipeline reports the shell's exit code, not curl's."
            }
        }
    }

    It 'validates a download past its HTTP status' {
        # curl -f alone does not catch a 200 that lies: a proxy or captive
        # portal answering instead of GitHub returns a perfectly successful
        # HTML page.
        $text = Get-Content -LiteralPath $setupCommon -Raw
        Assert-Match '(?i)doctype|<html' $text `
            'Step 9 must reject a body that looks like HTML -- that is a captive portal answering instead of GitHub'
        Assert-Match '(?i)length|size|empty|zero' $text `
            'Step 9 must reject a zero-length body'
    }

    It 'treats a failed pwsh install as fatal in both bootstraps' {
        # Every installed file is a PowerShell script. Continuing past a
        # failed pwsh install produces a complete-looking install that
        # cannot download anything.
        foreach ($rel in @('setup.sh', 'setup.ps1')) {
            $text = Get-Content -LiteralPath (Join-Path $script:RepoRoot $rel) -Raw
            Assert-Match '(?i)(exit\s+1|exit 1|throw)' $text "$rel should be able to stop outright"
            Assert-Match '(?is)pwsh.{0,4000}?(exit\s+1|Exit\s+1)' $text `
                "$rel must stop rather than continue if PowerShell 7 could not be installed"
        }
    }
}

Describe 'Installer dry run (shared half)' {

    It 'installs every pipeline file from a local checkout without fetching anything' {
        if (-not (Test-HasCommand 'bash') -and -not $IsWindows) {
            Skip-Test 'A POSIX shell is needed for the chmod calls in Step 11.'
        }

        $r = New-TestRoot -Label 'installer-dryrun'
        $savedPath = $env:PATH
        $savedUserPath = $null
        try {
            # A COPY of the repo, never the repo itself: Step 9 creates a
            # "YT-DLP Installation Files" folder inside -SourceDir and Step
            # 11 deletes it again. Neither should ever happen in a working
            # tree someone is editing.
            $sourceDir = Join-Path $r.Root 'repo-copy'
            New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
            foreach ($sub in @('scripts', 'config')) {
                Copy-Item -LiteralPath (Join-Path $script:RepoRoot $sub) -Destination (Join-Path $sourceDir $sub) -Recurse -Force
            }

            $localBin = Join-Path $r.Root 'bin'
            New-Item -ItemType Directory -Path $localBin -Force | Out-Null

            Enable-Stubs -TestRoot $r
            # python stands in for the curl_cffi pip install (Step 7) and is
            # what makes the ytdl-view launcher get written at all.
            New-StubBinary -TestRoot $r -Name 'python3' -Behavior { Write-Output 'Successfully installed curl_cffi' } | Out-Null
            New-StubBinary -TestRoot $r -Name 'yt-dlp'  -Behavior { Write-Output '2026.08.20' } | Out-Null
            # A deno already at $DenoBin makes Step 8 skip its network
            # installer outright, which is the documented skip path rather
            # than something invented for the test.
            $denoBin = Join-Path $localBin $(if ($IsWindows) { 'deno.exe' } else { 'deno' })
            Set-Content -LiteralPath $denoBin -Value '#!/bin/sh
echo "deno 2.0.0-stub"' -Encoding utf8
            if (-not $IsWindows) { & chmod +x $denoBin }

            # $LocalBin already on PATH => the shell-profile append in Step
            # 11 is skipped, so a test run never edits ~/.bashrc or ~/.zshrc.
            $env:PATH = $localBin + [System.IO.Path]::PathSeparator + $env:PATH
            if ($IsWindows) {
                # The Windows branch writes to the persistent USER Path
                # instead of a profile file. Snapshot it so the restore in
                # `finally` puts it back exactly.
                $savedUserPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
            }

            $common = Join-Path $sourceDir 'scripts/setup-common.ps1'
            $output = & (Get-PwshPath) -NoProfile -File $common `
                        -DataRoot $r.InstallRoot -LocalBin $localBin -SourceDir $sourceDir `
                        -PlatformLabel 'test' -StartStep 6 -TotalSteps 12 2>&1 |
                      ForEach-Object { "$_" }

            # Every repo source must have reached its runtime location.
            # Note configs/ (plural) on the installed side against config/
            # (singular) in the repo -- that asymmetry is baked into
            # run_ytdlp.ps1 and postprocess.ps1 and is not a typo.
            foreach ($rel in @('scripts/run_ytdlp.ps1', 'scripts/postprocess.ps1',
                               'scripts/ytdl.ps1', 'scripts/archive-viewer.py',
                               'configs/yt-dlp.conf')) {
                Assert-PathExists (Join-Path $r.InstallRoot $rel) `
                    "Step 11 did not install $rel. Installer output:`n$($output -join "`n")"
            }

            $launcher = Join-Path $localBin $(if ($IsWindows) { 'ytdl.cmd' } else { 'ytdl' })
            Assert-PathExists $launcher 'the `ytdl` command must be installed into the bin directory'
            $viewLauncher = Join-Path $localBin $(if ($IsWindows) { 'ytdl-view.cmd' } else { 'ytdl-view' })
            Assert-PathExists $viewLauncher `
                'ytdl-view is generated rather than copied, so nothing else would catch it going missing'
            $installedViewer = Join-Path $r.InstallRoot 'scripts/archive-viewer.py'
            Assert-FileMatches $viewLauncher ([regex]::Escape($installedViewer)) `
                'the generated ytdl-view launcher must point at the INSTALLED archive-viewer.py'

            # Folder tree (Step 10).
            foreach ($rel in @('Archive Logs/Logs', 'Archive Logs/Archive History',
                               'Youtube Videos/Complete Archive', 'Youtube Videos/_incomplete',
                               'Youtube Videos/Final Video')) {
                Assert-PathExists (Join-Path $r.InstallRoot $rel) "Step 10 did not create $rel"
            }

            Assert-Match 'not downloading' $output `
                'running from a checkout must use the local files, so an edit in the working tree wins over GitHub'
            Assert-NotMatch 'raw\.githubusercontent\.com/.*\bDownloading\b' $output `
                'nothing should have been fetched from GitHub during a dry run from a local checkout'

            # The scratch download folder must not be left in the source
            # tree once everything installed cleanly.
            Assert-PathMissing (Join-Path $sourceDir 'YT-DLP Installation Files') `
                'the scratch download folder should be removed once every file installed successfully'

            # The progress bar must end exactly at the declared total.
            Assert-Match 'Step 12/12' $output 'the shared half must finish on step 12 of 12'
            Assert-NotMatch 'Step 13/12' $output 'the step counter overshot its total'
        } finally {
            $env:PATH = $savedPath
            if ($IsWindows -and $null -ne $savedUserPath) {
                [System.Environment]::SetEnvironmentVariable('Path', $savedUserPath, 'User')
            }
            Remove-TestRoot $r
        }
    }

    It 'installs a launcher that actually resolves the pipeline it just placed' {
        # The end-to-end question the dry run above cannot answer on its
        # own: after an install, does typing the command reach run_ytdlp.ps1?
        if ($IsWindows) { Skip-Test 'Covered on Windows by ytdl.cmd; this checks the POSIX shim.' }
        if (-not (Test-HasCommand 'bash')) { Skip-Test 'bash is not on PATH.' }

        $r = New-TestRoot -Label 'installer-launcher'
        try {
            Install-PipelineInto -TestRoot $r -RepoRoot $script:RepoRoot
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'scripts/ytdl') `
                      -Destination (Join-Path $r.StubDir 'ytdl') -Force
            & chmod +x (Join-Path $r.StubDir 'ytdl')
            Set-Content -LiteralPath (Join-Path $r.InstallRoot 'scripts/run_ytdlp.ps1') `
                        -Value "param([string]`$Url,[string]`$DataRoot)`nWrite-Output `"REACHED url=`$Url root=`$DataRoot`"" -Encoding utf8

            $out = & bash -c "YTDLP_INSTALL_ROOT='$($r.InstallRoot)' '$(Join-Path $r.StubDir 'ytdl')' 'https://youtu.be/abc123' '/tmp/some path' 2>&1"
            Assert-Match 'REACHED url=https://youtu\.be/abc123' $out `
                'the installed ytdl shim must resolve ytdl.ps1 and reach run_ytdlp.ps1'
            Assert-Match 'root=/tmp/some path' $out 'a positional path with a space must survive both shims'
        } finally { Remove-TestRoot $r }
    }
}
