# The test suite — design notes

*Commit 2 of 2. Current as of `450737c` (the comment-completeness audit).
Supersedes the commit 1 notes; the differences are listed under
"What changed in this commit" at the end.*

`tests/` in the repo. One command, all three platforms, 118 tests, about two
and a half minutes. Nothing reaches YouTube and nothing touches your archive.
(Not strictly offline: one test runs the real dependency check once, which on
Linux makes a single HTTPS request to github.com and queries the local package
manager. Both degrade to a logged warning with no network.)

```bash
./tests/run-tests            # Linux, macOS
tests\run-tests.cmd          # Windows
./tests/run-tests -Live      # plus one real download
```

Full usage lives in `docs/test-suite-usage.md`. This document is the *why*.

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
           050-postprocess  055-comment-audit  060-locking
           070-installer  080-viewer  090-live
```

## Four decisions worth recording

**Not Pester.** The obvious choice, rejected for the same reason this repo
has no package manifest: it makes "can I run the tests" depend on a module
install succeeding on Windows, macOS and four Linux families before a single
assertion runs. This suite is what you reach for when you are *not sure the
environment is right* — it cannot itself be the part that fails to install.
The framework is ~280 lines of stock pwsh 7, which the pipeline already
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
command lookup finds the first on Unix and the second on Windows. It lives
in `lib/Fixtures.ps1` as `New-YtDlpStub` and answers **all three** yt-dlp
calls postprocess makes, because a suite stubbing only the call it cares
about would let the other two reach a real yt-dlp pointed at YouTube.

**Blocks that cannot be reached from outside are extracted, not re-typed.**
The audit's API cross-check calls `Invoke-RestMethod`, which no PATH stub can
intercept. `Get-ScriptRegion` pulls that block out of the **shipped** file by
its comment markers and runs it with a shadowing function, so 403s, 400s,
missing counts and shortfall arithmetic are all reachable with no key, no
quota and no network. A copy of the block living in a test file would drift
within a release or two, and then the tests pass against code that no longer
runs anywhere. The markers are the cost: `Get-ScriptRegion` fails with a
specific message naming the marker it could not find, rather than silently
testing an empty string.

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
| `@($null)` yielding a one-element array in the audit | a video with no comments audits as 0 merged, not 1 |

Plus invariants that previously lived only in comments: the `-o` template
directory depth, the config-is-static rule, `setup.ps1` staying 5.1-compatible
(checked against the syntax tree, so a `?` in a string cannot false-alarm),
step-count agreement across all three installer halves, `$ProjectFiles` ↔
`Install-ProjectFile` coverage, the launcher shims containing no argument
parsing, the audit asking for exactly one quota unit, and the viewer's
read-only and no-path-routes guarantees.

## The suite was itself tested

Twenty deliberate regressions were introduced into the pipeline one at a
time; each was caught by the test that should have caught it. That exercise
changed two tests and found one harness bug:

- **The lost-update check now pre-seeds `global_manifest.json` with 300
  entries.** Against an empty manifest the read-modify-write finishes in
  microseconds and two unsynchronized instances could miss each other by
  luck — removing the lock did *not* reliably fail the test. A real archive
  has hundreds of entries there anyway, so the fixture is more faithful for
  it. With the seed, lock removal fails 3/3.
- **The key-redaction test was passing for the wrong reason.** The typed 403
  and 400 branches log *fixed* strings that never include the exception
  message, so deleting the redaction left them green. Only the generic branch
  logs `$auditMsg` verbatim. The test now drives a transport failure whose
  message carries the request URI — the shape that actually leaks — and
  additionally asserts that the underlying cause survives redaction, so a
  future "fix" that blanks the whole message also fails.
- **The stub's call log needed `FileShare.None`, not `FileShare.Read`.** On
  Unix, .NET implements `FileShare` with `flock`, and anything short of
  `None` maps to a *shared* lock — so two concurrent stubs both acquired it,
  both seeked to the same end-of-file offset (`FileMode.Append` does not use
  `O_APPEND`), and one record silently overwrote the other. No exception, no
  corrupt line, just a call log one entry short. It surfaced as an
  intermittent "expected 3 downloads, found 2" in the `-Workers` tests about
  one run in five. Worth knowing generally: `FileShare.Read` is not mutual
  exclusion on Unix.

The lesson from the second one generalises: a test that asserts an absence
(no key in the log, no file in the archive, no warning printed) can pass
because the code is right *or* because the test never reached the code path
that would be wrong. Mutation is the only cheap way to tell those apart.

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
python 3.11): 117 passed, 1 skipped (the opt-in live suite), stable across
repeated runs. The macOS and Windows branches are statically checked only —
same caveat the pipeline itself carries. The suite is built to run there
unmodified; the first runs on macOS 26 and Windows 11 are the real test of
that, and any failure they surface is as likely to be in the harness as in
the pipeline.

## What changed in this commit

Against commit 1, which predates the comment audit:

- **`suites/055-comment-audit.tests.ps1` is new** — 23 tests over the audit
  block added in `450737c`, in two halves. The local invariants run against
  the real `postprocess.ps1` with no API key, which is also the common
  production case. Every API cross-check branch runs from the block extracted
  out of the shipped file with `Invoke-RestMethod` shadowed.
- **`lib/Fixtures.ps1` gained `New-YtDlpStub` and `Get-ScriptRegion`.** The
  first is the three-call stub, moved out of `050-postprocess` so both suites
  share one copy and neither can accidentally reach a real yt-dlp; it also
  gained `YTDLP_TEST_COMMENT_SET` for producing duplicate / orphaned /
  double-pinned comment sets. The second is the block extractor described
  above.
- **`suites/050-postprocess.tests.ps1` lost its inline stub** and calls
  `New-YtDlpStub` instead. No test in it changed.
- **The existing 94 tests passed unchanged against `450737c`**, which is
  worth recording on its own: adding the audit disturbed neither the comments
  pass, nor the manifest shape, nor anything downstream of either.
- Nine further mutations were run against the new suite, which is what caught
  the key-redaction test passing for the wrong reason.

## Open findings

**The viewer picks a pre-merge stream if `postprocess.ps1` has not run.**
`archive-viewer.py` chooses the video with
`"pre-merge" not in f["folder"].lower()` — a folder-name test only. In a
folder where the streams are still in `Final files/` (postprocess crashed, or
the archive predates the relocation), a video-only `Final Video.f248.webm`
sorts first and gets served as the video: no audio, no error. Adding a
filename check for yt-dlp's `Final Video.f<id>.<ext>` pattern alongside the
folder check closes it. Low severity — the window is normally seconds — and
the test fixture already exists
(`New-VideoFolder -WithPreMergeStreams -PreMergeUnrelocated`).

**A malformed sidecar `info.json` aborts post-processing outright.** The
first read — `$info = Get-Content $infoJsonFile.FullName -Raw |
ConvertFrom-Json`, near the top of `postprocess.ps1` — is not wrapped, and
`$ErrorActionPreference` is `Stop`, so bad JSON throws straight to the outer
catch. A *missing* info.json degrades gracefully (id/title/date are recovered
from the folder name and the run continues); an *unreadable* one does not,
even though `archive-viewer.py` already tolerates both. That video then gets
no `checksums.sha256`, no `manifest.json`, no manifest entries and never
reaches the Final Video repository, and re-running does not fix it. The
realistic way in is an interrupted write of the sidecar itself — the comments
merge rewrites that exact file, so a crash or a full disk mid-merge leaves
truncated JSON behind. It fails loudly, which is much better than most of
what this suite guards against, and it is rare. Current behaviour is pinned
by *aborts loudly, and early, on an unparseable sidecar info.json* in
`055-comment-audit`, which carries the replacement assertions in a comment
for whenever the parse is made tolerant.
