# The test suite — design notes

*Commit 1 of 2. Written against `7642007`, before the comment-completeness
audit landed. Commit 2 covers the audit.*

Added `tests/` to the repo. One command, all three platforms, ~95 tests,
about two minutes, no network and no YouTube.

```bash
./tests/run-tests            # Linux, macOS
tests\run-tests.cmd          # Windows
./tests/run-tests -Live      # plus one real download
```

Full usage lives in `tests/README.md`. This document is the *why*.

## Shape

Same organizing principle as the pipeline: `run-tests` (bash) and
`run-tests.cmd` are shims with no logic; everything lives once in
`run-tests.ps1`. A test that passes on one platform is testing the same
thing on all three because there is one runner, not three kept in agreement
by hand.

```
tests/
  run-tests           run-tests.cmd        run-tests.ps1
  lib/  Harness.ps1   Fixtures.ps1   Report.ps1
  suites/  010-syntax  020-launcher  030-config  040-run-ytdlp
           050-postprocess  060-locking  070-installer  080-viewer  090-live
```

## Three decisions worth recording

**Not Pester.** The obvious choice, rejected for the same reason this repo
has no package manifest: it makes "can I run the tests" depend on a module
install succeeding on Windows, macOS and four Linux families before a single
assertion runs. This suite is what you reach for when you are *not sure the
environment is right* — it cannot itself be the part that fails to install.
The framework is ~270 lines of stock pwsh 7, which the pipeline already
requires.

**yt-dlp is stubbed, ffmpeg is not.** The stub records every invocation,
which is what turns "the code looks like it passes `--ignore-config`" into
"`--ignore-config` was passed, and `--download-archive` pointed at the
archive file under the data root actually used for this run". ffmpeg and
ffprobe stay real: they are genuinely installed everywhere this runs, they
are fast, and stubbing them would hide exactly the container-level failures
(a remux producing a zero-byte file) the pipeline has guards for. Where they
are absent, tests skip rather than fail.

The stub itself is the repo's own launcher pattern reused — one PowerShell
body behind an extensionless shim and a `.cmd` shim, because a native
command lookup finds the first on Unix and the second on Windows.

**Skips are not failures.** A missing optional dependency reports SKIP with
a reason. A suite that cries wolf about an optional tool is a suite you learn
to ignore — the same failure mode `checksums.sha256` already had when it
always reported one bad line.

## Nothing touches the real archive

Every suite builds a fixture tree under the system temp directory and points
`YTDLP_INSTALL_ROOT` at it. `New-TestRoot` refuses outright to return a path
inside a real install root. Three real side effects, all contained:

- The installer dry-run creates and deletes `YT-DLP Installation Files`
  inside a **copy** of the repo, never the working tree.
- On Windows it snapshots and restores the user `Path` variable, because the
  installer legitimately writes to it.
- The shell-profile append is skipped by putting the test bin directory on
  `PATH` first.

## What is actually covered

Every bug the project has already found once now has a test phrased as the
thing that should be true:

| Past bug | Test |
|---|---|
| `Get-Item` without `-Force` on a dot-prefixed marker | the dependency check throttles to once a day; the Channel Info refresh honours its six-hour throttle |
| `$videoIds[0..($cutIndex - 1)]` reading `0..-1` as a descending range | `--sync` queues nothing when the newest video is already archived |
| `video_postprocessing.log` hashed while still being written | every line of `checksums.sha256` actually verifies |
| Missing `\[comments\]` anchor doubling the request count | each comment API request is counted exactly once |
| `--exec` firing for `--keep-video` pre-merge streams | a pre-merge stream writes no manifest and never reaches Final Video |
| Lost manifest updates under `-Workers` | six real concurrent processes across two channels lose nothing |
| `$rest` unrolling to a bare string | `ytdl <url> /some/path` with exactly one extra argument |

Plus invariants that previously lived only in comments: the `-o` template
directory depth, the config-is-static rule, `setup.ps1` staying 5.1-compatible
(checked against the syntax tree, so a `?` in a string cannot false-alarm),
step-count agreement across all three installer halves, `$ProjectFiles` ↔
`Install-ProjectFile` coverage, the launcher shims containing no argument
parsing, and the viewer's read-only and no-path-routes guarantees.

