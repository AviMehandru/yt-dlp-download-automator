# POT_PROVIDER_VERSION: 1
#
# PO (proof-of-origin) token provider lifecycle for the yt-dlp archival
# pipeline: install, start, health-check, update-with-rollback, and stop.
#
# WHY THIS EXISTS AT ALL. Before this file, the pipeline ran on yt-dlp's
# default client list and nothing else. Those defaults are, for an
# unauthenticated caller, exactly two clients: android_vr and web_safari.
# android_vr needs no PO token and was doing all the real work;
# web_safari needs a GVS PO token that this pipeline did not provide, so
# it could not complete a download at all. That is the whole story behind
# the "Only images are available for download" failure recorded in
# yt-dlp.conf's CONFIG_VERSION 23 note: excluding android_vr did not fall
# back to a working client, it fell back to the ONLY other default, which
# was structurally unusable. So the pipeline was effectively single-client,
# and that one client is the one with the open upstream 403 bug
# (yt-dlp/yt-dlp#17456). Providing PO tokens is what turns the fallback
# list back into a real list.
#
# WHAT A PO TOKEN IS, in one paragraph, because the name is unhelpful.
# YouTube asks certain clients to attach a token proving the request came
# from a real browser-like client rather than a script. The token is
# produced by running Google's BotGuard JavaScript, and it is bound to a
# specific video id, so it cannot be generated once and reused -- every
# video needs a fresh one. That is why this is a long-running local
# service rather than a config value: something has to run that JS, per
# video, on demand.
#
# TWO COMPONENTS, ONE VERSION. bgutil-ytdlp-pot-provider ships as a pair:
#   * a yt-dlp PLUGIN (Python, from PyPI) that yt-dlp loads and calls
#     whenever an extractor needs a token, and
#   * a SERVER (Node) that the plugin talks to over local HTTP, which is
#     what actually runs the BotGuard JS.
# Upstream requires these two to be the same version. Get-PotTargetVersion
# below therefore resolves ONE version number from PyPI and uses it for
# both, rather than letting them drift independently -- a mismatched pair
# fails in confusing ways (the plugin loads, the server answers, and token
# requests quietly return nothing useful).
#
# WHY A TARBALL AND NOT `git clone`. Upstream's README says to clone the
# repo at a tag to build the server. This file downloads the tag's tarball
# over plain HTTPS instead, for the same reason setup-common.ps1's Step 9
# fetches individual files rather than cloning: nothing else in this
# project needs git at runtime, and a single HTTPS GET has far fewer ways
# to fail on a fresh machine than a clone does. It also makes pinning
# trivial, which is exactly what rollback needs -- the version is right
# there in the URL.
#
# DUAL USE. Dot-source this file to get the functions
# (`. path/to/pot-provider.ps1`), which is how run_ytdlp.ps1 consumes it.
# Or run it directly with -SelfTest / -Install / -Stop / -Status for
# diagnostics without starting a download. Running it with no switches
# does nothing but define functions, so dot-sourcing is side-effect free.

param(
    # Diagnostic entry points. All optional: with none of them set this
    # file only defines functions (see DUAL USE above).
    [switch] $SelfTest,
    [switch] $Install,
    [switch] $Stop,
    [switch] $Status,
    # Overrides the port the local provider server listens on. 4416 is
    # upstream's default and is what the plugin assumes when no
    # base_url extractor-arg is passed.
    [int]    $Port = 4416
)

$ErrorActionPreference = "Continue"

# =====================================================================
# PATHS AND CONSTANTS
# =====================================================================
# Resolved the same way run_ytdlp.ps1 resolves them, and deliberately NOT
# imported from it: this file has to work standalone (the -SelfTest path
# above) without dragging in a script whose param block demands a -Url.

