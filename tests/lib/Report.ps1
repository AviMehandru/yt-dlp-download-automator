<#
.SYNOPSIS
    Writes the self-contained HTML results page for a test run.

.DESCRIPTION
    One file, no assets, no CDN, no JavaScript framework -- it has to open
    from a file:// URL inside a VM with no network, which is exactly where
    this suite gets run. The only script in the page is a few lines to
    filter the list and expand a row.

    The report exists because the console output scrolls. A run covering
    four platforms produces a few hundred lines, and the useful part of a
    failure -- the assertion's expected/actual pair plus whatever the script
    under test printed while failing -- is the part most likely to have
    scrolled away by the time the run ends.
#>

Set-StrictMode -Version Latest

function ConvertTo-HtmlText {
    param([Parameter(Position = 0)]$Text)
    if ($null -eq $Text) { return '' }
    return ([string]$Text).
        Replace('&', '&amp;').
        Replace('<', '&lt;').
        Replace('>', '&gt;').
        Replace('"', '&quot;')
}

function Write-HtmlReport {
    param(
        [Parameter(Mandatory = $true)]$Results,
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Environment = @{},
        [double]$TotalSeconds = 0
    )

    $all    = @($Results)
    $passed = @($all | Where-Object { $_.Status -eq 'Pass' }).Count
    $failed = @($all | Where-Object { $_.Status -eq 'Fail' }).Count
    $skipped= @($all | Where-Object { $_.Status -eq 'Skip' }).Count
    $verdict = if ($failed -gt 0) { 'FAILED' } else { 'PASSED' }
    $verdictClass = if ($failed -gt 0) { 'bad' } else { 'good' }

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine('<!doctype html><html lang="en"><head><meta charset="utf-8">')
    $null = $sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    $null = $sb.AppendLine('<title>yt-dlp pipeline test results</title>')
    $null = $sb.AppendLine(@'
<style>
:root{--bg:#fbfaf9;--fg:#1c1a19;--muted:#6b6560;--card:#fff;--line:#e5e1dd;
      --good:#1c7a4a;--bad:#b3261e;--skip:#8a6d1f;--codebg:#f4f1ee;}
@media (prefers-color-scheme:dark){:root{--bg:#181614;--fg:#eceae8;--muted:#9c948c;
      --card:#221f1d;--line:#35302c;--good:#4ec27f;--bad:#f2857c;--skip:#d9b656;--codebg:#141211;}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
     font:14px/1.55 ui-sans-serif,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
.wrap{max-width:1080px;margin:0 auto;padding:28px 20px 72px}
h1{font-size:22px;margin:0 0 4px;letter-spacing:-.01em}
.sub{color:var(--muted);margin:0 0 22px;font-size:13px}
.verdict{display:inline-block;padding:3px 10px;border-radius:5px;font-weight:650;
         font-size:12px;letter-spacing:.06em}
.verdict.good{background:color-mix(in srgb,var(--good) 16%,transparent);color:var(--good)}
.verdict.bad{background:color-mix(in srgb,var(--bad) 16%,transparent);color:var(--bad)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:10px;margin:0 0 22px}
.tile{background:var(--card);border:1px solid var(--line);border-radius:9px;padding:12px 14px}
.tile b{display:block;font-size:24px;font-weight:640;letter-spacing:-.02em;line-height:1.2}
.tile span{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.07em}
.tile.p b{color:var(--good)}.tile.f b{color:var(--bad)}.tile.s b{color:var(--skip)}
table.env{width:100%;border-collapse:collapse;background:var(--card);
          border:1px solid var(--line);border-radius:9px;overflow:hidden;margin:0 0 26px}
table.env td{padding:7px 14px;border-bottom:1px solid var(--line);vertical-align:top}
table.env tr:last-child td{border-bottom:0}
table.env td:first-child{color:var(--muted);width:190px;white-space:nowrap}
.controls{margin:0 0 14px;display:flex;gap:8px;flex-wrap:wrap;align-items:center}
button{font:inherit;background:var(--card);color:var(--fg);border:1px solid var(--line);
       border-radius:7px;padding:5px 12px;cursor:pointer}
button:hover{border-color:var(--muted)}
button[aria-pressed=true]{background:var(--fg);color:var(--bg);border-color:var(--fg)}
h2{font-size:15px;margin:26px 0 8px;font-weight:640}
.suite{background:var(--card);border:1px solid var(--line);border-radius:9px;overflow:hidden}
.row{border-bottom:1px solid var(--line)}
.row:last-child{border-bottom:0}
.row>summary{padding:9px 14px;cursor:pointer;display:flex;gap:11px;align-items:baseline;
             list-style:none}
.row>summary::-webkit-details-marker{display:none}
.row[data-s=Pass]>summary{cursor:default}
.tag{font-size:10px;font-weight:700;letter-spacing:.07em;padding:2px 6px;border-radius:4px;
     flex:0 0 auto;min-width:42px;text-align:center}
.tag.Pass{background:color-mix(in srgb,var(--good) 15%,transparent);color:var(--good)}
.tag.Fail{background:color-mix(in srgb,var(--bad) 15%,transparent);color:var(--bad)}
.tag.Skip{background:color-mix(in srgb,var(--skip) 18%,transparent);color:var(--skip)}
.nm{flex:1 1 auto}
.ms{color:var(--muted);font-size:11px;flex:0 0 auto;font-variant-numeric:tabular-nums}
.detail{padding:2px 14px 14px 68px}
.detail h4{margin:10px 0 5px;font-size:11px;color:var(--muted);
           text-transform:uppercase;letter-spacing:.07em;font-weight:640}
pre{background:var(--codebg);border:1px solid var(--line);border-radius:7px;
    padding:10px 12px;margin:0;overflow-x:auto;font:12px/1.5 ui-monospace,SFMono-Regular,
    "SF Mono",Menlo,Consolas,monospace;white-space:pre-wrap;word-break:break-word}
.hidden{display:none!important}
footer{margin-top:34px;color:var(--muted);font-size:12px}
</style>
'@)
    $null = $sb.AppendLine('</head><body><div class="wrap">')
    $null = $sb.AppendLine('<h1>yt-dlp pipeline test results</h1>')
    $null = $sb.AppendLine(('<p class="sub"><span class="verdict {0}">{1}</span> &nbsp;{2} test(s) in {3:N1}s &middot; {4}</p>' -f `
        $verdictClass, $verdict, $all.Count, $TotalSeconds, (ConvertTo-HtmlText (Get-Date).ToString('yyyy-MM-dd HH:mm:ss K'))))

    $null = $sb.AppendLine('<div class="tiles">')
    $null = $sb.AppendLine(('<div class="tile p"><b>{0}</b><span>passed</span></div>' -f $passed))
    $null = $sb.AppendLine(('<div class="tile f"><b>{0}</b><span>failed</span></div>' -f $failed))
    $null = $sb.AppendLine(('<div class="tile s"><b>{0}</b><span>skipped</span></div>' -f $skipped))
    $null = $sb.AppendLine('</div>')

    if ($Environment.Count -gt 0) {
        $null = $sb.AppendLine('<table class="env">')
        foreach ($k in $Environment.Keys) {
            $null = $sb.AppendLine(('<tr><td>{0}</td><td>{1}</td></tr>' -f `
                (ConvertTo-HtmlText $k), (ConvertTo-HtmlText $Environment[$k])))
        }
        $null = $sb.AppendLine('</table>')
    }

    $null = $sb.AppendLine(@'
<div class="controls">
  <button id="b-all"  aria-pressed="true"  onclick="flt('all',this)">All</button>
  <button id="b-fail" aria-pressed="false" onclick="flt('Fail',this)">Failures only</button>
  <button id="b-skip" aria-pressed="false" onclick="flt('Skip',this)">Skipped only</button>
  <button onclick="document.querySelectorAll('details.row').forEach(d=>d.open=true)">Expand all</button>
  <button onclick="document.querySelectorAll('details.row').forEach(d=>d.open=false)">Collapse all</button>
</div>
'@)

    foreach ($group in ($all | Group-Object Suite)) {
        $gFail = @($group.Group | Where-Object { $_.Status -eq 'Fail' }).Count
        $label = '{0} <span class="ms">{1} test(s){2}</span>' -f `
                 (ConvertTo-HtmlText $group.Name), $group.Count, `
                 $(if ($gFail -gt 0) { ", $gFail failed" } else { '' })
        $null = $sb.AppendLine(('<h2>{0}</h2>' -f $label))
        $null = $sb.AppendLine('<div class="suite">')
        foreach ($r in $group.Group) {
            $open = if ($r.Status -eq 'Fail') { ' open' } else { '' }
            $null = $sb.AppendLine(('<details class="row" data-s="{0}"{1}><summary><span class="tag {0}">{0}</span><span class="nm">{2}</span><span class="ms">{3} ms</span></summary>' -f `
                $r.Status, $open, (ConvertTo-HtmlText $r.Name), $r.DurationMs))
            $null = $sb.AppendLine('<div class="detail">')
            if ($r.Message) {
                $null = $sb.AppendLine(('<h4>{0}</h4><pre>{1}</pre>' -f `
                    $(if ($r.Status -eq 'Skip') { 'Reason' } else { 'Failure' }), (ConvertTo-HtmlText $r.Message)))
            }
            if ($r.Detail) {
                $null = $sb.AppendLine(('<h4>Stack</h4><pre>{0}</pre>' -f (ConvertTo-HtmlText $r.Detail)))
            }
            if (@($r.Output).Count -gt 0) {
                $null = $sb.AppendLine(('<h4>Captured output</h4><pre>{0}</pre>' -f `
                    (ConvertTo-HtmlText ((@($r.Output) -join "`n")))))
            }
            if (-not $r.Message -and -not $r.Detail -and @($r.Output).Count -eq 0) {
                $null = $sb.AppendLine('<p class="ms">No output captured.</p>')
            }
            $null = $sb.AppendLine('</div></details>')
        }
        $null = $sb.AppendLine('</div>')
    }

    $null = $sb.AppendLine(@'
<footer>Generated by tests/run-tests.ps1. Re-run with -Suite or -Filter to narrow, -ShowOutput for live console output, -Live to include the real-download suite.</footer>
</div>
<script>
function flt(mode,btn){
  document.querySelectorAll('.controls button[aria-pressed]').forEach(b=>b.setAttribute('aria-pressed','false'));
  if(btn) btn.setAttribute('aria-pressed','true');
  document.querySelectorAll('details.row').forEach(function(d){
    var show = (mode==='all') || (d.dataset.s===mode);
    d.classList.toggle('hidden', !show);
    if(show && mode!=='all') d.open = true;
  });
  document.querySelectorAll('h2').forEach(function(h){
    var box = h.nextElementSibling;
    var any = box && box.querySelector('details.row:not(.hidden)');
    h.classList.toggle('hidden', !any);
    if(box) box.classList.toggle('hidden', !any);
  });
}
</script>
</body></html>
'@)

    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}
