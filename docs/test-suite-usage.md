# tests/

The automated test suite for the yt-dlp archival pipeline. One command, all
platforms, no dependencies to install first.

```bash
./tests/run-tests            # Linux, macOS
tests\run-tests.cmd          # Windows
```

118 tests, about two and a half minutes, no network and no YouTube. It writes a
pass/fail summary to the console and a self-contained HTML report to
`tests/results/results.html`, and exits non-zero if anything failed.

## What it is

Same organizing principle as the pipeline itself: **`run-tests` (bash) and
`run-tests.cmd` are shims with no logic in them.** Everything lives once, in
`run-tests.ps1`, so a test that passes on one platform is testing the same
thing on all three because there is one runner, not three kept in agreement
by hand.

It is deliberately **not** Pester. Pester is the obvious choice and was
rejected for the same reason this repo has no package manifest: it would
make "can I run the tests" depend on a module install succeeding on Windows,
macOS and four Linux families before a single assertion runs. This suite is
what you reach for when you are not sure the environment is right — it
cannot itself be the part that fails to install. Everything is stock pwsh 7,
which the pipeline already requires.

## What it does not touch

Every suite builds its own fixture tree under the system temp directory,
points `YTDLP_INSTALL_ROOT` at it, and replaces `yt-dlp` with a recording
stub. `New-TestRoot` refuses outright to hand back a path inside a real
install root. **Nothing in a normal run reads or writes your real archive,
and nothing reaches YouTube.**

Three side effects are worth naming because they are real:

- The installer dry-run creates and deletes a `YT-DLP Installation Files`
  folder inside a **copy** of the repo, never your working tree.
- On Windows, that same test snapshots and restores the user `Path`
  environment variable, because the installer legitimately writes to it.
- The shell-profile append (`~/.bashrc` / `~/.zshrc`) is skipped, because
  the test puts its bin directory on `PATH` first.

## The suites

| File | Covers |
|---|---|
| `010-syntax` | Every file parses. `bash -n`, `py_compile`, the PowerShell parser. LF line endings on the POSIX shims. `setup.ps1` still 5.1-compatible. The launcher shims still contain no argument parsing. |
| `020-launcher` | `ytdl.ps1` argument parsing, against a stand-in `run_ytdlp.ps1` whose `param()` block mirrors the real one — so a flag the launcher emits that `run_ytdlp.ps1` could not bind fails here. |
| `030-config` | `yt-dlp.conf` invariants: `CONFIG_VERSION`, the config-is-static rule, the removed options staying removed, `--ignore-config` on every extracting invocation, and the exact directory depth every `-o` template must produce. |
| `040-run-ytdlp` | Folder self-heal, command-line construction, the archive-history snapshot, the once-a-day dependency throttle, distinct-id counting in the session summary, and the whole `-Workers` path including `--sync` truncation. |
| `050-postprocess` | The per-video pipeline end to end against fabricated folders: the `.mkv` gate, pre-merge relocation, the comments pass and its telemetry, the info.json re-embed, `checksums.sha256`, both manifests, the Channel Info throttle, the Final Video sync, and the `_incomplete` sweep. |
| `055-comment-audit` | The comment completeness audit: local invariants (duplicates, orphan replies, more than one pinned) run against the real `postprocess.ps1`, plus every API cross-check branch — shortfall arithmetic, tolerance, 403, 400, key redaction — run from the block extracted out of the shipped file with `Invoke-RestMethod` shadowed, so no key, quota or network is involved. |
| `060-locking` | Six real concurrent `postprocess.ps1` processes across two channels, checking that no manifest update is lost. |
| `070-installer` | Step-count agreement across all three halves, `$ProjectFiles` ↔ `Install-ProjectFile` coverage, the keep-going error handling, no `curl \| sh`, plus a real dry run of the shared half from a local checkout. |
| `080-viewer` | `archive-viewer.py` started for real and driven over HTTP: routes, metadata, comments, the read-only invariant (before/after inventory of the whole archive), and nine path-traversal probes. |
| `090-live` | Opt-in. One real video, real yt-dlp, real ffmpeg, real network. Skipped unless `-Live`. |

