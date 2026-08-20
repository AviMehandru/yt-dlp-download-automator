# Security Review

A pass through every file in the pipeline (`ytdl`, `run_ytdlp.ps1`,
`postprocess.ps1`, `yt-dlp.conf`, `setup.sh`), looking specifically for
injection risk, unsafe handling of untrusted data, and supply-chain
exposure. Overall verdict: **the core pipeline is sound**; the real findings
are all in `setup.sh`'s installer steps.

## What's already done right

**No shell-string command construction, anywhere.** Every call into
`yt-dlp`, `ffmpeg`, or `ffprobe` from PowerShell uses native array-style
argument passing (`& command arg1 arg2 ...`), not a single interpolated
string handed to a shell. This matters because several of those arguments
come from data that ultimately traces back to YouTube — video titles,
channel URLs, comment text, `original_url`/`channel_url` fields pulled out
of `info.json`. None of it is shell-executed at any point; a video titled
`` `rm -rf ~` `` or a comment containing `$(...)` is just a string,
never code. `ytdl`'s bash launcher does the same — `$URL`/`$CUSTOM_PATH`
are passed as `pwsh` parameter values, not concatenated into a command.

**The one place that *does* go through a shell (`--exec`) uses yt-dlp's
own injection-safe field expansion.** `run_ytdlp.ps1` builds the
`--exec` string with `%(filepath)q`, not `%(filepath)s`. `%q` is yt-dlp's
own shell-safe quoting for exactly this scenario — newer yt-dlp versions
actually *refuse* to expand plain `%()s`/`%()l` fields inside `--exec`
for this reason. This was already correctly handled before this review;
worth confirming it stays that way if the `--exec` line is ever touched
again.

**JSON parsing, not `Invoke-Expression`.** All `info.json`/comment/manifest
handling goes through `ConvertFrom-Json`/`ConvertTo-Json` — a real parser,
not a string-eval. There's no `Invoke-Expression` or similar dynamic-code
pattern anywhere in either `.ps1` file.

**No credentials in the pipeline at all.** No stored passwords, API keys,
or `--cookies-from-browser` usage — nothing here to leak.

**`--ignore-config` on every yt-dlp invocation** (main pass, comments pass,
channel-info pass) prevents a stray config file anywhere on yt-dlp's
auto-discovery path from silently injecting its own options — including a
malicious `--exec` line. This was a real, previously-hit bug in this
project's history and it's consistently guarded against now.

## Findings

### 1. `curl | sh` for Deno, with no integrity verification (setup.sh, Step 6)

```bash
curl -fsSL https://deno.land/install.sh | sh -s -- -y
```

This pipes a remote script straight into a shell with no checksum or
signature check. If `deno.land` were ever compromised, or a
man-in-the-middle occurred despite HTTPS (e.g. a compromised CA, a
malicious proxy on the network), this executes arbitrary code as your
user — and the binary that results then gets `sudo cp`'d to
`/usr/local/bin/deno`, where it will subsequently run with every
invocation of the pipeline.

