<#
    The comment completeness audit in postprocess.ps1.

    This block exists because yt-dlp has no ground-truth count to check
    itself against, so a partial comment extraction is indistinguishable
    from a complete one -- no error, no warning, just fewer comments in the
    file. yt-dlp/yt-dlp#15303 was exactly that: 367 of 684 comments,
    silently. Fixed upstream, but the failure MODE is permanent, because
    comment extraction is scraping and scraping breaks quietly.

    Which makes the audit itself the thing that must not break quietly. It
    is the only part of this pipeline whose entire job is to notice
    something, and it runs on every video with nobody watching. Two ways of
    testing it here:

    IN THE RUNNING PIPELINE -- the local invariants and the manifest record,
    exercised by running the real postprocess.ps1 against fabricated comment
    sets. No API key is set, which is also the common case in production.

    AS AN EXTRACTED BLOCK -- the API cross-check branches, run with a
    shadowing Invoke-RestMethod so 403s, 400s, missing counts and shortfall
    arithmetic are all reachable without a key, without quota and without
    network. The block is pulled out of the SHIPPED file rather than
    re-typed, so these tests cannot drift into passing against code that no
    longer runs anywhere.

    The redaction test is the one to keep no matter what else changes here.
    The API key travels in the query string -- the form the Data API
    documents -- which means PowerShell can embed it in an exception message
    built from the request URI. A logged key ends up in download.log, in
    each video's video_complete.log, and in whatever anyone pastes into an
    issue.
#>

# ---------------------------------------------------------------------
# Part 1: the audit as it runs inside postprocess.ps1
# ---------------------------------------------------------------------

