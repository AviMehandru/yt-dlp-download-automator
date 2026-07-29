param(
    [Parameter(Mandatory = $true)][string]$Url
)

# On PowerShell 7.3+ (which this now runs under), native-command stderr
# lines get wrapped as ErrorRecord objects when redirected (2>&1 below),
# which prints/logs them as noisy "NativeCommandError" blocks instead of
# yt-dlp's plain warning/error text. This restores plain-text passthrough.
$PSNativeCommandUseErrorActionPreference = $false

$dataRoot        = "C:/yt-dlp"
$configsRoot     = "C:/yt-dlp/configs"
$archiveLogsRoot = Join-Path $dataRoot "Archive Logs"
$historyDir      = Join-Path $archiveLogsRoot "Archive History"
$logsDir         = Join-Path $archiveLogsRoot "Logs"
$logFile         = Join-Path $logsDir "download.log"
$archiveFile     = Join-Path $logsDir "archive.txt"
$globalManifest  = Join-Path $dataRoot "Youtube Videos/global_manifest.json"
$confFile        = Join-Path $configsRoot "yt-dlp.conf"

foreach ($d in @($historyDir, $logsDir)) {
    if (!(Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"

# --- Dependency updates/checks (throttled to once/day, not every run) ---
# yt-dlp: safe, real, built-in self-update -- yt-dlp -U replaces its own exe
# in place and is designed for exactly this. It no-ops harmlessly if yt-dlp
# was installed via a package manager that doesn't support self-update.
#
# ffmpeg / pwsh: check-and-warn only, NOT auto-replace. Neither has a safe
# built-in self-update, and pwsh in particular is the interpreter currently
# running this very script -- attempting to overwrite its own exe mid-session
# risks a locked-file failure or a broken install. If you'd rather have real
# auto-update for these two despite that risk, ask and I'll add it, but a
# warning you can act on when convenient is the safer default.
$updateThrottleMarker = Join-Path $dataRoot ".last_dependency_check"
$updateThrottleHours = 24
$needsDependencyCheck = $true
if (Test-Path $updateThrottleMarker) {
    $age = (Get-Date) - (Get-Item $updateThrottleMarker).LastWriteTime
    if ($age.TotalHours -lt $updateThrottleHours) { $needsDependencyCheck = $false }
}

if ($needsDependencyCheck) {
    "-- Dependency check (throttled to once/$updateThrottleHours`h) --" | Tee-Object -FilePath $logFile -Append
    $updateOutput = & yt-dlp -U 2>&1
    $updateOutput | ForEach-Object { "  [yt-dlp -U] $_" | Tee-Object -FilePath $logFile -Append }

    $pwshLatestTag = $null
    try {
        $pwshRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/latest" -Headers @{ "User-Agent" = "yt-dlp-archiver" } -ErrorAction Stop
        $pwshLatestTag = $pwshRelease.tag_name -replace '^v', ''
    } catch {
        "  [pwsh check] Could not reach GitHub to check latest version: $($_.Exception.Message)" | Tee-Object -FilePath $logFile -Append
    }
    if ($pwshLatestTag -and ($PSVersionTable.PSVersion.ToString() -ne $pwshLatestTag)) {
        "  WARNING: pwsh $($PSVersionTable.PSVersion) is running; $pwshLatestTag is the latest release. Update at a natural stopping point with: winget upgrade Microsoft.PowerShell" | Tee-Object -FilePath $logFile -Append
    }

    $ffmpegLatestVersion = $null
    try {
        $ffmpegVersionPage = Invoke-RestMethod -Uri "https://www.gyan.dev/ffmpeg/builds/release-version" -ErrorAction Stop
        $ffmpegLatestVersion = "$ffmpegVersionPage".Trim()
    } catch {
        "  [ffmpeg check] Could not reach gyan.dev to check latest version: $($_.Exception.Message)" | Tee-Object -FilePath $logFile -Append
    }
    $ffmpegCurrentRaw = (& ffmpeg -version) 2>$null
    $ffmpegCurrentVersion = if ($ffmpegCurrentRaw -and $ffmpegCurrentRaw[0] -match 'ffmpeg version (\S+)') { $Matches[1] } else { $null }
    if ($ffmpegLatestVersion -and $ffmpegCurrentVersion -and ($ffmpegCurrentVersion -ne $ffmpegLatestVersion)) {
        "  WARNING: ffmpeg $ffmpegCurrentVersion is installed; $ffmpegLatestVersion is the latest gyan.dev release. Grab it from https://www.gyan.dev/ffmpeg/builds/ when convenient." | Tee-Object -FilePath $logFile -Append
    }

    Set-Content -Path $updateThrottleMarker -Value (Get-Date -Format "o")
}

# --- Versioned archival snapshot (#16): back up archive.txt + global manifest before this run ---
if (Test-Path $archiveFile)    { Copy-Item $archiveFile "$historyDir/archive_$timestamp.txt" }
if (Test-Path $globalManifest) { Copy-Item $globalManifest "$historyDir/global_manifest_$timestamp.json" }

$configVersion = $null
if (Test-Path $confFile) {
    $m = Select-String -Path $confFile -Pattern "CONFIG_VERSION:\s*(\S+)" | Select-Object -First 1
    if ($m) { $configVersion = $m.Matches[0].Groups[1].Value }
}
$ytDlpVersion  = (& yt-dlp --version) 2>$null
$ffmpegRaw     = (& ffmpeg -version) 2>$null
$ffmpegVersion = if ($ffmpegRaw) { ($ffmpegRaw -split "`n")[0] } else { $null }

"==== Download session started $timestamp ====" | Tee-Object -FilePath $logFile -Append
"yt-dlp: $ytDlpVersion | ffmpeg: $ffmpegVersion | config version: $configVersion" | Tee-Object -FilePath $logFile -Append
"URL: $Url" | Tee-Object -FilePath $logFile -Append

# --- Run yt-dlp, capturing stdout AND stderr (warnings/errors) into the log ---
# --ignore-config stops yt-dlp from also auto-loading any yt-dlp.conf it finds
# in the current directory, %APPDATA%, or next to the binary. Without it, a
# stray leftover config file anywhere on the auto-discovery path silently
# merges its own options (and any --exec lines) into every run.
& yt-dlp --ignore-config --config-location $confFile $Url 2>&1 | Tee-Object -FilePath $logFile -Append

"==== Download session finished $(Get-Date -Format o) ====" | Tee-Object -FilePath $logFile -Append