function Get-PotPaths {
    param([int] $ProviderPort = 4416)

    $installRoot = if ([string]::IsNullOrWhiteSpace($env:YTDLP_INSTALL_ROOT)) {
        if ($IsWindows) { "C:/yt-dlp" } else { Join-Path $HOME "yt-dlp" }
    } else {
        $env:YTDLP_INSTALL_ROOT
    }

    # The server lives under the INSTALL root, never under a custom
    # -DataRoot. It is part of the pipeline installation (like scripts/
    # and configs/), not part of the archive data, and one machine running
    # two data roots should still share one provider server rather than
    # racing two of them onto the same port.
    $potRoot = Join-Path $installRoot "pot-provider"

    [pscustomobject]@{
        InstallRoot = $installRoot
        PotRoot     = $potRoot
        ServerDir   = Join-Path $potRoot "server"
        ServerEntry = Join-Path $potRoot "server/build/main.js"
        StateFile   = Join-Path $potRoot "pot-state.json"
        PidFile     = Join-Path $potRoot "pot-server.pid"
        LogFile     = Join-Path $potRoot "pot-server.log"
        Port        = $ProviderPort
        BaseUrl     = "http://127.0.0.1:$ProviderPort"
    }
}

# The client list used when a PO token IS available, in the order yt-dlp
# should try them. Ordering rationale, from the upstream PO Token Guide's
# own client table:
#
#   tv_simply  -- needs a GVS token (which we now have), does NOT support
#                 account cookies, and is not subject to the `tv` client's
#                 "all formats DRM'd without cookies" problem. For an
#                 unauthenticated archiver this is the best first choice.
#   web_safari -- needs a GVS token, but uniquely also offers HLS (m3u8)
#                 formats which do NOT currently require a token at all.
#                 That makes it the most useful second try: it can
#                 sometimes succeed even if token generation is failing,
#                 which no other token-requiring client can do.
#   android_vr -- needs no token ever. Kept LAST, not removed: it is the
#                 client with the open #17456 403 bug, and its "made for
#                 kids videos are unavailable" limitation makes it a poor
#                 default. But as a final fallback it is genuinely useful,
#                 because it fails in a completely different way than the
#                 two above, which is the entire point of a fallback.
#
# Deliberately NOT included: `web` (only SABR formats, which yt-dlp cannot
# download), `tv` (every format DRM'd without cookies, and this pipeline
# passes none), `web_creator`/`web_music` (require account cookies),
# `android`/`ios` (no cookie support AND still token-gated, so they add
# risk without adding capability), and `web_embedded` (embeddable videos
# only -- too narrow to be worth a slot).
$script:PotHealthyClients = "tv_simply,web_safari,android_vr"

# =====================================================================
# STATE FILE
# =====================================================================
# Records the last combination of (provider version, yt-dlp version) that
# actually passed a self-test. This is what rollback rolls back TO, and it
# is the only durable memory this system has -- everything else is
# re-derived on each run.

function Read-PotState {
    param([string] $StateFile)
    if (-not (Test-Path $StateFile)) {
        return [pscustomobject]@{
            KnownGoodProvider = $null
            KnownGoodYtDlp    = $null
            LastVerified      = $null
            LastFailure       = $null
        }
    }
    try {
        Get-Content -Path $StateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        # A corrupt state file must never be fatal: the worst case is that
        # we lose the known-good pin and have to re-verify from scratch,
        # which is exactly what a first run does anyway.
        [pscustomobject]@{
            KnownGoodProvider = $null
            KnownGoodYtDlp    = $null
            LastVerified      = $null
            LastFailure       = "unreadable state file, ignored"
        }
    }
}

function Write-PotState {
    param([string] $StateFile, [object] $State)
    try {
        $dir = Split-Path -Parent $StateFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $State | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
    } catch {
        Write-Verbose "Could not persist POT state to $StateFile : $($_.Exception.Message)"
    }
}

# =====================================================================
# VERSION RESOLUTION
# =====================================================================

