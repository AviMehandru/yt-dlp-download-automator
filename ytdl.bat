@echo off
REM Usage: ytdl <youtube-url>
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\yt-dlp\run_ytdlp.ps1" -Url "%~1"
