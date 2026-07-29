param(
    [Parameter(Mandatory = $true)][string]$Url
)

# On PowerShell 7.3+, native-command stderr lines get wrapped as ErrorRecord
# objects when redirected (2>&1 below), which prints/logs them as noisy
# "NativeCommandError" blocks instead of yt-dlp's plain warning/error text.
# This restores plain-text passthrough. Applies the same on Linux as Windows.
$PSNativeCommandUseErrorActionPreference = $false

$dataRoot        = "/home/linuxisthebest/yt-dlp"
$configsRoot     = "/home/linuxisthebest/yt-dlp/configs"
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
# in place and is designed for exactly this, identically on Linux. It no-ops
# harmlessly if yt-dlp was installed via a package manager that doesn't
# support self-update (e.g. apt) rather than the standalone binary.
#
# ffmpeg / pwsh: check-and-warn only, NOT auto-replace, same reasoning as the
# Windows version -- neither has a safe built-in self-update, and pwsh is the
# interpreter currently running this very script. On Ubuntu both are
# normally managed by apt, so this checks apt's own upgradable-package list
# rather than comparing against upstream release numbers, which wouldn't
# line up with Ubuntu's (older, distro-patched) package versions anyway.
# NOTE: this reads apt's existing local cache -- it does not run
# "apt update" itself, since that needs root and a background video-download
# script silently invoking sudo is not something to do unattended. Run
# "sudo apt update" yourself periodically for this check to stay accurate.
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

    $aptUpgradable = $null
    try {
        $aptUpgradable = & apt list --upgradable 2>$null
    } catch {
        "  [apt check] Could not query apt's upgradable-package list: $($_.Exception.Message)" | Tee-Object -FilePath $logFile -Append
    }
    if ($aptUpgradable) {
        if ($aptUpgradable -match '^powershell/') {
            "  WARNING: an apt update is available for powershell. Update at a natural stopping point with: sudo apt update && sudo apt install --only-upgrade powershell" | Tee-Object -FilePath $logFile -Append
        }
        if ($aptUpgradable -match '^ffmpeg/') {
            "  WARNING: an apt update is available for ffmpeg. Update at a natural stopping point with: sudo apt update && sudo apt install --only-upgrade ffmpeg" | Tee-Object -FilePath $logFile -Append
        }
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
# in the current directory, ~/.config/yt-dlp/, or next to the binary. Without
# it, a stray leftover config file anywhere on the auto-discovery path
# silently merges its own options (and any --exec lines) into every run.
& yt-dlp --ignore-config --config-location $confFile $Url 2>&1 | Tee-Object -FilePath $logFile -Append

"==== Download session finished $(Get-Date -Format o) ====" | Tee-Object -FilePath $logFile -Append