# The plugin and server must be the same version, so exactly ONE version
# number is resolved here and used for both. PyPI is the source of truth
# rather than the GitHub releases API because the pip package is the half
# that yt-dlp actually loads, because PyPI needs no API token and has no
# unauthenticated rate limit worth worrying about, and because a version
# that is on PyPI is guaranteed to have a matching git tag upstream (the
# reverse is not guaranteed -- a tag can exist before the release ships).
function Get-PotTargetVersion {
    try {
        $meta = Invoke-RestMethod -Uri "https://pypi.org/pypi/bgutil-ytdlp-pot-provider/json" `
                                  -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        if ($meta.info.version) { return $meta.info.version }
    } catch {
        Write-Verbose "Could not query PyPI for the provider version: $($_.Exception.Message)"
    }
    return $null
}

function Get-YtDlpVersion {
    try {
        $v = (& yt-dlp --version 2>$null | Select-Object -First 1)
        if ($v) { return $v.Trim() }
    } catch { }
    return $null
}

function Get-InstalledPotPluginVersion {
    # `pip show` rather than importing the module: yt-dlp loads the plugin
    # itself and there is no supported way to ask yt-dlp what version of a
    # plugin it loaded, but pip knows what it installed.
    try {
        $out = & python3 -m pip show bgutil-ytdlp-pot-provider 2>$null
        if (-not $out) { $out = & python -m pip show bgutil-ytdlp-pot-provider 2>$null }
        $line = $out | Where-Object { $_ -match '^Version:\s*(.+)$' } | Select-Object -First 1
        if ($line -and $line -match '^Version:\s*(.+)$') { return $Matches[1].Trim() }
    } catch { }
    return $null
}

function Get-InstalledPotServerVersion {
    param([object] $Paths)
    $pkg = Join-Path $Paths.ServerDir "package.json"
    if (-not (Test-Path $pkg)) { return $null }
    try {
        return (Get-Content -Path $pkg -Raw | ConvertFrom-Json).version
    } catch { return $null }
}

# =====================================================================
# INSTALL
# =====================================================================

function Install-PotPlugin {
    param([string] $Version)

    # --break-system-packages matches how setup-common.ps1 already installs
    # curl_cffi: these are externally-managed Python environments on most
    # modern distros, and this pipeline deliberately does not create a
    # virtualenv (yt-dlp is a standalone binary and would not see one).
    $pipArgs = @("-m", "pip", "install", "--upgrade", "--break-system-packages")
    if ($Version) { $pipArgs += "bgutil-ytdlp-pot-provider==$Version" }
    else          { $pipArgs += "bgutil-ytdlp-pot-provider" }

    foreach ($py in @("python3", "python")) {
        $cmd = Get-Command $py -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        & $py @pipArgs 2>&1 | ForEach-Object { Write-Verbose "  [pot-plugin] $_" }
        if ($LASTEXITCODE -eq 0) { return $true }
        # Retry without the flag: older pips reject an unknown option
        # outright, so a failure here may just mean "this pip predates
        # PEP 668" rather than "the install failed".
        $fallback = $pipArgs | Where-Object { $_ -ne "--break-system-packages" }
        & $py @fallback 2>&1 | ForEach-Object { Write-Verbose "  [pot-plugin] $_" }
        if ($LASTEXITCODE -eq 0) { return $true }
    }
    return $false
}

function Install-PotServer {
    param([object] $Paths, [string] $Version)

    $node = Get-Command node -ErrorAction SilentlyContinue
    $npm  = Get-Command npm  -ErrorAction SilentlyContinue
    if (-not $node -or -not $npm) {
        Write-Verbose "node/npm not found on PATH -- cannot build the provider server."
        return $false
    }

    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("pot-server-" + [guid]::NewGuid().ToString("N"))
    $tarball = Join-Path ([System.IO.Path]::GetTempPath()) ("pot-$Version.tar.gz")

    try {
        New-Item -ItemType Directory -Path $staging -Force | Out-Null

        # Two URL shapes for the same bytes. codeload is what github.com's
        # /archive/ path redirects to; asking for it directly avoids one
        # cross-host redirect, which some corporate proxies mangle. The
        # github.com spelling is kept as a fallback because codeload is
        # occasionally blocked on its own where github.com is not.
        $urls = @(
            "https://codeload.github.com/Brainicism/bgutil-ytdlp-pot-provider/tar.gz/refs/tags/$Version",
            "https://github.com/Brainicism/bgutil-ytdlp-pot-provider/archive/refs/tags/$Version.tar.gz"
        )
        $got = $false
        foreach ($u in $urls) {
            try {
                Invoke-WebRequest -Uri $u -OutFile $tarball -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
                $item = Get-Item $tarball -ErrorAction SilentlyContinue
                # A captive portal or proxy answering 200 with an HTML page
                # produces a small "tarball" that tar will reject with a
                # confusing error. Catching it here names the real problem.
                if ($item -and $item.Length -gt 10000) { $got = $true; break }
            } catch {
                Write-Verbose "  [pot-server] $u failed: $($_.Exception.Message)"
            }
        }
        if (-not $got) { return $false }

        # tar is present by default on all three targets now (Windows has
        # shipped bsdtar in System32 since Windows 10 1803), so this is one
        # command rather than a platform branch.
        & tar -xzf $tarball -C $staging 2>&1 | ForEach-Object { Write-Verbose "  [pot-server] $_" }
        if ($LASTEXITCODE -ne 0) { return $false }

        # The tarball unpacks to a single <repo>-<version> directory whose
        # exact name has changed shape upstream before, so it is discovered
        # rather than assumed.
        $extracted = Get-ChildItem -Path $staging -Directory | Select-Object -First 1
        if (-not $extracted) { return $false }
        $serverSrc = Join-Path $extracted.FullName "server"
        if (-not (Test-Path $serverSrc)) { return $false }

        Push-Location $serverSrc
        try {
            # `npm ci` rather than `npm install`: it installs exactly the
            # lockfile's dependency tree, which is the whole point of
            # pinning a version. `npm install` is free to resolve newer
            # transitive dependencies and would quietly defeat rollback.
            & npm ci --no-audit --no-fund 2>&1 | ForEach-Object { Write-Verbose "  [pot-server] $_" }
            if ($LASTEXITCODE -ne 0) { return $false }
            & npx tsc 2>&1 | ForEach-Object { Write-Verbose "  [pot-server] $_" }
            if ($LASTEXITCODE -ne 0) { return $false }
        } finally {
            Pop-Location
        }

        if (-not (Test-Path (Join-Path $serverSrc "build/main.js"))) { return $false }

        # Only now is the old install replaced. Building in a temp
        # directory and swapping at the end means a failed build (a network
        # blip during npm ci, a TypeScript error in a bad release) leaves
        # the PREVIOUS working server completely untouched -- which is what
        # makes rollback possible at all, since rollback needs something to
        # roll back to.
        if (-not (Test-Path $Paths.PotRoot)) {
            New-Item -ItemType Directory -Path $Paths.PotRoot -Force | Out-Null
        }
        $previous = "$($Paths.ServerDir).previous"
        if (Test-Path $previous)          { Remove-Item -Path $previous -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path $Paths.ServerDir)   { Move-Item -Path $Paths.ServerDir -Destination $previous -Force }
        Move-Item -Path $serverSrc -Destination $Paths.ServerDir -Force
        return $true
    } catch {
        Write-Verbose "Provider server install failed: $($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item -Path $tarball -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =====================================================================
# SERVER LIFECYCLE
# =====================================================================

function Test-PotServerAlive {
    param([object] $Paths, [int] $TimeoutSec = 5)
    try {
        $r = Invoke-WebRequest -Uri "$($Paths.BaseUrl)/ping" -UseBasicParsing `
                               -TimeoutSec $TimeoutSec -ErrorAction Stop
        return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300)
    } catch {
        return $false
    }
}

