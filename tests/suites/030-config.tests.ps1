<#
    config/yt-dlp.conf, and the invariants the rest of the pipeline silently
    depends on it holding.

    Two of these are worth more than the rest.

    The OUTPUT TEMPLATE DEPTH test encodes what CLAUDE.md calls load-bearing:
    postprocess.ps1 finds the data root by walking up four levels from the
    file yt-dlp hands it, and archive-viewer.py discovers videos by looking
    exactly two levels under "Complete Archive". Neither reads the config.
    So adding or removing one directory level in an -o template silently
    breaks path derivation everywhere, with no error at the point of change
    and a confusing one much later. A template that no longer produces
    <Uploader>/<Uploader> - <date> - <id> - <title>/<subfolder>/<file>
    should fail here, immediately, next to the line that changed it.

    The CONFIG-IS-STATIC test guards the reason this file needs no per-user
    sed pass: anything requiring a real $HOME path lives on the command line
    in run_ytdlp.ps1, because yt-dlp config files do no ~ or $HOME
    expansion. Moving one back would reintroduce the exact problem the
    design removed, and would do it quietly -- the literal path would simply
    be wrong on every machine but the one it was written on.
#>

Describe 'yt-dlp.conf' {

    $confPath = Join-Path $script:RepoRoot 'config/yt-dlp.conf'
    $confRaw  = Get-Content -LiteralPath $confPath -Raw
    # "Active" = the settings yt-dlp actually reads. Every assertion about
    # presence or absence below runs against these lines only, because this
    # file's comments deliberately DISCUSS the options that were removed and
    # must not be re-added -- grepping the whole file would flag the very
    # documentation that exists to prevent the mistake.
    $active = @(Get-Content -LiteralPath $confPath |
                Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$' })

    It 'declares a numeric CONFIG_VERSION both scripts can read' {
        Assert-Match '(?m)^#\s*CONFIG_VERSION:\s*\d+\s*$' $confRaw `
            'CONFIG_VERSION must be a bare number on its own comment line'
        # Both scripts parse it with the same pattern and record it in
        # manifest.json and download.log. Asserted against the scripts'
        # actual regex rather than a re-typed one, so a change to either
        # side shows up here.
        foreach ($rel in @('scripts/run_ytdlp.ps1', 'scripts/postprocess.ps1')) {
            Assert-FileMatches (Join-Path $script:RepoRoot $rel) 'CONFIG_VERSION:\\s\*\(\\S\+\)' `
                "$rel must still read CONFIG_VERSION out of the conf file"
        }
        $m = [regex]::Match($confRaw, '(?m)^#\s*CONFIG_VERSION:\s*(\d+)')
        Assert-True ([int]$m.Groups[1].Value -gt 0) 'CONFIG_VERSION should be a positive integer'
    }

    It 'holds nothing that needs a real $HOME path (the config-is-static invariant)' {
        # yt-dlp config files are plain text with no ~ or $HOME expansion,
        # which is why these four live on the command line instead.
        foreach ($opt in @('--download-archive', '--paths', '--exec', '--js-runtimes')) {
            $offenders = @($active | Where-Object { $_ -match ('(^|\s)' + [regex]::Escape($opt) + '(\s|=|$)') })
            if ($offenders.Count -gt 0) {
                throw "$opt is back in yt-dlp.conf: '$($offenders[0])'. It needs a resolved path, and this file has no ~/`$HOME expansion -- build it in run_ytdlp.ps1 and pass it on the command line."
            }
        }
    }

    It 'keeps the settings the post-processing pipeline depends on' {
        # Each of these is a load-bearing dependency of postprocess.ps1, not
        # a preference: remove one and a specific later step stops working.
        $required = [ordered]@{
            '--merge-output-format mkv' = 'postprocess.ps1 gates its entire pipeline on the file being .mkv'
            '--keep-video'              = 'the "Pre-merge streams/" relocation exists only because this leaves them behind'
            '--no-embed-info-json'      = 'the info.json embed is deferred and done by hand AFTER the comments merge'
            '--write-info-json'         = 'the sidecar info.json is the input to almost every later step'
            '--write-thumbnail'         = 'Thumbnail.png is generated locally from whatever this saves'
        }
        foreach ($opt in $required.Keys) {
            $needle = ($opt -split ' ')[0]
            $found = @($active | Where-Object { $_ -match ('(^|\s)' + [regex]::Escape($needle) + '(\s|$)') })
            Assert-True ($found.Count -gt 0) "$opt is missing from yt-dlp.conf -- $($required[$opt])"
        }
    }

    It 'does not re-add the options that were deliberately removed' {
        # Each of these has a comment block in the conf file explaining what
        # broke when it was there. The comments are the design record; this
        # is the enforcement.
        foreach ($opt in @('--convert-thumbnails', '--windows-filenames')) {
            $offenders = @($active | Where-Object { $_ -match ('(^|\s)' + [regex]::Escape($opt) + '(\s|=|$)') })
            if ($offenders.Count -gt 0) {
                throw "$opt was removed on purpose and is back: '$($offenders[0])'. Read the comment block above it in config/yt-dlp.conf before restoring it."
            }
        }
    }

    It 'every -o template produces the exact directory depth the pipeline walks' {
        # <Uploader>/<Uploader> - <date> - <id> - <title>/<subfolder>/<file>
        # Three separators, no more, no fewer. postprocess.ps1 walks up
        # four levels from the file to find "Youtube Videos"; the viewer
        # discovers videos two levels under "Complete Archive".
        $templates = @($active | Where-Object { $_ -match '^\s*-o\s' })
        Assert-True ($templates.Count -ge 6) "expected the six -o templates, found $($templates.Count)"

        foreach ($line in $templates) {
            $m = [regex]::Match($line, '^\s*-o\s+"(?<body>.*)"\s*$')
            Assert-True $m.Success "could not parse the -o template: $line"
            $body = $m.Groups['body'].Value
            # Strip the optional "key:" prefix (subtitle:, thumbnail:, ...).
            # Matched against a known list rather than "anything before a
            # colon", so a template whose PATH contained a colon could not
            # be silently mis-parsed.
            $path = $body -replace '^(subtitle|thumbnail|description|infojson|link|pl_thumbnail|pl_infojson):', ''

            $segments = @($path -split '/')
            Assert-Equal 4 $segments.Count `
                "the -o template must be <uploader>/<video folder>/<subfolder>/<file>, which is four segments. This one has $($segments.Count): $path"

            Assert-Match '%\(uploader\)' $segments[0] `
                "the first segment must be the uploader folder: $path"
            Assert-Match '%\(uploader\)[^/]*-[^/]*%\(upload_date\)s[^/]*-[^/]*%\(id\)s[^/]*-[^/]*%\(title\)' $segments[1] `
                @"
the per-video folder name must stay "<uploader> - <upload_date> - <id> - <title>".
postprocess.ps1 parses exactly that shape out of the folder name when the
info.json is missing or unreadable, and it is the only metadata recovery path
there is. Template segment was: $($segments[1])
"@
        }
    }

    It 'the main pass and the comments pass pace themselves independently' {
        # The mismatch is deliberate and documented: the conf's value
        # governs the main download (a handful of requests, reliability
        # worth more than seconds), while the comments pass overrides it.
        # This test exists so someone "fixing the inconsistency" has to
        # read why first.
        $sleepLine = @($active | Where-Object { $_ -match '^\s*--sleep-requests\s' }) | Select-Object -First 1
        Assert-True ($null -ne $sleepLine) '--sleep-requests should still be set for the main download pass'
        $confValue = [double](($sleepLine -split '\s+')[1])

        $post = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts/postprocess.ps1') -Raw
        $m = [regex]::Match($post, '--sleep-requests\s+([0-9.]+)\s*`')
        Assert-True $m.Success 'postprocess.ps1 should set its own --sleep-requests in the comments pass'
        $commentsValue = [double]$m.Groups[1].Value

        Assert-True ($commentsValue -lt $confValue) `
            "the comments pass ($commentsValue) should pace faster than the main pass ($confValue) -- comment continuations are the cheap endpoint and there are thousands of them"
        Assert-Match '--ignore-config' $post `
            'the comments pass must set --ignore-config, or the conf value would apply to it after all'
    }

    It 'every extracting yt-dlp invocation passes --ignore-config' {
        # Without it a stray auto-discovered yt-dlp.conf (cwd, the per-user
        # config dir, next to the binary) merges its own options -- and its
        # own --exec lines -- into the run.
        #
        # Found via the syntax tree, one CommandAst at a time, rather than
        # by counting "& yt-dlp" against "--ignore-config" across the whole
        # file. Counting cannot tell WHICH invocation is missing the flag,
        # and it cannot distinguish the invocations that legitimately do not
        # need it: `yt-dlp -U` and `yt-dlp --version` neither extract nor
        # download, so an auto-discovered config has nothing to poison in
        # them. Those two are exempt by name; everything else must carry it.
        foreach ($rel in @('scripts/run_ytdlp.ps1', 'scripts/postprocess.ps1')) {
            $path = Join-Path $script:RepoRoot $rel
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
            $commands = @($ast.FindAll({
                $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                $args[0].GetCommandName() -eq 'yt-dlp'
            }, $true))

            Assert-True ($commands.Count -gt 0) "expected at least one yt-dlp invocation in $rel"

            foreach ($cmd in $commands) {
                # Compared as source text, not as CommandParameterAst nodes.
                # PowerShell parses a SINGLE-dash argument (-U) as a
                # CommandParameterAst but a DOUBLE-dash one
                # (--ignore-config) as a plain string constant, so a check
                # written against parameter nodes silently sees no arguments
                # at all on every yt-dlp call in this repo -- it would pass
                # for the wrong reason on the invocations that are correct.
                $argv = @($cmd.CommandElements | Select-Object -Skip 1 | ForEach-Object { $_.Extent.Text })
                $isInformational = ($argv.Count -eq 1) -and ($argv[0] -in @('-U', '--version'))
                if ($isInformational) { continue }
                if ($argv -notcontains '--ignore-config') {
                    throw "$rel line $($cmd.Extent.StartLineNumber): this yt-dlp invocation does not pass --ignore-config, so a stray yt-dlp.conf on the auto-discovery path could merge its own options (and --exec lines) into the run. Arguments were: $($argv -join ' ')"
                }
            }
        }
    }

    It 'every extracting yt-dlp invocation ends with "--" before its URL' {
        # The end-of-options marker, checked structurally for the same reason
        # --ignore-config is: it is the kind of thing that gets dropped when
        # a call site is copied and edited, and nothing fails until the one
        # video whose id happens to start with a hyphen.
        #
        # YouTube ids are base64url, so about one in thirty starts with "-"
        # or "_" -- "-QMgcOSyf-o" is an ordinary id. yt-dlp parses with
        # optparse, which reads ANY argument beginning with "-" as an option
        # wherever it appears, and the failure is a bare "Usage: yt-dlp
        # [OPTIONS] URL [URL...]" that names nothing. "--" ends option
        # parsing, costs nothing on an ordinary URL, and makes the whole
        # class of bug impossible.
        #
        # The invariant is positional, not just "contains --": the marker
        # only protects arguments that come AFTER it, so it must be the
        # second-to-last element, immediately before the URL.
        foreach ($rel in @('scripts/run_ytdlp.ps1', 'scripts/postprocess.ps1')) {
            $path = Join-Path $script:RepoRoot $rel
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
            $commands = @($ast.FindAll({
                $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                $args[0].GetCommandName() -eq 'yt-dlp'
            }, $true))

            foreach ($cmd in $commands) {
                $argv = @($cmd.CommandElements | Select-Object -Skip 1 | ForEach-Object { $_.Extent.Text })
                # Same two exemptions as above: neither takes a URL at all.
                $isInformational = ($argv.Count -eq 1) -and ($argv[0] -in @('-U', '--version'))
                if ($isInformational) { continue }

                if ($argv.Count -lt 2 -or $argv[-2] -ne '--') {
                    throw "$rel line $($cmd.Extent.StartLineNumber): this yt-dlp invocation does not pass '--' immediately before its URL, so a video id beginning with a hyphen would be read as an option and the run would die on a usage message. Last two arguments were: $(($argv | Select-Object -Last 2) -join ' ')"
                }
            }
        }
    }
}