## Options

```
-Suite '05*'              only that suite file (others are never loaded)
-Filter '*comments*'      wildcard against "<suite name> <test name>"
-ShowOutput               echo each test's captured output as it runs
-StopOnFail               stop at the first failure
-NoReport                 console only
-ReportPath <path>        somewhere other than tests/results/results.html

-Live                     also run the real-download suite
-LiveUrl <url>            which video (default: the first YouTube video ever)
-LiveMaxComments <n>      cap the comments pass (default 100)
-LiveFullComments         no cap — as long as archiving that video normally takes
```

### About `-Live` and the comments cap

The comments pass costs roughly one HTTP request per comment **thread**, so an
uncapped live run against a popular video is hours, and a test that takes
hours is a test nobody runs. Unless you pass `-LiveFullComments`, a
*pass-through* shim sits in front of the real `yt-dlp` and adds
`--extractor-args "youtube:max_comments=N,all,all,0"` to the comments pass
only. Everything else — every argument the pipeline built — reaches the real
`yt-dlp` untouched. Comment volume is the one thing the live suite
deliberately does not exercise at full scale.

The live run leaves its archive in the temp directory rather than deleting
it, and prints the path. It is the most useful thing to look at when
something about that run was surprising.

## Skips are not failures

A missing **optional** dependency reports `SKIP`, with the reason, not
`FAIL`. `ffmpeg`/`ffprobe` absent skips the thumbnail, re-embed and live
tests; no `python3` skips the viewer suite; `bash` absent (Windows) skips the
POSIX-shim tests. This is deliberate: a suite that cries wolf about an
optional tool is a suite you learn to ignore, which is exactly the failure
mode this project already documented for `checksums.sha256`.

## Adding a test

Drop a `NNN-name.tests.ps1` file in `suites/`. It is dot-sourced by the
runner, so `Describe`, `It`, the `Assert-*` functions, `Skip-Test` and every
fixture builder are already in scope, as are `$script:RepoRoot` and
`$script:IncludeLive`.

```powershell
Describe 'some component' {
    It 'does the thing' {
        $r = New-TestRoot -Label 'my-test'
        try {
            Install-PipelineInto -TestRoot $r -RepoRoot $script:RepoRoot
            Enable-Stubs -TestRoot $r
            New-YtDlpStub -TestRoot $r | Out-Null      # handles all three yt-dlp calls

            $video = New-VideoFolder -TestRoot $r -SeedChannelInfoThrottle
            $result = Invoke-Postprocess -TestRoot $r -FilePath $video.MkvPath

            Assert-Match 'Post-processing complete' $result.Output
            Assert-Match '--sleep-requests 0\.25' (Get-StubCalls -TestRoot $r -Name 'yt-dlp')[0].line
        } finally { Remove-TestRoot $r }
    }
}
```

Use `New-YtDlpStub` for anything that runs `postprocess.ps1`. It answers all
three of the yt-dlp calls that script makes — the version query, the comments
pass and the Channel Info refresh — because a stub that covers only the call
you care about lets the other two fall through to whatever real yt-dlp is
installed, which on your own machine is a real one pointed at YouTube. Its
comment payload is steered by `YTDLP_TEST_COMMENT_SET`
(`clean`/`dupes`/`orphans`/`twopinned`) and `YTDLP_TEST_COMMENT_EMPTY`.

For a branch that cannot be reached from outside — a cmdlet call you need to
fake, like the audit's `Invoke-RestMethod` — `Get-ScriptRegion` pulls one
comment-delimited block out of the **shipped** file so it can be run with a
shadowing function. Extracting rather than re-typing matters: a copy of the
block in a test file drifts within a release or two, and then the tests pass
against code that no longer runs anywhere.