## The suite was itself tested

Eleven deliberate regressions were introduced into the pipeline one at a
time; each was caught by the test that should have caught it. That exercise
changed one test and found one harness bug:

- **The lost-update check now pre-seeds `global_manifest.json` with 300
  entries.** Against an empty manifest the read-modify-write finishes in
  microseconds and two unsynchronized instances could miss each other by
  luck — removing the lock did *not* reliably fail the test. A real archive
  has hundreds of entries there anyway, so the fixture is more faithful for
  it. With the seed, lock removal fails 3/3.
- **The stub's call log needed `FileShare.None`, not `FileShare.Read`.** On
  Unix, .NET implements `FileShare` with `flock`, and anything short of
  `None` maps to a *shared* lock — so two concurrent stubs both acquired it,
  both seeked to the same end-of-file offset (`FileMode.Append` does not use
  `O_APPEND`), and one record silently overwrote the other. No exception, no
  corrupt line, just a call log one entry short. It surfaced as an
  intermittent "expected 3 downloads, found 2" in the `-Workers` tests about
  one run in five. Worth knowing generally: `FileShare.Read` is not mutual
  exclusion on Unix.

## `-Live` and the comments cap

The comments pass costs roughly one HTTP request per comment *thread*, so an
uncapped live run against a popular video is hours, and a test that takes
hours is a test nobody runs. Unless `-LiveFullComments` is given, a
**pass-through** shim (not a stub) sits in front of the real yt-dlp and adds
`--extractor-args "youtube:max_comments=N,all,all,0"` to the comments pass
only; every other argument the pipeline built reaches the real yt-dlp
untouched. Comment volume is the one thing the live suite deliberately does
not exercise at full scale.

The live run leaves its archive in the temp directory and prints the path.

## Verification status of the suite itself

Written and run against **Linux** (Ubuntu 24.04, pwsh 7.4.6, ffmpeg 6.1,
python 3.11): 94 passed, 1 skipped (the opt-in live suite), stable across
repeated runs. The macOS and Windows branches are statically checked only —
same caveat the pipeline itself carries. The suite is built to run there
unmodified; the first runs on macOS 26 and Windows 11 are the real test of
that, and any failure they surface is as likely to be in the harness as in
the pipeline.

## Two things found while writing it

**1. The comment-completeness audit is not in the repo.**
`claude/comment-fetch-performance.md` documents a post-merge audit block in
`postprocess.ps1` — `comment_audit` in `manifest.json`, `duplicate_ids` /
`orphan_replies` / `pinned_count`, the `videos.list?part=statistics`
cross-check, `YTDLP_YOUTUBE_API_KEY`, `YTDLP_COMMENT_AUDIT_TOLERANCE`, the
key-redaction rule. None of it exists in `main` as of `7642007`; the only
change in that commit was `--sleep-requests 2 → 0.25`. Either the audit was
never committed or the doc got ahead of the code. No tests were written for
it. If it lands, it wants roughly six: the three local invariants, the
tolerance boundary, the missing-key path, and a check that a 400 carrying
the key in its message is redacted before logging.

*(It landed in `450737c`. That is what commit 2 covers.)*

**2. The viewer picks a pre-merge stream if `postprocess.ps1` has not run.**
`archive-viewer.py` chooses the video with
`"pre-merge" not in f["folder"].lower()` — a folder-name test only. In a
folder where the streams are still in `Final files/` (postprocess crashed,
or the archive predates the relocation), a video-only `Final Video.f248.webm`
sorts first and gets served as the video: no audio, no error. Adding a
filename check for yt-dlp's `Final Video.f<id>.<ext>` pattern alongside the
folder check closes it. Low severity — the window is normally seconds — but
it is a one-line fix and the test fixture for it already exists
(`New-VideoFolder -WithPreMergeStreams -PreMergeUnrelocated`).
