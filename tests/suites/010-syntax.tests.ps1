<#
    Static checks: does every file in the repo still parse, and does each
    one still obey the constraint that makes it work where it runs?

    Cheap, and first for a reason -- a parse error anywhere downstream turns
    every behavioural test in this suite into noise, so it is worth knowing
    in the first two seconds rather than the last.

    The 5.1-compatibility checks are the interesting part. setup.ps1 is what
    INSTALLS pwsh 7, so it runs under Windows PowerShell 5.1 and may not use
    a ternary, ??, ?., ForEach-Object -Parallel, or $IsWindows/$IsMacOS/
    $IsLinux. Nothing enforced that before this file: the constraint lived
    only in a comment, on a script that is never executed on the machine
    where it is edited, whose failure mode is a syntax error on a user's
    first ever run. They are checked against the parsed syntax tree rather
    than by grepping for "?", so a question mark inside a string or comment
    cannot produce a false alarm.
#>

Describe 'Static analysis' {

    $psFiles = @(
        'scripts/run_ytdlp.ps1', 'scripts/postprocess.ps1', 'scripts/ytdl.ps1',
        'scripts/pot-provider.ps1',
        'scripts/setup-common.ps1', 'setup.ps1',
        'tests/run-tests.ps1', 'tests/lib/Harness.ps1', 'tests/lib/Fixtures.ps1', 'tests/lib/Report.ps1'
    )

    foreach ($rel in $psFiles) {
        It "parses: $rel" {
            $path = Join-Path $script:RepoRoot $rel
            Assert-PathExists $path
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
            if ($errors -and $errors.Count -gt 0) {
                $detail = ($errors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join "`n  "
                throw "PowerShell parse errors in ${rel}:`n  $detail"
            }
        }
    }

    It 'setup.sh and scripts/ytdl pass bash -n' {
        if (-not (Test-HasCommand 'bash')) { Skip-Test 'bash is not on PATH (expected on Windows).' }
        foreach ($rel in @('setup.sh', 'scripts/ytdl', 'tests/run-tests')) {
            $path = Join-Path $script:RepoRoot $rel
            Assert-PathExists $path
            $out = & bash -n $path 2>&1
            Assert-Equal 0 $LASTEXITCODE "bash -n rejected ${rel}: $($out -join ' ')"
        }
    }

    It 'archive-viewer.py compiles' {
        $python = @('python3', 'python') | Where-Object { Test-HasCommand $_ } | Select-Object -First 1
        if (-not $python) { Skip-Test 'No python3/python on PATH; the viewer is an optional component.' }
        $path = Join-Path $script:RepoRoot 'scripts/archive-viewer.py'
        # PYTHONPYCACHEPREFIX keeps __pycache__ out of the repo working tree.
        $env:PYTHONPYCACHEPREFIX = [System.IO.Path]::GetTempPath()
        $out = & $python -m py_compile $path 2>&1
        Assert-Equal 0 $LASTEXITCODE "py_compile rejected archive-viewer.py: $($out -join ' ')"
    }

    It 'the POSIX shims use LF line endings and start with a shebang' {
        # A CRLF after "#!/usr/bin/env bash" makes the kernel look for an
        # interpreter literally named "bash\r" and fail with "no such file
        # or directory" -- naming a file that plainly exists. It is the
        # single most confusing way to break a shim, and the easiest to
        # introduce by editing on Windows.
        foreach ($rel in @('scripts/ytdl', 'setup.sh', 'tests/run-tests')) {
            $path = Join-Path $script:RepoRoot $rel
            $bytes = [System.IO.File]::ReadAllBytes($path)
            Assert-True ($bytes.Length -gt 3) "$rel is suspiciously short"
            Assert-Equal 0x23 $bytes[0] "$rel must start with '#'"
            Assert-Equal 0x21 $bytes[1] "$rel must start with '#!'"
            $firstCr = [Array]::IndexOf($bytes, [byte]0x0D)
            $firstLf = [Array]::IndexOf($bytes, [byte]0x0A)
            if ($firstCr -ge 0 -and $firstCr -lt $firstLf) {
                throw "$rel has a CRLF line ending on its shebang line. Convert it to LF or the shim will not execute on Linux/macOS."
            }
        }
    }

    It 'setup.ps1 stays compatible with Windows PowerShell 5.1' {
        # setup.ps1 is the script that installs pwsh 7, so it necessarily
        # runs under 5.1. Every construct below parses fine in the pwsh 7
        # you are reading this in and is a hard syntax error there.
        $path = Join-Path $script:RepoRoot 'setup.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)

        $problems = @()

        foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.TernaryExpressionAst] }, $true)) {
            $problems += "line $($node.Extent.StartLineNumber): ternary '? :' is pwsh 7 only -- use if/else"
        }

        foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)) {
            if ("$($node.Operator)" -eq 'QuestionQuestion') {
                $problems += "line $($node.Extent.StartLineNumber): null-coalescing '??' is pwsh 7 only"
            }
        }

        foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            $name = $node.VariablePath.UserPath
            if ($name -in @('IsWindows', 'IsMacOS', 'IsLinux')) {
                $problems += "line $($node.Extent.StartLineNumber): `$$name does not exist in 5.1 (it silently evaluates to `$null, so the branch is simply never taken)"
            }
        }

        foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandParameterAst] }, $true)) {
            if ($node.ParameterName -eq 'Parallel') {
                $problems += "line $($node.Extent.StartLineNumber): ForEach-Object -Parallel is pwsh 7 only"
            }
        }

        if ($problems.Count -gt 0) {
            throw "setup.ps1 must run under Windows PowerShell 5.1 -- it is what installs pwsh 7:`n  " + ($problems -join "`n  ")
        }
    }

    It 'setup-common.ps1 is only ever invoked under pwsh 7' {
        # The mirror of the test above: setup-common.ps1 is allowed every
        # pwsh 7 construct precisely because the bootstraps hand it to pwsh.
        # This asserts that handoff still exists, so the freedom stays
        # earned rather than assumed.
        Assert-FileMatches (Join-Path $script:RepoRoot 'setup.sh') 'pwsh[^\n]*setup-common\.ps1' `
            'setup.sh must invoke setup-common.ps1 through pwsh'
        Assert-FileMatches (Join-Path $script:RepoRoot 'setup.ps1') '(?s)pwsh.*setup-common\.ps1' `
            'setup.ps1 must invoke setup-common.ps1 through pwsh'
    }

    It 'the launcher shims contain no argument parsing' {
        # The organizing principle from CLAUDE.md, enforced: ytdl and
        # ytdl.cmd are shims, and every option lives once in ytdl.ps1. A
        # conditional on an option name in a shim is the beginning of the
        # two-parsers-drifting-apart problem this repo already had once.
        foreach ($rel in @('scripts/ytdl', 'scripts/ytdl.cmd')) {
            $body = Get-Content -LiteralPath (Join-Path $script:RepoRoot $rel) -Raw
            # Strip comments first: both files DISCUSS the options at
            # length, and that prose is the design record, not logic.
            $code = ($body -split "`n" | Where-Object { $_ -notmatch '^\s*(#|rem\b|REM\b|::)' }) -join "`n"
            foreach ($opt in @('--sync', '--items', '--after', '--lazy', '--workers', '--path')) {
                Assert-NotMatch ([regex]::Escape($opt)) $code `
                    "$rel references $opt outside a comment -- option parsing belongs in ytdl.ps1, which is the only parser on any platform"
            }
        }
    }
}
