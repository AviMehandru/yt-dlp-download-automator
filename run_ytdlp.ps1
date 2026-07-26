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