function Start-PotServer {
    param([object] $Paths, [int] $WaitSec = 30)

    if (Test-PotServerAlive -Paths $Paths) { return $true }
    if (-not (Test-Path $Paths.ServerEntry)) { return $false }

    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { return $false }

    try {
        # Detached, with stdout/stderr to a log file. Not Start-Job: a job
        # dies with the PowerShell session that created it, and this server
        # should outlive a single `ytdl` invocation so the next one does
        # not pay the startup cost again.
        $proc = Start-Process -FilePath $node.Source `
                              -ArgumentList @($Paths.ServerEntry, "--port", "$($Paths.Port)") `
                              -WorkingDirectory $Paths.ServerDir `
                              -RedirectStandardOutput $Paths.LogFile `
                              -RedirectStandardError  "$($Paths.LogFile).err" `
                              -WindowStyle Hidden -PassThru -ErrorAction Stop
        Set-Content -Path $Paths.PidFile -Value $proc.Id -Encoding ASCII
    } catch {
        Write-Verbose "Could not start the provider server: $($_.Exception.Message)"
        return $false
    }

    # Poll rather than sleep-a-fixed-amount: first start after a build is
    # slow (Node cold start plus BotGuard warmup), later starts are near
    # instant, and a fixed sleep would have to be sized for the worst case
    # on every single run.
    $deadline = (Get-Date).AddSeconds($WaitSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-PotServerAlive -Paths $Paths -TimeoutSec 3) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Stop-PotServer {
    param([object] $Paths)
    if (-not (Test-Path $Paths.PidFile)) { return }
    try {
        $serverPid = [int](Get-Content -Path $Paths.PidFile -Raw).Trim()
        Stop-Process -Id $serverPid -Force -ErrorAction SilentlyContinue
    } catch { }
    Remove-Item -Path $Paths.PidFile -Force -ErrorAction SilentlyContinue
}

# =====================================================================
# SELF-TEST
# =====================================================================
# This is the function that answers the only question that matters: can
# this machine, right now, actually produce a PO token?
#
# It deliberately does NOT test by downloading a real video. Doing that
# would need a hardcoded video id, which rots (videos get deleted, made
# private, or region-locked) and would make the pipeline's health depend on
# one stranger's upload staying public forever. Asking the provider for a
# token directly tests the same thing -- can BotGuard still run here --
# with no external dependency beyond the provider itself.
#
# CAVEAT WORTH KNOWING: /get_pot's exact request shape is upstream's own
# API and can change between provider versions. This function therefore
# treats a MALFORMED-REQUEST style rejection differently from a genuine
# token failure: if the server is alive and answering but rejects the
# probe's shape, that is reported as Unknown rather than Unhealthy, and the
# caller proceeds on the token clients anyway. Reporting a shape change as
# "BotGuard is broken" would drop the pipeline into degraded mode for a
# reason that has nothing to do with whether tokens work.
function Test-PotToken {
    param([object] $Paths, [int] $TimeoutSec = 45)

    if (-not (Test-PotServerAlive -Paths $Paths)) {
        return [pscustomobject]@{ Result = "Unhealthy"; Reason = "provider server is not answering on $($Paths.BaseUrl)" }
    }

    # An arbitrary but well-formed content binding. Any stable string works
    # -- the token is bound to it, and we throw the token away.
    $body = @{ content_binding = "ytdlp-pipeline-selftest" } | ConvertTo-Json -Compress

    try {
        $r = Invoke-WebRequest -Uri "$($Paths.BaseUrl)/get_pot" -Method Post -Body $body `
                               -ContentType "application/json" -UseBasicParsing `
                               -TimeoutSec $TimeoutSec -ErrorAction Stop
        $payload = $null
        try { $payload = $r.Content | ConvertFrom-Json } catch { }
        if ($payload -and $payload.po_token) {
            return [pscustomobject]@{ Result = "Healthy"; Reason = "provider returned a token" }
        }
        return [pscustomobject]@{ Result = "Unknown"; Reason = "provider answered /get_pot but returned no recognizable token field; treating as usable" }
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -eq 400 -or $status -eq 404 -or $status -eq 422) {
            # The server is up and talking; it just did not like this
            # probe. See the CAVEAT above -- not a token failure.
            return [pscustomobject]@{ Result = "Unknown"; Reason = "provider rejected the self-test probe shape (HTTP $status); its API may have changed, treating as usable" }
        }
        return [pscustomobject]@{ Result = "Unhealthy"; Reason = "token request failed: $($_.Exception.Message)" }
    }
}

# =====================================================================
# THE ENTRY POINT
# =====================================================================
# One call, one answer. run_ytdlp.ps1 calls this and gets back an object
# saying whether to use the token clients or to degrade.
#
# The sequence, and why it is in this order:
#   1. Is the current install already healthy? If yes, stop -- do not
#      update. Updating a working stack is how you break a working stack,
#      and yt-dlp's own --update in yt-dlp.conf already covers yt-dlp
#      itself for everything OTHER than token generation.
#   2. Not healthy: try updating to the current upstream version. This is
#      the case where YouTube changed something and upstream has shipped a
#      fix -- the whole reason to auto-update at all.
#   3. Still not healthy: roll back to the last version pair that DID
#      pass. This is the case where upstream shipped a bad release, or the
#      new version needs a newer yt-dlp than is installed.
#   4. Still not healthy: degrade. Report it loudly and let the caller
#      run on yt-dlp's own defaults, exactly as the pipeline did before
#      this file existed.
#
# Step 4 is the honest part of this design and is worth stating plainly:
# when YouTube changes BotGuard and upstream has not yet shipped a fix,
# NOTHING here can produce a token. There is no local repair for that. The
# most this can do is notice quickly, avoid contaminating the archive, and
# keep downloading at reduced capability until a fix lands upstream.
function Initialize-PotProvider {
    param(
        [int]    $ProviderPort = 4416,
        [switch] $SkipUpdate,
        [scriptblock] $Log = { param($m) Write-Host $m }
    )

    $paths = Get-PotPaths -ProviderPort $ProviderPort
    $state = Read-PotState -StateFile $paths.StateFile

    function New-PotResult {
        param([bool] $Healthy, [string] $Reason, [string] $Version)
        # ExtractorArgs is what actually gets splatted onto the yt-dlp
        # command line. In the DEGRADED case it is deliberately EMPTY
        # rather than "android_vr": omitting player_client entirely means
        # yt-dlp uses its own defaults, which is byte-for-byte the behavior
        # this pipeline had before PO tokens were wired up. Degrading
        # should reproduce the old known state exactly, not invent a new
        # narrower one that has never been tested.
        # NOT named $args: that is a PowerShell automatic variable holding
        # the function's own unbound arguments, and assigning to it is
        # either ignored or an error depending on context. This kind of
        # collision is silent and maddening to debug, so the name is
        # deliberately unremarkable instead.
        $argList = @()
        if ($Healthy) {
            $argList += @("--extractor-args", "youtube:player_client=$script:PotHealthyClients")
            if ($ProviderPort -ne 4416) {
                $argList += @("--extractor-args", "youtubepot-bgutilhttp:base_url=$($paths.BaseUrl)")
            }
        }
        [pscustomobject]@{
            Healthy       = $Healthy
            Reason        = $Reason
            Version       = $Version
            PlayerClients = if ($Healthy) { $script:PotHealthyClients } else { "(yt-dlp defaults)" }
            ExtractorArgs = $argList
            BaseUrl       = $paths.BaseUrl
            Paths         = $paths
        }
    }

    # --- 1. Is what is already installed working? ---
    $installedServer = Get-InstalledPotServerVersion -Paths $paths
    if ($installedServer) {
        if (Start-PotServer -Paths $paths) {
            $probe = Test-PotToken -Paths $paths
            if ($probe.Result -ne "Unhealthy") {
                & $Log "PO token provider healthy (v$installedServer): $($probe.Reason)"
                $state.KnownGoodProvider = $installedServer
                $state.KnownGoodYtDlp    = Get-YtDlpVersion
                $state.LastVerified      = (Get-Date).ToString("o")
                $state.LastFailure       = $null
                Write-PotState -StateFile $paths.StateFile -State $state
                return New-PotResult -Healthy $true -Reason $probe.Reason -Version $installedServer
            }
            & $Log "PO token provider v$installedServer is installed but not producing tokens: $($probe.Reason)"
        } else {
            & $Log "PO token provider v$installedServer is installed but its server did not start."
        }
    } else {
        & $Log "PO token provider is not installed yet."
    }

    if ($SkipUpdate) {
        return New-PotResult -Healthy $false -Reason "provider unhealthy and -SkipPotUpdate was set" -Version $installedServer
    }

    # --- 2. Update to current upstream and re-test ---
    $target = Get-PotTargetVersion
    if (-not $target) {
        & $Log "Could not reach PyPI to determine the current provider version."
    } elseif ($target -eq $installedServer) {
        & $Log "Already on the current provider version (v$target) and it is failing -- an upstream fix has not shipped yet."
    } else {
        & $Log "Installing PO token provider v$target (was: $(if ($installedServer) { "v$installedServer" } else { "none" }))..."
        Stop-PotServer -Paths $paths
        $serverOk = Install-PotServer -Paths $paths -Version $target
        $pluginOk = Install-PotPlugin -Version $target
        if ($serverOk -and $pluginOk -and (Start-PotServer -Paths $paths)) {
            $probe = Test-PotToken -Paths $paths
            if ($probe.Result -ne "Unhealthy") {
                & $Log "PO token provider v$target is working."
                $state.KnownGoodProvider = $target
                $state.KnownGoodYtDlp    = Get-YtDlpVersion
                $state.LastVerified      = (Get-Date).ToString("o")
                $state.LastFailure       = $null
                Write-PotState -StateFile $paths.StateFile -State $state
                return New-PotResult -Healthy $true -Reason $probe.Reason -Version $target
            }
            & $Log "PO token provider v$target installed but still not producing tokens: $($probe.Reason)"
        } else {
            & $Log "PO token provider v$target failed to install (server: $serverOk, plugin: $pluginOk)."
        }
    }

    # --- 3. Roll back to the last known-good pair ---
    # Only meaningful if there IS a known-good version and it is not the
    # one that just failed -- rolling back to the version we are already
    # running and have already seen fail would just waste a build.
    if ($state.KnownGoodProvider -and $state.KnownGoodProvider -ne $target -and $state.KnownGoodProvider -ne $installedServer) {
        & $Log "Rolling back to last known-good PO token provider v$($state.KnownGoodProvider)..."
        Stop-PotServer -Paths $paths
        $serverOk = Install-PotServer -Paths $paths -Version $state.KnownGoodProvider
        $pluginOk = Install-PotPlugin -Version $state.KnownGoodProvider
        if ($serverOk -and $pluginOk -and (Start-PotServer -Paths $paths)) {
            $probe = Test-PotToken -Paths $paths
            if ($probe.Result -ne "Unhealthy") {
                & $Log "Rollback to v$($state.KnownGoodProvider) succeeded."
                return New-PotResult -Healthy $true -Reason "rolled back to known-good v$($state.KnownGoodProvider)" -Version $state.KnownGoodProvider
            }
        }
        & $Log "Rollback to v$($state.KnownGoodProvider) did not restore token generation."
    }

    # --- 4. Degrade ---
    $state.LastFailure = (Get-Date).ToString("o")
    Write-PotState -StateFile $paths.StateFile -State $state
    Stop-PotServer -Paths $paths
    return New-PotResult -Healthy $false -Reason "no working PO token provider available; YouTube may have changed BotGuard and an upstream fix has not shipped yet" -Version $installedServer
}

# =====================================================================
# STANDALONE DIAGNOSTIC MODES
# =====================================================================
# Guarded so that dot-sourcing this file (which runs the whole body) has
# no side effects at all -- see DUAL USE at the top.

if ($SelfTest -or $Install -or $Stop -or $Status) {
    $p = Get-PotPaths -ProviderPort $Port

    if ($Stop) {
        Stop-PotServer -Paths $p
        Write-Host "Provider server stopped (if it was running)."
    }

    if ($Status) {
        $st = Read-PotState -StateFile $p.StateFile
        Write-Host "Provider root:      $($p.PotRoot)"
        Write-Host "Server version:     $(Get-InstalledPotServerVersion -Paths $p)"
        Write-Host "Plugin version:     $(Get-InstalledPotPluginVersion)"
        Write-Host "Current upstream:   $(Get-PotTargetVersion)"
        Write-Host "yt-dlp version:     $(Get-YtDlpVersion)"
        Write-Host "Server responding:  $(Test-PotServerAlive -Paths $p)"
        Write-Host "Known-good pair:    provider v$($st.KnownGoodProvider) / yt-dlp $($st.KnownGoodYtDlp)"
        Write-Host "Last verified:      $($st.LastVerified)"
        Write-Host "Last failure:       $($st.LastFailure)"
    }

    if ($Install -or $SelfTest) {
        $result = Initialize-PotProvider -ProviderPort $Port
        Write-Host ""
        Write-Host "Healthy:        $($result.Healthy)"
        Write-Host "Reason:         $($result.Reason)"
        Write-Host "Player clients: $($result.PlayerClients)"
        if (-not $result.Healthy) {
            Write-Host ""
            Write-Host "Downloads will still run, on yt-dlp's default clients, but anything"
            Write-Host "downloaded while degraded is withheld from the download archive and"
            Write-Host "listed in Archive Logs/Logs/needs-refetch.txt so it can be re-fetched"
            Write-Host "at full quality once a working provider is available."
        }
    }
}