**Severity**: Low-to-moderate in practice (this is an extremely common,
generally-accepted pattern — Deno's own official docs recommend it — and
the realistic attack surface is a compromise of `deno.land` itself or your
network's TLS trust, both low-likelihood). Worth hardening if you're
distributing this pipeline for others to run, less critical for personal
use on a single VM.

**Fix, if you want it**: download a pinned release archive instead and
verify against Deno's published checksums, e.g.:
```bash
DENO_VERSION="v2.x.x"  # pin a specific version
curl -fsSL "https://github.com/denoland/deno/releases/download/${DENO_VERSION}/deno-x86_64-unknown-linux-gnu.zip" -o /tmp/deno.zip
curl -fsSL "https://github.com/denoland/deno/releases/download/${DENO_VERSION}/deno-x86_64-unknown-linux-gnu.zip.sha256sum" -o /tmp/deno.zip.sha256
sha256sum -c /tmp/deno.zip.sha256
```

### 2. `yt-dlp` binary downloaded with no hash verification (setup.sh, Step 3)

```bash
sudo curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
sudo chmod a+rx /usr/local/bin/yt-dlp
```

yt-dlp publishes a `SHA2-256SUMS` file (and GPG signatures) alongside every
release. This installs the binary directly without checking either.

**Severity**: Same reasoning as above — low in practice given GitHub's own
TLS/integrity guarantees, but this is the single most-trusted binary in
the whole pipeline (it runs on every single invocation, with full access
to whatever the pipeline can touch), so it's the one most worth pinning if
you do only one of these fixes.

**Fix, if you want it**:
```bash
curl -fsSL https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS -o /tmp/yt-dlp-sums.txt
sudo curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
grep " yt-dlp$" /tmp/yt-dlp-sums.txt | sha256sum -c -
sudo chmod a+rx /usr/local/bin/yt-dlp
```

### 3. Predictable filenames in `/tmp` (setup.sh, Steps 4/6/7)

`/tmp/packages-microsoft-prod.deb`, `/tmp/deno-install.log`,
`/tmp/vmhgfs-mount.log` are all fixed, predictable names. On a genuinely
single-user VM (your actual setup) this is a non-issue. On a shared
multi-user machine, a fixed `/tmp` filename is a classic (if narrow) race
condition/symlink-attack vector — another local user could pre-create a
symlink at that path before your script writes to it.

**Severity**: Low, and essentially theoretical given this is a
single-user VM. Only worth fixing if this script ever runs somewhere
multi-tenant.

**Fix, if you want it**: swap fixed paths for `mktemp`, e.g.
`DENO_LOG="$(mktemp)"`.

### 4. `allow_other` on the VMware shared-folder mount (setup.sh, Step 7)

```bash
sudo vmhgfs-fuse .host:/ /mnt/hgfs -o subtype=vmhgfs-fuse,allow_other
```

`allow_other` makes the mount readable by every local user on the VM, not
just the one who mounted it — necessary for the mount to actually be
usable in the general case, but worth knowing about explicitly: if this
VM ever gets a second local account, that account can read (and via
default FUSE permissions, often write) whatever's shared from the host.

**Severity**: Low on a single-user VM (the expected setup here). Flagging
for awareness rather than as something to change.

### 5. No path validation on `-DataRoot` (run_ytdlp.ps1)

The optional custom data root is resolved to an absolute path but never
checked against anything — you could point it at `/etc`, `/root`, or
anywhere else your account can write to, and the pipeline would happily
create `Youtube Videos/` and `Archive Logs/` there.

**Severity**: Not really a vulnerability in this context — it's your own
tool, invoked by you, with your own account's actual permissions; pointing
it at a sensitive path isn't a privilege escalation, since anything it
could write there, you could already write there yourself. Only relevant
if this were ever wrapped by something with a different trust boundary
(e.g. a shared service invoking `ytdl` on other people's behalf) — not the
case today.

## Summary

| # | Issue | File | Severity |
|---|---|---|---|
| 1 | Unverified `curl \| sh` for Deno | `setup.sh` | Low–moderate |
| 2 | Unverified yt-dlp binary download | `setup.sh` | Low |
| 3 | Predictable `/tmp` filenames | `setup.sh` | Low (single-user VM) |
| 4 | `allow_other` on shared mount | `setup.sh` | Low (single-user VM) |
| 5 | No `-DataRoot` path validation | `run_ytdlp.ps1` | Informational only |

## What implementing these fixes would actually involve

None of these require redesigning anything — they're all localized changes
to `setup.sh`, each independent of the others. Roughly, in order of effort:

**#2 (yt-dlp checksum verification) — smallest change.** yt-dlp publishes a
`SHA2-256SUMS` file alongside every GitHub release. This means one extra
`curl` to fetch that file, and one `sha256sum -c` (or equivalent `grep` +
compare) right after downloading the binary, before `chmod`ing it
executable. A few lines, no new dependencies, nothing to maintain going
forward — the checksums file updates itself with every yt-dlp release.

**#1 (Deno checksum verification) — similar shape, slightly more upkeep.**
Deno publishes checksums per release too, but pinning to a specific
version number (rather than always grabbing "latest") means `setup.sh`
would need that version bumped occasionally by hand, or a small extra step
to query Deno's GitHub API for the latest tag first. A bit more code than
#2, and it trades some of the "just works, always current" convenience of
`curl | sh` for the verification guarantee.

**#3 (predictable `/tmp` filenames) — mechanical, no design decisions.**
Swap each fixed path (`/tmp/packages-microsoft-prod.deb`,
`/tmp/deno-install.log`, `/tmp/vmhgfs-mount.log`) for one generated by
`mktemp` at the point of use. Purely find-and-replace; no behavior change
on a single-user system, since the risk this closes only exists with
other local users present.

**#4 (`allow_other` on the shared mount) — not really a "fix," a decision.**
There's no code change that removes the exposure while keeping the mount
usable for a non-root user — `allow_other` is what makes that work at all.
The only way to "fix" this is to accept a narrower mount (root-only
access, defeating the point) or restrict it at the VMware host level
(only share folders you're fine with every VM-local account seeing).
Realistically: leave as-is for a single-user VM, revisit only if a second
account ever gets added.

**#5 (`-DataRoot` path validation) — a genuine design question, not a bug
fix.** Adding validation means deciding what's actually disallowed —
blocking paths outside `$HOME` would break the whole point of the
feature (letting you point it at `/mnt/hgfs/...` or an external drive).
A more realistic version would be a denylist of obviously-wrong targets
(`/etc`, `/root`, `/boot`, system paths) rather than a strict allowlist.
Worth doing only if this pipeline ever gets invoked by anything other than
you typing the command yourself.

**Bottom line**: #2 is worth doing regardless — it's cheap and it protects
the one binary that runs on every single invocation. #1 and #3 are easy
but lower-value on a single-user setup. #4 and #5 aren't really "fixes"
so much as tradeoffs to consciously accept or reject. Say the word for any
of these and I'll implement it directly in `setup.sh`.

