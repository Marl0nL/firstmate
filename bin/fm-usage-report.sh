#!/usr/bin/env bash
# Aggregate the token-usage ledger into a self-contained HTML report and open it
# with lavish-axi for review.
#
# Usage:
#   fm-usage-report.sh              build the report and open it in lavish-axi
#   fm-usage-report.sh --no-open    build the HTML only; print its path
#   fm-usage-report.sh --out <path> write the HTML to <path>
#
# The report shows: headline 5-hour and weekly quota tiles + today's weighted
# tokens; weighted consumption per day (stacked by model); breakdowns by project,
# task, harness, and model; and the four token classes split raw and weighted.
# Weights are configurable (fm-usage-lib.sh) and are a RELATIVE ranking heuristic,
# not the subscription's server-side limit accounting - the report labels itself
# "claude-harness usage" because non-claude crews are invisible here (see
# docs/usage-monitor.md).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-usage-lib.sh
. "$SCRIPT_DIR/fm-usage-lib.sh"

OPEN=1
OUT="$FM_USAGE_DIR/report.html"
while [ $# -gt 0 ]; do
  case "$1" in
    --no-open) OPEN=0; shift ;;
    --out) OUT=${2:-$OUT}; shift 2 ;;
    *) shift ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "fm-usage-report: jq is required" >&2; exit 1; }
mkdir -p "$FM_USAGE_DIR" 2>/dev/null || true
mkdir -p "$(dirname "$OUT")" 2>/dev/null || true

if [ ! -s "$FM_USAGE_LEDGER" ]; then
  echo "fm-usage-report: no ledger yet at $FM_USAGE_LEDGER - run fm-usage-poll.sh --backfill first" >&2
  exit 1
fi

TODAY=$(date -u +%Y-%m-%d 2>/dev/null || echo '')
GENERATED=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')

# Freshest quota signal (best-effort; the report still renders without it).
QUOTA='{"source":"none","degraded":true,"windows":{"session":{"percent":0,"severity":"normal","resets_at":""},"weekly":{"percent":0,"severity":"normal","resets_at":""},"scoped":[]}}'
if [ -x "$SCRIPT_DIR/fm-usage-quota.sh" ]; then
  q=$("$SCRIPT_DIR/fm-usage-quota.sh" --signal 2>/dev/null) && [ -n "$q" ] && QUOTA=$q
fi