Describe 'Comment audit in the running pipeline' {

    function New-AuditRoot {
        param([string]$Label)
        $r = New-TestRoot -Label $Label
        Install-PipelineInto -TestRoot $r -RepoRoot $script:RepoRoot
        Enable-Stubs -TestRoot $r
        New-YtDlpStub -TestRoot $r | Out-Null
        $video = New-VideoFolder -TestRoot $r -SeedChannelInfoThrottle
        New-SessionLog -TestRoot $r | Out-Null
        $r | Add-Member -NotePropertyName Video -NotePropertyValue $video -Force
        return $r
    }

    function Get-AuditFromManifest {
        param($TestRoot)
        $manifestPath = Join-Path $TestRoot.Video.MetaDir 'manifest.json'
        Assert-PathExists $manifestPath
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        Assert-True ($null -ne $manifest.comment_audit) `
            'manifest.json must carry comment_audit on every run -- the whole point is that the numbers accumulate across the archive so the tolerance can be calibrated from real data'
        return $manifest.comment_audit
    }

    # The audit is the last thing that should ever break a download. Every
    # test below therefore also checks the run completed.
    It 'records the audit in manifest.json and runs local checks with no API key' {
        $r = New-AuditRoot -Label 'audit-nokey'
        try {
            $previousKey = $env:YTDLP_YOUTUBE_API_KEY
            $env:YTDLP_YOUTUBE_API_KEY = $null
            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            $env:YTDLP_YOUTUBE_API_KEY = $previousKey

            Assert-Match 'Post-processing complete' $result.Output
            Assert-Match 'Comment audit: local checks only' $result.Output
            Assert-Match 'YTDLP_YOUTUBE_API_KEY' $result.Output `
                'the message should name the variable that enables the cross-check'

            $audit = Get-AuditFromManifest $r
            Assert-Equal 'no_key' $audit.api_status
            Assert-Equal 3    $audit.merged_count
            Assert-Equal 0    $audit.duplicate_ids
            Assert-Equal 0    $audit.orphan_replies
            Assert-Equal 1    $audit.pinned_count
            Assert-Equal 0.05 $audit.tolerance 'the default tolerance is 5%'
            Assert-True ($null -eq $audit.api_comment_count) 'no API call was made, so there is no API count'
            Assert-True (-not [string]::IsNullOrWhiteSpace($audit.audited_at)) 'the audit should timestamp itself'
        } finally { Remove-TestRoot $r }
    }

    It 'stays silent on a clean comment set' {
        $r = New-AuditRoot -Label 'audit-clean'
        try {
            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            Assert-NotMatch 'comment audit -- \d+ duplicate' $result.Output
            Assert-NotMatch 'comment audit -- \d+ repl' $result.Output
            Assert-NotMatch 'comments flagged is_pinned' $result.Output
        } finally { Remove-TestRoot $r }
    }

    It 'catches duplicate comment ids' {
        $env:YTDLP_TEST_COMMENT_SET = 'dupes'
        $r = New-AuditRoot -Label 'audit-dupes'
        try {
            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            Assert-Match 'comment audit -- 1 duplicate comment id' $result.Output
            $audit = Get-AuditFromManifest $r
            Assert-Equal 1 $audit.duplicate_ids
            Assert-Match 'Post-processing complete' $result.Output 'a duplicate must warn, never fail the download'
        } finally { Remove-TestRoot $r; $env:YTDLP_TEST_COMMENT_SET = $null }
    }

    It 'catches replies whose parent was never captured' {
        # The sharpest local check: an orphan is proof of a mid-traversal
        # gap, and it costs no external call at all.
        $env:YTDLP_TEST_COMMENT_SET = 'orphans'
        $r = New-AuditRoot -Label 'audit-orphans'
        try {
            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            Assert-Match 'comment audit -- 2 repl' $result.Output
            Assert-Match 'extraction gap, not a display quirk' $result.Output
            $audit = Get-AuditFromManifest $r
            Assert-Equal 2 $audit.orphan_replies
        } finally { Remove-TestRoot $r; $env:YTDLP_TEST_COMMENT_SET = $null }
    }

    It 'does not count a top-level comment as an orphan' {
        # Top-level comments carry parent = "root", which is not a real
        # comment id. Counting those as orphans would make every video in
        # the archive report a gap, which is the same cry-wolf failure the
        # checksum file already had once.
        $r = New-AuditRoot -Label 'audit-root-parent'
        try {
            $null = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            $audit = Get-AuditFromManifest $r
            Assert-Equal 0 $audit.orphan_replies `
                'two of the three fixture comments have parent = "root"; neither is an orphan'
        } finally { Remove-TestRoot $r }
    }

    It 'catches more than one pinned comment' {
        $env:YTDLP_TEST_COMMENT_SET = 'twopinned'
        $r = New-AuditRoot -Label 'audit-pinned'
        try {
            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            Assert-Match '2 comments flagged is_pinned' $result.Output
            Assert-Match 'at most one per video' $result.Output
            $audit = Get-AuditFromManifest $r
            Assert-Equal 2 $audit.pinned_count
        } finally { Remove-TestRoot $r; $env:YTDLP_TEST_COMMENT_SET = $null }
    }

    It 'reports zero comments as zero, not one' {
        # @($info.comments) on an ABSENT property yields a one-element array
        # containing $null, so a video with comments disabled would report
        # merged_count = 1. Every audit number downstream is derived from
        # this one, so an off-by-one here is an off-by-one everywhere.
        $env:YTDLP_TEST_COMMENT_EMPTY = '1'
        $r = New-AuditRoot -Label 'audit-nocomments'
        try {
            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            $audit = Get-AuditFromManifest $r
            Assert-Equal 0 $audit.merged_count `
                'a video with no comments must audit as 0 merged, not 1 -- the explicit guard against @($null) yielding a one-element array'
            Assert-Match 'Post-processing complete' $result.Output
        } finally { Remove-TestRoot $r; $env:YTDLP_TEST_COMMENT_EMPTY = $null }
    }

    It 'honours YTDLP_COMMENT_AUDIT_TOLERANCE and rejects a nonsense value' {
        $r = New-AuditRoot -Label 'audit-tolerance'
        try {
            $env:YTDLP_COMMENT_AUDIT_TOLERANCE = '0.2'
            $null = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            Assert-Equal 0.2 (Get-AuditFromManifest $r).tolerance

            foreach ($bad in @('banana', '-0.1', '1.5')) {
                $env:YTDLP_COMMENT_AUDIT_TOLERANCE = $bad
                $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
                Assert-Match 'not a number between 0 and 1' $result.Output "'$bad' should be rejected"
                Assert-Equal 0.05 (Get-AuditFromManifest $r).tolerance `
                    "a rejected tolerance must fall back to the 0.05 default, not to `$null"
            }
        } finally { Remove-TestRoot $r; $env:YTDLP_COMMENT_AUDIT_TOLERANCE = $null }
    }

    It 'is never itself the thing that fails a download' {
        # An archive step whose entire job is to NOTICE a problem must not
        # become one. Each of these comment sets makes the audit find
        # something; all of them must still finish the run, write the
        # manifest, and sync the Final Video repository.
        foreach ($set in @('dupes', 'orphans', 'twopinned')) {
            $env:YTDLP_TEST_COMMENT_SET = $set
            $r = New-AuditRoot -Label "audit-nonfatal-$set"
            try {
                $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
                Assert-Match 'Post-processing complete' $result.Output "the '$set' set aborted the run"
                Assert-NotMatch 'ERROR during post-processing' $result.Output
                Assert-PathExists (Join-Path $r.Video.MetaDir 'manifest.json')
                Assert-PathExists (Join-Path $r.Video.MetaDir 'checksums.sha256')
                Assert-PathExists (Join-Path $r.Video.VideosRoot 'Final Video/Test Channel')
            } finally { Remove-TestRoot $r; $env:YTDLP_TEST_COMMENT_SET = $null }
        }
    }

    It 'aborts loudly, and early, on an unparseable sidecar info.json' {
        # DOCUMENTING CURRENT BEHAVIOUR, NOT ENDORSING IT.
        #
        # The FIRST read of the sidecar -- `$info = Get-Content ... |
        # ConvertFrom-Json`, near the top of the script -- is not wrapped,
        # and $ErrorActionPreference is "Stop", so malformed JSON throws
        # straight out to the outer catch. The script handles a MISSING
        # info.json gracefully (it recovers id/title/date from the folder
        # name and carries on), but not an unreadable one, even though the
        # viewer already tolerates both.
        #
        # The consequence: that video gets no checksums.sha256, no
        # manifest.json, no global/channel manifest entry and never reaches
        # the Final Video repository -- and re-running does not fix it,
        # because the sidecar is still malformed. The realistic way in is an
        # interrupted write of the sidecar itself: the comments merge
        # rewrites that exact file, so a crash or a full disk mid-merge
        # leaves truncated JSON behind.
        #
        # It fails LOUDLY, which is far better than most of what this suite
        # guards against, and it is rare. But if the parse is ever wrapped
        # so it falls back to the folder name the way a missing file does,
        # this test should be replaced by the assertions in the commented
        # block below.
        $r = New-AuditRoot -Label 'audit-broken-sidecar'
        try {
            $clean = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            Assert-Match 'Post-processing complete' $clean.Output 'the fixture itself should post-process cleanly'

            Set-Content -LiteralPath $r.Video.InfoPath -Value '{ this is not json' -Encoding utf8
            $broken = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath

            Assert-Match 'ERROR during post-processing' $broken.Output `
                'a malformed sidecar currently aborts the run -- it must at least do so loudly'
            Assert-Match 'Conversion from JSON failed' $broken.Output `
                'the error should name the actual cause, not just fail'
            Assert-NotMatch 'Post-processing complete' $broken.Output

            # If the parse is ever made tolerant, delete everything above
            # and assert this instead:
            #   Assert-Match 'Post-processing complete' $broken.Output
            #   Assert-PathExists (Join-Path $r.Video.MetaDir 'manifest.json')
            #   Assert-PathExists (Join-Path $r.Video.VideosRoot 'Final Video/Test Channel')
        } finally { Remove-TestRoot $r }
    }
}

