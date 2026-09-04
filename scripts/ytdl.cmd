@echo off
REM Thin cmd.exe shim so `ytdl <url> [options]` works from a plain Command
REM Prompt, from the Run box, and from anything that shells out via cmd --
REM all of which cannot execute a .ps1 file directly. Every bit of the
REM actual argument parsing lives in ytdl.ps1 -- one file, shared with the
REM POSIX `ytdl` shim, so the command line is parsed identically on every
REM platform. This exists only to hand it over. Note ytdl.ps1 is NOT next
REM to this file once installed: this shim goes on PATH in %USERPROFILE%
REM \.local\bin, while ytdl.ps1 lives with the other scripts under the
REM install root, which is why the path below is built rather than assumed.
REM
REM %* (not %1 %2 %3...) is what makes a URL containing "=" work. cmd.exe
REM treats "=" as an argument delimiter alongside spaces when it splits the
REM line into the numbered %1/%2/... variables, so "?v=abc123" would arrive
REM as two separate arguments and the URL would be truncated at the "=".
REM %* is the raw, unsplit remainder of the command line, so it passes
REM through byte-for-byte and pwsh does the real tokenizing.
REM
REM YTDLP_INSTALL_ROOT is honored here for the same reason the launcher and
REM run_ytdlp.ps1 honor it: so a non-default install location only has to
REM be set in one place.
setlocal
if defined YTDLP_INSTALL_ROOT (
    set "YTDL_LAUNCHER=%YTDLP_INSTALL_ROOT%\scripts\ytdl.ps1"
) else (
    set "YTDL_LAUNCHER=C:\yt-dlp\scripts\ytdl.ps1"
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%YTDL_LAUNCHER%" %*
exit /b %ERRORLEVEL%
