@echo off
rem Windows shim for the test suite. No logic here -- see run-tests.ps1,
rem and scripts/ytdl.cmd for why the two shims cannot be one file.
rem %* rather than %1 %2 ... so an argument containing "=" survives.
where /q pwsh
if errorlevel 1 (
    echo Error: pwsh ^(PowerShell 7^) is not on PATH. >&2
    echo The pipeline itself cannot run without it either -- re-run setup.ps1. >&2
    exit /b 2
)
pwsh -NoProfile -File "%~dp0run-tests.ps1" %*
exit /b %ERRORLEVEL%