# ---------------------------------------------------------------------
# Part 2: the API cross-check, run as an extracted block
# ---------------------------------------------------------------------

Describe 'Comment audit API cross-check' {

    $postprocessPath = Join-Path $script:RepoRoot 'scripts/postprocess.ps1'
    $auditBlock = Get-ScriptRegion -Path $postprocessPath `
                                   -StartMarker '# --- Comment completeness audit ---' `
                                   -EndMarker   '# --- Re-embed the (now comment-complete) info.json into the .mkv ---'

    function Invoke-AuditBlock {
        <#
            Runs the extracted block in a child pwsh with:
              * a Log function that records to a file
              * Invoke-RestMethod shadowed by a mock (a FUNCTION shadows a
                cmdlet of the same name, which is what makes this work
                without touching the shipped file)
              * $infoJsonFile / $videoId set up as postprocess.ps1 would
            and returns the resulting $commentAudit plus the log lines.

            A child process rather than in-process, so the shadowing
            function and the environment variables cannot leak into the rest
            of the suite.
        #>
        param(
            [Parameter(Mandatory = $true)]$TestRoot,
            [array]$Comments = @(),
            [string]$VideoId = 'testVideo01',
            [string]$ApiKey  = '',
            [string]$ApiMode = 'ok',
            [long]$ApiCount  = 3,
            [string]$Tolerance = ''
        )

        $work    = Join-Path $TestRoot.Root ('audit-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $infoPath  = Join-Path $work 'Info.info.json'
        $auditOut  = Join-Path $work 'audit.json'
        $logOut    = Join-Path $work 'audit.log'
        $uriOut    = Join-Path $work 'requested-uri.txt'
        $runner    = Join-Path $work 'run-audit.ps1'

        $payload = [ordered]@{ id = $VideoId; comment_count = $Comments.Count }
        if ($Comments.Count -gt 0) { $payload['comments'] = $Comments }
        $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $infoPath -Encoding utf8

        $prelude = @"
`$ErrorActionPreference = 'Stop'
`$script:AuditLog = [System.Collections.Generic.List[string]]::new()
function Log(`$msg) { `$script:AuditLog.Add("`$msg") }

# A FUNCTION of this name shadows the cmdlet, so the shipped block calls
# this instead without knowing anything about it.
function Invoke-RestMethod {
    param(`$Uri, `$Method, `$TimeoutSec, `$ErrorAction)
    Set-Content -LiteralPath '$uriOut' -Value "`$Uri"
    switch (`$env:YTDLP_TEST_API_MODE) {
        'noitems' { return [pscustomobject]@{ items = @() } }
        'nocount' { return [pscustomobject]@{ items = @([pscustomobject]@{ statistics = [pscustomobject]@{ viewCount = '10' } }) } }
        'forbidden' {
            `$r = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Response status code does not indicate success: 403 (Forbidden).', `$r)
        }
        'badrequest' {
            # The message deliberately CONTAINS the key, which is what a
            # real 400 built from the request URI does.
            `$r = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadRequest)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new("400 Bad Request for `$Uri", `$r)
        }
        'transport' {
            # The message embeds the full request URI -- and therefore the
            # key -- because that is what a real transport failure does.
            # A mock whose message did NOT contain the key would let the
            # redaction be deleted with every test still green: verified by
            # mutation, which is exactly how this line came to say so.
            throw "The remote name could not be resolved for `$Uri"
        }
        default {
            return [pscustomobject]@{ items = @([pscustomobject]@{ statistics = [pscustomobject]@{ commentCount = `$env:YTDLP_TEST_API_COUNT } }) }
        }
    }
}

`$infoJsonFile = Get-Item -LiteralPath '$infoPath'
`$videoId = if ([string]::IsNullOrWhiteSpace(`$env:YTDLP_TEST_VIDEO_ID)) { `$null } else { `$env:YTDLP_TEST_VIDEO_ID }

"@
        $epilogue = @"

`$commentAudit | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath '$auditOut'
`$script:AuditLog | Set-Content -LiteralPath '$logOut'
"@
        Set-Content -LiteralPath $runner -Value ($prelude + $auditBlock + $epilogue) -Encoding utf8

        $saved = @{
            Key       = $env:YTDLP_YOUTUBE_API_KEY
            Tolerance = $env:YTDLP_COMMENT_AUDIT_TOLERANCE
        }
        $env:YTDLP_YOUTUBE_API_KEY = $ApiKey
        $env:YTDLP_COMMENT_AUDIT_TOLERANCE = $Tolerance
        $env:YTDLP_TEST_API_MODE  = $ApiMode
        $env:YTDLP_TEST_API_COUNT = "$ApiCount"
        $env:YTDLP_TEST_VIDEO_ID  = $VideoId
        try {
            $stdout = & (Get-PwshPath) -NoProfile -File $runner 2>&1 | ForEach-Object { "$_" }
        } finally {
            $env:YTDLP_YOUTUBE_API_KEY = $saved.Key
            $env:YTDLP_COMMENT_AUDIT_TOLERANCE = $saved.Tolerance
            $env:YTDLP_TEST_API_MODE = $null
            $env:YTDLP_TEST_API_COUNT = $null
            $env:YTDLP_TEST_VIDEO_ID = $null
        }

        if (-not (Test-Path -LiteralPath $auditOut)) {
            throw "The extracted audit block did not complete. Output:`n$($stdout -join "`n")"
        }
        return [pscustomobject]@{
            Audit    = (Get-Content -LiteralPath $auditOut -Raw | ConvertFrom-Json)
            Log      = @(if (Test-Path -LiteralPath $logOut) { Get-Content -LiteralPath $logOut } else { @() })
            Uri      = $(if (Test-Path -LiteralPath $uriOut) { Get-Content -LiteralPath $uriOut -Raw } else { '' })
            Stdout   = @($stdout)
        }
    }

    $threeComments = @(
        [ordered]@{ id = 'c1';    text = 'one';   parent = 'root'; is_pinned = $true }
        [ordered]@{ id = 'c2';    text = 'two';   parent = 'root'; is_pinned = $false }
        [ordered]@{ id = 'c2.r1'; text = 'reply'; parent = 'c2';   is_pinned = $false }
    )

    $root = New-TestRoot -Label 'audit-api'

    It 'reports "within tolerance" when the archived count matches' {
        $run = Invoke-AuditBlock -TestRoot $root -Comments $threeComments -ApiKey 'AIzaSyTESTKEY000' -ApiCount 3
        Assert-Equal 'ok' $run.Audit.api_status
        Assert-Equal 3 $run.Audit.api_comment_count
        Assert-Equal 3 $run.Audit.merged_count
        Assert-Equal 0 $run.Audit.shortfall_ratio
        Assert-Match 'within tolerance' $run.Log
        Assert-NotMatch 'WARNING' $run.Log
    }

    It 'warns when the archive is short by more than the tolerance' {
        # The #15303 shape: roughly half the comments, silently. 3 of 100 is
        # 97% short, well past any tolerance anyone would set.
        $run = Invoke-AuditBlock -TestRoot $root -Comments $threeComments -ApiKey 'AIzaSyTESTKEY000' -ApiCount 100
        Assert-Equal 'ok' $run.Audit.api_status
        Assert-Equal 0.97 $run.Audit.shortfall_ratio
        Assert-Match 'WARNING: comment audit -- archived 3 of ~100' $run.Log
        Assert-Match '97% short' $run.Log
        Assert-Match 'Worth re-running the comments pass' $run.Log `
            'the warning should say what to do about it'
    }

    It 'stays quiet for a shortfall inside the tolerance' {
        # 97 of 100 is 3% short: inside the 5% default, because
        # statistics.commentCount is a cached approximation that drifts and
        # an equality check would produce constant false alarms.
        $ninetySeven = @(1..97 | ForEach-Object { [ordered]@{ id = "c$_"; text = "c$_"; parent = 'root'; is_pinned = $false } })
        $run = Invoke-AuditBlock -TestRoot $root -Comments $ninetySeven -ApiKey 'AIzaSyTESTKEY000' -ApiCount 100
        Assert-Equal 0.03 $run.Audit.shortfall_ratio
        Assert-Match 'within tolerance' $run.Log
        Assert-NotMatch 'WARNING' $run.Log
    }

    It 'respects a tolerance override in both directions' {
        $ninetySeven = @(1..97 | ForEach-Object { [ordered]@{ id = "c$_"; text = "c$_"; parent = 'root'; is_pinned = $false } })
        $tight = Invoke-AuditBlock -TestRoot $root -Comments $ninetySeven -ApiKey 'AIzaSyTESTKEY000' -ApiCount 100 -Tolerance '0.01'
        Assert-Equal 0.01 $tight.Audit.tolerance
        Assert-Match 'WARNING: comment audit -- archived 97 of ~100' $tight.Log `
            'a 3% shortfall must warn once the tolerance is 1%'

        $loose = Invoke-AuditBlock -TestRoot $root -Comments $threeComments -ApiKey 'AIzaSyTESTKEY000' -ApiCount 100 -Tolerance '0.99'
        Assert-Equal 0.99 $loose.Audit.tolerance
        Assert-NotMatch 'WARNING' $loose.Log 'a 97% shortfall is inside a 99% tolerance'
    }

    It 'clamps a negative shortfall to zero' {
        # Archiving MORE than the reported count is normal: the statistic
        # lags, and yt-dlp sees replies it may not include. That is not a
        # finding, and a negative ratio in the manifest would be noise in
        # every later calibration of the tolerance.
        $run = Invoke-AuditBlock -TestRoot $root -Comments $threeComments -ApiKey 'AIzaSyTESTKEY000' -ApiCount 2
        Assert-Equal 0 $run.Audit.shortfall_ratio
        Assert-NotMatch 'WARNING' $run.Log
    }

    It 'handles a video the API reports no comment count for' {
        $run = Invoke-AuditBlock -TestRoot $root -Comments $threeComments -ApiKey 'AIzaSyTESTKEY000' -ApiMode 'nocount'
        Assert-Equal 'comment_count_unavailable' $run.Audit.api_status
        Assert-Match 'comments disabled or hidden' $run.Log
        Assert-NotMatch 'WARNING' $run.Log 'comments being disabled is not a problem to warn about'
    }

    It 'handles a video the API does not return at all' {
        $run = Invoke-AuditBlock -TestRoot $root -Comments $threeComments -ApiKey 'AIzaSyTESTKEY000' -ApiMode 'noitems'
        Assert-Equal 'video_not_found' $run.Audit.api_status
        Assert-Match 'deleted, private, or region-blocked' $run.Log
    }

    It 'distinguishes a 403 from any other failure' {
        $run = Invoke-AuditBlock -TestRoot $root -Comments $threeComments -ApiKey 'AIzaSyTESTKEY000' -ApiMode 'forbidden'
        Assert-Equal 'forbidden_or_quota' $run.Audit.api_status
        Assert-Match 'quota exhausted, key restricted, or YouTube Data API v3 not enabled' $run.Log `
            'a 403 has three plausible causes and the message should name all of them'
        Assert-Match 'the download itself is unaffected' $run.Log
    }

    It 'never lets the API key reach a log line' {
        # THE test to keep. The key travels in the query string, so a real
        # 400 built from the request URI carries it in its message -- which
        # would then land in download.log, in every video_complete.log, and
        # in whatever gets pasted into an issue.
        $key = 'AIzaSyLEAKME_0123456789abcdefghij'
        $run = Invoke-AuditBlock -TestRoot $root -Comments $threeComments -ApiKey $key -ApiMode 'badrequest'

        Assert-Equal 'bad_request' $run.Audit.api_status
        Assert-Match 'almost always means YTDLP_YOUTUBE_API_KEY is malformed' $run.Log

        $everything = (@($run.Log) + @($run.Stdout) + @(($run.Audit | ConvertTo-Json -Depth 6))) -join "`n"
        Assert-NotMatch ([regex]::Escape($key)) $everything @"
The API key appeared in the audit's output. It travels in the query string,
so PowerShell can embed it in an exception message built from the request
URI -- every message logged from the catch must be passed through the
redaction first, and `$auditUri must never be logged directly.
"@
        # And the key really was sent, so the test is not passing simply
        # because no request was made.
        Assert-Match ([regex]::Escape($key)) $run.Uri `
            'the key should still be sent in the query string -- that is the form the Data API documents'
    }

    It 'redacts the key from an untyped transport failure' {
        # THIS is the test that actually holds the redaction in place, and
        # it took a mutation run to notice. The typed 403 and 400 branches
        # log FIXED strings that never contain the exception message, so
        # deleting the redaction line leaves them green. Only the generic
        # branch logs $auditMsg verbatim -- a DNS or TLS failure, which
        # produces no .Response and whose message carries the request URI,
        # key included.
        $key = 'AIzaSyLEAKME_0123456789abcdefghij'
        $run = Invoke-AuditBlock -TestRoot $root -Comments $threeComments -ApiKey $key -ApiMode 'transport'
        Assert-Equal 'error' $run.Audit.api_status
        Assert-Match 'API call failed' $run.Log
        Assert-Match 'could not be resolved' $run.Log `
            'the underlying cause should survive redaction -- redacting the key must not blank the whole message'
        Assert-NotMatch ([regex]::Escape($key)) (@($run.Log) -join "`n") @"
The API key reached a log line. It travels in the query string, so an
exception message built from the request URI carries it, and every message
logged from the catch must go through the redaction first. From there it
would land in download.log, in every video_complete.log, and in whatever
gets pasted into an issue.
"@
        Assert-Match '<redacted>' (@($run.Log) -join "`n") `
            'the redaction should leave a visible marker, so a reader can tell something was removed'
    }

    It 'skips the cross-check when no video id was resolved' {
        # postprocess.ps1 reaches this state when the info.json is missing
        # AND the folder name does not parse, which is rare but real.
        $run = Invoke-AuditBlock -TestRoot $root -Comments $threeComments -ApiKey 'AIzaSyTESTKEY000' -VideoId ''
        Assert-Equal 'no_video_id' $run.Audit.api_status
        Assert-Match 'API cross-check skipped' $run.Log
    }

    It 'runs the local invariants even when the API half is unavailable' {
        # The local checks cost nothing and must not be gated on the API
        # call succeeding -- an orphan reply is proof of a gap whether or
        # not a key exists.
        $broken = @(
            [ordered]@{ id = 'c1';      text = 'one';    parent = 'root';       is_pinned = $true }
            [ordered]@{ id = 'c1';      text = 'dupe';   parent = 'root';       is_pinned = $true }
            [ordered]@{ id = 'lost.r1'; text = 'orphan'; parent = 'lostParent'; is_pinned = $false }
        )
        $run = Invoke-AuditBlock -TestRoot $root -Comments $broken -ApiKey 'AIzaSyTESTKEY000' -ApiMode 'forbidden'
        Assert-Equal 'forbidden_or_quota' $run.Audit.api_status
        Assert-Equal 1 $run.Audit.duplicate_ids
        Assert-Equal 1 $run.Audit.orphan_replies
        Assert-Equal 2 $run.Audit.pinned_count
        Assert-Match 'duplicate comment id' $run.Log
        Assert-Match 'never captured' $run.Log
        Assert-Match 'at most one per video' $run.Log
    }

    It 'asks only for the statistics part, which is one quota unit' {
        # part=statistics on videos.list costs 1 unit, so this could audit
        # 10,000 videos a day. Asking for a heavier part, or using a
        # commentThreads call, would change that by orders of magnitude and
        # is the kind of edit that looks harmless.
        $run = Invoke-AuditBlock -TestRoot $root -Comments $threeComments -ApiKey 'AIzaSyTESTKEY000'
        Assert-Match 'youtube/v3/videos\?' $run.Uri `
            'the audit must use videos.list, not commentThreads -- fetching comments through the API would lose is_pinned, is_favorited and author_is_verified, none of which the API exposes'
        Assert-Match 'part=statistics' $run.Uri
        Assert-NotMatch 'part=[^&]*,' $run.Uri 'asking for more than one part costs more than one quota unit'
    }

    Remove-TestRoot $root
}
