# PO token support — design notes

Added 2026-09-03. Introduces `scripts/pot-provider.ps1` and bumps
`CONFIG_VERSION` to 25.

## The finding that motivated this

`config/yt-dlp.conf`'s CONFIG_VERSION 23 note recorded a symptom without the
cause. The cause: yt-dlp's unauthenticated default clients are exactly two —
`android_vr` and `web_safari`. `android_vr` needs no PO token; `web_safari`
needs a GVS one, which the pipeline did not supply.

So excluding `android_vr` did not fall back to a working client. It fell back
to the *only other default*, which was structurally incapable of returning
media formats — hence "Only images are available for download."

The pipeline was therefore effectively **single-client**, and that one client
is the one with the open upstream 403 bug (yt-dlp/yt-dlp#17456). The fallback
list existed but had one usable entry.

## Client ordering, and why

With a working provider, `run_ytdlp.ps1` passes
`youtube:player_client=tv_simply,web_safari,android_vr`.

| Client | Token | Reason for its position |
|---|---|---|
| `tv_simply` | GVS | Good formats, no cookies needed, not subject to `tv`'s "all DRM'd without cookies" problem. Best first choice unauthenticated. |
| `web_safari` | GVS | Uniquely also offers HLS formats that need *no* token, so it can partially work even when token generation is shaky. |
| `android_vr` | none | Last, not removed. Fails *differently* from the other two, which is the point of a fallback. |

Excluded deliberately: `web` (SABR-only, undownloadable), `tv` (DRM without
cookies), `web_creator`/`web_music` (need cookies), `android`/`ios` (no cookie
support *and* token-gated), `web_embedded` (too narrow).

The order lives in `$script:PotHealthyClients` in `pot-provider.ps1`, not in
`yt-dlp.conf` — it is a per-run decision that depends on provider health, so a
static config file cannot express it.

## The honest limit

When YouTube changes BotGuard and upstream has not shipped a fix, **nothing
local can produce a token**. There is no self-healing past that point. The
implemented sequence is: health-check → update and re-test → roll back to last
known-good pair → degrade.

## The archive-contamination trap

This is the non-obvious part and the reason the design is more than a flag.

A degraded run downloads real videos at possibly lower quality. If those IDs
reached `archive.txt`, every future healthy run would skip them forever, and
the archive would silently hold the worse copy with no record of which entries
were affected.

Fix: a degraded session lets yt-dlp **read** the real archive (so completed
videos are still skipped) while **writing** to a scratch copy. The diff is
appended to `Archive Logs/Logs/needs-refetch.txt` — an append-only ledger of
refetch debt. Files on disk are deliberately left in place; deleting them would
mean an outage produces nothing at all.

Cost: degraded videos are downloaded twice. That trade is intentional —
duplicate bandwidth is recoverable, a silently degraded archive entry is not.

## Decisions taken (user-confirmed)

- Degraded runs download but do **not** record to the archive.
- Node installed **natively** (tarball into the install root), not Docker —
  Docker Desktop on Windows/macOS is a heavier dependency than this project has
  anywhere else.
- Update policy: update provider and yt-dlp together, verify, roll back to the
  last known-good pair on failure.

## Unverified assumption

`Test-PotToken` POSTs to the provider's `/get_pot` endpoint. That request shape
is upstream's own API and could not be verified from the authoring environment
(GitHub was unreachable there). The function is written defensively — an
HTTP 400/404/422 is reported as `Unknown` and treated as usable, so an API
change does **not** drop the pipeline into degraded mode. Confirm on a real
machine with `pwsh -File scripts/pot-provider.ps1 -SelfTest`.

## Not verified locally

No PowerShell parse check was run when this landed — the authoring environment
had no `pwsh` and could not reach Microsoft's package hosts. Run
`tests/run-tests` (suite 010 now includes `pot-provider.ps1`) before trusting it.