# One jq pass over the ledger builds every aggregate the renderer needs.
DATA=$(jq -s \
  --arg today "$TODAY" --arg generated "$GENERATED" \
  --argjson wi "$(fm_usage_weight input)" --argjson wo "$(fm_usage_weight output)" \
  --argjson wcc "$(fm_usage_weight cache_creation)" --argjson wcr "$(fm_usage_weight cache_read)" \
  --argjson quota "$QUOTA" '
  def weight(r): (r.input_tokens*$wi) + (r.output_tokens*$wo)
               + (r.cache_creation_input_tokens*$wcc) + (r.cache_read_input_tokens*$wcr);
  def day(r): (r.ts // "")[0:10];
  def agg(field):
    (group_by(.[field]) | map({key:(.[0][field] // "unknown"),
       weighted:(map(weight(.)) | add // 0),
       requests:length}) | sort_by(-.weighted));
  map(. + {w: weight(.)}) as $rows
  | {
    generated_at: $generated,
    weights: {input:$wi, output:$wo, cache_creation:$wcc, cache_read:$wcr},
    quota: $quota,
    totals: {
      requests: ($rows|length),
      input: ($rows|map(.input_tokens)|add // 0),
      output: ($rows|map(.output_tokens)|add // 0),
      cache_creation: ($rows|map(.cache_creation_input_tokens)|add // 0),
      cache_read: ($rows|map(.cache_read_input_tokens)|add // 0),
      weighted: ($rows|map(.w)|add // 0)
    },
    today_weighted: ($rows | map(select(day(.) == $today) | .w) | add // 0),
    by_project: ($rows | agg("project")),
    by_task: ($rows | agg("task_id") | .[0:20]),
    by_harness: ($rows | agg("harness")),
    by_model: ($rows | agg("model")),
    by_day: (
      $rows | group_by(day(.))
      | map({day:(.[0]|day(.)),
             weighted:(map(.w)|add // 0),
             models:(group_by(.model) | map({key:(.[0].model // "unknown"), weighted:(map(.w)|add // 0)}))})
      | sort_by(.day) | .[-30:]
    )
  }' "$FM_USAGE_LEDGER" 2>/dev/null)

if [ -z "$DATA" ]; then
  echo "fm-usage-report: failed to aggregate the ledger" >&2
  exit 1
fi

# Emit a self-contained HTML page: inline CSS, an embedded data blob, and a small
# vanilla-JS renderer (no external assets, so it opens anywhere).
{
cat <<'HTML_HEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>firstmate token usage</title>
<style>
  :root { color-scheme: light dark; --bg:#0f1115; --card:#171a21; --ink:#e7ebf0; --mut:#9aa4b2; --line:#262b35; --accent:#5b9dff; --warn:#e8a33d; --crit:#e5544b; }
  * { box-sizing: border-box; }
  body { margin:0; padding:24px; background:var(--bg); color:var(--ink); font:15px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif; }
  h1 { font-size:20px; margin:0 0 4px; }
  .sub { color:var(--mut); font-size:13px; margin-bottom:20px; }
  .grid { display:grid; gap:16px; grid-template-columns:repeat(auto-fill,minmax(220px,1fr)); margin-bottom:24px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:16px; min-width:0; }
  .tile .big { font-size:30px; font-weight:650; }
  .tile .lbl { color:var(--mut); font-size:12px; text-transform:uppercase; letter-spacing:.04em; }
  .tile .meta { color:var(--mut); font-size:12px; margin-top:4px; }
  .sev-normal .big { color:var(--ink); } .sev-warning .big { color:var(--warn); } .sev-critical .big { color:var(--crit); }
  section { margin-bottom:28px; }
  section h2 { font-size:15px; margin:0 0 12px; color:var(--mut); text-transform:uppercase; letter-spacing:.04em; }
  table { width:100%; border-collapse:collapse; font-size:14px; }
  th,td { text-align:left; padding:7px 10px; border-bottom:1px solid var(--line); white-space:nowrap; }
  th { color:var(--mut); font-weight:500; font-size:12px; }
  td.num, th.num { text-align:right; font-variant-numeric:tabular-nums; }
  .barwrap { overflow-x:auto; }
  .bar { height:8px; border-radius:4px; background:var(--accent); }
  .barcell { min-width:120px; }
  .barbg { background:var(--line); border-radius:4px; }
  .days { display:flex; gap:3px; align-items:flex-end; height:140px; overflow-x:auto; padding-bottom:4px; }
  .day { flex:0 0 22px; display:flex; flex-direction:column; justify-content:flex-end; height:100%; }
  .daybar { width:100%; background:var(--accent); border-radius:3px 3px 0 0; min-height:1px; }
  .day .dl { font-size:9px; color:var(--mut); text-align:center; margin-top:3px; transform:rotate(0); }
  .tag { display:inline-block; font-size:11px; color:var(--mut); border:1px solid var(--line); border-radius:999px; padding:1px 8px; }
  .foot { color:var(--mut); font-size:12px; margin-top:24px; }
</style>
</head>
<body>
<h1>firstmate token usage</h1>
<div class="sub">claude-harness crews only &middot; weighted cost is a relative ranking heuristic, not the subscription's server-side limit accounting</div>
<div id="app"></div>
<div class="foot" id="foot"></div>
<script id="data" type="application/json">
HTML_HEAD
printf '%s\n' "$DATA"
cat <<'HTML_TAIL'
</script>
<script>
const D = JSON.parse(document.getElementById('data').textContent);
const fmt = n => (n||0).toLocaleString('en-US');
const kfmt = n => { n=n||0; if(n>=1e9)return (n/1e9).toFixed(1)+'B'; if(n>=1e6)return (n/1e6).toFixed(1)+'M'; if(n>=1e3)return (n/1e3).toFixed(1)+'k'; return ''+Math.round(n); };
const esc = s => String(s==null?'':s).replace(/[&<>]/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
const sev = w => (w && w.severity) ? w.severity : 'normal';
function tile(lbl, big, meta, s){ return `<div class="card tile sev-${s||'normal'}"><div class="lbl">${lbl}</div><div class="big">${big}</div><div class="meta">${meta||''}</div></div>`; }
function barTable(title, rows, total){
  if(!rows||!rows.length) return '';
  const max = Math.max(1, ...rows.map(r=>r.weighted));
  const body = rows.map(r=>{
    const pct = Math.round(100*r.weighted/max);
    const share = total? (100*r.weighted/total).toFixed(1)+'%' : '';
    return `<tr><td>${esc(r.key)}</td><td class="num">${fmt(r.requests)}</td><td class="num">${kfmt(r.weighted)}</td>`
      + `<td class="barcell"><div class="barbg"><div class="bar" style="width:${pct}%"></div></div></td>`
      + `<td class="num">${share}</td></tr>`;
  }).join('');
  return `<section><h2>${title}</h2><div class="barwrap"><table>`
    + `<thead><tr><th>${title.replace(/^By /,'')}</th><th class="num">reqs</th><th class="num">weighted</th><th>share</th><th class="num"></th></tr></thead>`
    + `<tbody>${body}</tbody></table></div></section>`;
}
function daysChart(days){
  if(!days||!days.length) return '';
  const max = Math.max(1, ...days.map(d=>d.weighted));
  const cols = days.map(d=>{
    const h = Math.round(100*d.weighted/max);
    return `<div class="day" title="${esc(d.day)}: ${kfmt(d.weighted)} weighted"><div class="daybar" style="height:${h}%"></div><div class="dl">${esc(d.day.slice(5))}</div></div>`;
  }).join('');
  return `<section><h2>Weighted consumption per day (last ${days.length})</h2><div class="days">${cols}</div></section>`;
}
const q = D.quota||{windows:{}}, s5 = (q.windows&&q.windows.session)||{}, sw=(q.windows&&q.windows.weekly)||{};
const est = q.degraded ? ' <span class="tag">estimated</span>' : '';
let tiles = tile('5-hour window', (s5.percent||0)+'%', (s5.resets_at?('resets '+esc(s5.resets_at)):'')+est, sev(s5));
tiles += tile('Weekly window', (sw.percent||0)+'%', (sw.resets_at?('resets '+esc(sw.resets_at)):'')+est, sev(sw));
tiles += tile('Today (weighted)', kfmt(D.today_weighted), fmt(D.totals.requests)+' requests all-time', 'normal');
tiles += tile('Total weighted', kfmt(D.totals.weighted), 'lifetime ledger', 'normal');
const scoped = (q.windows&&q.windows.scoped||[]).filter(x=>x.is_active);
if(scoped.length) tiles += scoped.map(x=>tile('Cap: '+esc(x.model), (x.percent||0)+'%', x.resets_at?('resets '+esc(x.resets_at)):'', sev(x))).join('');
const t = D.totals, w = D.weights;
const classRows = [
  {key:'output', raw:t.output, weighted:t.output*w.output},
  {key:'cache_creation', raw:t.cache_creation, weighted:t.cache_creation*w.cache_creation},
  {key:'input', raw:t.input, weighted:t.input*w.input},
  {key:'cache_read', raw:t.cache_read, weighted:t.cache_read*w.cache_read},
].sort((a,b)=>b.weighted-a.weighted);
const maxc = Math.max(1, ...classRows.map(r=>r.weighted));
const classBody = classRows.map(r=>`<tr><td>${r.key} <span class="tag">&times;${w[r.key]}</span></td><td class="num">${fmt(r.raw)}</td><td class="num">${kfmt(r.weighted)}</td>`
  +`<td class="barcell"><div class="barbg"><div class="bar" style="width:${Math.round(100*r.weighted/maxc)}%"></div></div></td></tr>`).join('');
let html = `<div class="grid">${tiles}</div>`;
html += daysChart(D.by_day);
html += `<section><h2>Token-class split (raw vs weighted)</h2><div class="barwrap"><table><thead><tr><th>class</th><th class="num">raw tokens</th><th class="num">weighted</th><th class="num"></th></tr></thead><tbody>${classBody}</tbody></table></div></section>`;
html += barTable('By task', D.by_task, t.weighted);
html += barTable('By project', D.by_project, t.weighted);
html += barTable('By model', D.by_model, t.weighted);
html += barTable('By harness', D.by_harness, t.weighted);
document.getElementById('app').innerHTML = html;
document.getElementById('foot').textContent = 'generated ' + (D.generated_at||'') + ' · quota source: ' + (q.source||'none');
</script>
</body>
</html>
HTML_TAIL
} > "$OUT"

echo "fm-usage-report: wrote $OUT"

if [ "$OPEN" -eq 1 ]; then
  if command -v lavish-axi >/dev/null 2>&1; then
    lavish-axi "$OUT"
  else
    echo "fm-usage-report: lavish-axi not found; open $OUT manually" >&2
  fi
fi
exit 0
