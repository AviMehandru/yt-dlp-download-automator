@echo off
REM Called by yt-dlp's --exec after_move hook.
REM Args: %1=full source filepath  %2=uploader  %3=upload_date  %4=id  %5=title  %6=ext

set "SRC=%~1"
set "UPLOADER=%~2"
set "UPDATE=%~3"
set "ID=%~4"
set "TITLE=%~5"
set "EXT=%~6"

set "DESTDIR=C:\yt-dlp\Youtube Videos\Pure Video\%UPLOADER%"
set "DESTFILE=%DESTDIR%\%UPLOADER% - %UPDATE% - %ID% - %TITLE%.%EXT%"

if not exist "%DESTDIR%" mkdir "%DESTDIR%"

copy /Y "%SRC%" "%DESTFILE%" >nul

if %ERRORLEVEL% EQU 0 (
    echo Copied to Pure Video: %DESTFILE%
) else (
    echo FAILED to copy "%SRC%" to "%DESTFILE%" 1>&2
)