Two things about writing behaviour stubs. The scriptblock is serialised to a
file, so it **cannot close over outer variables** — pass values in through
environment variables. And every invocation is recorded regardless of what
the behaviour does, which is what makes "was `--ignore-config` actually
passed" an assertable fact rather than something you confirm by reading the
source and hoping.

Write assertion messages as **the thing that should be true**, not the
mistake that was made, and put the *why* in the message — these tests get run
on machines you are not sitting at, and the message is the whole report.

## Does the suite actually catch anything?

It was checked by mutation: twenty deliberate regressions were introduced
into the pipeline one at a time, and each was caught by the test that should
have caught it.

| Regression introduced | Caught by |
|---|---|
| `\[comments\]` anchor removed from the request counter | *counts each comment API request exactly once* |
| `$cutIndex -eq 0` guard removed from `--sync` truncation | *queues nothing when --sync finds the newest video already archived* |
| `-Force` removed from the Channel Info throttle read | *honours the six-hour Channel Info refresh throttle* |
| `-Force` removed from the dependency-check marker read | *throttles the dependency check to once a day* |
| Self-log exclusion removed from `checksums.sha256` | *writes a checksums.sha256 in which every line actually verifies* |
| `.mkv` gate removed | *skips everything for a --keep-video pre-merge stream* |
| Global manifest lock removed | *loses no global manifest updates …* (3/3 runs) |
| A directory level added to an `-o` template | *every -o template produces the exact directory depth …* |
| A ternary added to `setup.ps1` | *setup.ps1 stays compatible with Windows PowerShell 5.1* |
| `--ignore-config` dropped from the comments pass | *every extracting yt-dlp invocation passes --ignore-config* |
| Pre-merge relocation removed | *moves pre-merge streams out of Final files …* |
| `@($null)` guard removed from the audit's `merged_count` | *reports zero comments as zero, not one* |
| API key redaction removed | *redacts the key from an untyped transport failure* |
| `parent = "root"` no longer excluded from the orphan check | *does not count a top-level comment as an orphan* |
| Negative shortfall clamp removed | *clamps a negative shortfall to zero* |
| A second `part=` added to the API request | *asks only for the statistics part, which is one quota unit* |
| Local invariants gated behind the API key | *runs the local invariants even when the API half is unavailable* |
| Tolerance range validation removed | *honours YTDLP_COMMENT_AUDIT_TOLERANCE …* |
| Duplicate-id check removed | *catches duplicate comment ids* |
| `comment_audit` dropped from `manifest.json` | *records the audit in manifest.json …* |

That exercise changed two tests and found one bug in the harness itself:

- The lost-update check now pre-seeds `global_manifest.json` with 300
  entries. Against an empty manifest the read-modify-write finishes in
  microseconds and two unsynchronized instances could miss each other by
  luck — lock removal did *not* reliably fail the test. A real archive has
  hundreds of entries there anyway, so the fixture is more faithful for it.
  With the seed, lock removal fails 3/3.
- The key-redaction test was passing for the wrong reason. The typed 403 and
  400 branches log **fixed** strings that never contain the exception
  message, so deleting the redaction left them green; only the generic
  branch logs the message verbatim. The test now drives a transport failure
  whose message carries the request URI — the shape that actually leaks.
- The stub's call log needed `FileShare.None`, not `FileShare.Read`. On Unix
  .NET implements `FileShare` with `flock`, and anything short of `None` maps
  to a **shared** lock, so two concurrent stubs both acquired it, both seeked
  to the same end-of-file offset (`FileMode.Append` does not use `O_APPEND`),
  and one record silently overwrote the other. It surfaced as an intermittent
  "expected 3 downloads, found 2" in the `-Workers` tests about one run in
  five. If you ever see a count assertion fail intermittently, suspect the
  harness before the pipeline — and note that a lost record now leaves a
  marker that says so explicitly rather than looking like a lost update.

If you change the pipeline in a way these tests do not notice, that is worth
treating as a gap in the suite rather than a licence to skip it.
