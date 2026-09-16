#!/usr/bin/env python3
"""
report.py — render one benchmark result as a standalone HTML page.

    scripts/report.py benchmark/results/current-mtls-put-6000rps.json
    scripts/report.py --all                     # every *.json in benchmark/results/
    scripts/report.py --all --out-dir reports

One page per execution, written to reports/<label>.html. There is deliberately
no index page and no server: the directory listing is the index, and each file
opens straight from the filesystem.

Self-contained by design -- inline CSS, no JavaScript, no external requests, no
fonts or CDN. A report can be emailed or attached to a ticket and will render
identically offline.

WHY NOT GRAFANA/PROMETHEUS
    A metrics stack would have to run alongside the load generator on a single
    host, competing for the CPU it is supposed to be measuring. A static page
    generated after the fact costs nothing at measurement time.

Two result shapes are understood:
  * the Go client's JSON  (mode=connect|tls|dns|dnstest) — throughput, latency,
    status codes, error counters
  * hold-tunnels.py's JSON — tunnel establishment and survival
Anything unrecognised still renders, with its raw keys listed, rather than
being silently skipped.

SPDX-License-Identifier: none (POC code)
"""

import argparse
import glob
import html
import json
import os
import sys
from datetime import datetime, timezone

CSS = """
:root{--bg:#fbfbfa;--fg:#1b1b19;--muted:#6b6b66;--line:#dcdcd6;--card:#fff;
--ok:#1a7f37;--warn:#9a6700;--bad:#b42318;--accent:#0b5fff}
@media (prefers-color-scheme:dark){:root{--bg:#16161a;--fg:#ececec;--muted:#a0a0a8;
--line:#2e2e35;--card:#1e1e23;--ok:#4ac26b;--warn:#d4a72c;--bad:#ff7b72;--accent:#6ea8ff}}
*{box-sizing:border-box}
body{margin:0;padding:32px 24px 64px;background:var(--bg);color:var(--fg);
font:15px/1.55 ui-sans-serif,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
main{max-width:900px;margin:0 auto}
h1{font-size:24px;margin:0 0 4px;letter-spacing:-.01em}
h2{font-size:15px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);
margin:34px 0 10px;font-weight:600}
.sub{color:var(--muted);margin:0 0 24px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:18px 20px;margin:0 0 16px}
table{border-collapse:collapse;width:100%;font-size:14px}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line)}
th{color:var(--muted);font-weight:600}
td.num{text-align:right;font-variant-numeric:tabular-nums}
tr:last-child td{border-bottom:none}
.kpis{display:flex;flex-wrap:wrap;gap:14px}
.kpi{flex:1 1 150px;background:var(--card);border:1px solid var(--line);
border-radius:10px;padding:14px 16px}
.kpi .v{font-size:22px;font-weight:650;font-variant-numeric:tabular-nums;letter-spacing:-.02em}
.kpi .k{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;margin-top:4px}
.ok{color:var(--ok)}.bad{color:var(--bad)}.warn{color:var(--warn)}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:13px}
ul{margin:6px 0 0;padding-left:20px}li{margin:3px 0}
footer{margin-top:40px;color:var(--muted);font-size:12px;border-top:1px solid var(--line);padding-top:12px}
"""


def esc(v):
    return html.escape(str(v))


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def fmt(v):
    if is_num(v):
        if float(v).is_integer() and abs(v) < 1e15:
            return f"{int(v):,}"
        return f"{v:,.2f}".rstrip("0").rstrip(".")
    return esc(v)


def kpi(label, value, cls=""):
    return (f'<div class="kpi"><div class="v {cls}">{esc(value)}</div>'
            f'<div class="k">{esc(label)}</div></div>')


def table(rows, headers):
    if not rows:
        return ""
    out = ["<table><thead><tr>"]
    out += [f"<th>{esc(h)}</th>" for h in headers]
    out += ["</tr></thead><tbody>"]
    for r in rows:
        out.append("<tr>")
        for i, c in enumerate(r):
            cls = ' class="num"' if (i > 0 and is_num(c)) else ""
            out.append(f"<td{cls}>{fmt(c)}</td>")
        out.append("</tr>")
    out.append("</tbody></table>")
    return "".join(out)


def render_client(d):
    """The Go client's result JSON."""
    p = []
    lat = d.get("latency_ms") or {}
    errs = {k: d.get(k, 0) for k in
            ("connect_error", "tls_error", "http_error", "timeout",
             "mtls_rejected", "connect_rejected") if k in d}
    total_err = sum(v for v in errs.values() if is_num(v))

    p.append('<div class="kpis">')
    if "achieved_rps" in d:
        p.append(kpi("throughput", f"{d['achieved_rps']:,.0f} rps"))
    if "achieved_qps" in d:
        p.append(kpi("query rate", f"{d['achieved_qps']:,.0f} qps"))
    if "success" in d:
        cls = "ok" if total_err == 0 else "warn"
        p.append(kpi("successful", f"{d['success']:,}", cls))
    if lat.get("p50") is not None:
        p.append(kpi("p50 latency", f"{lat['p50']:,.2f} ms"))
    if lat.get("p99") is not None:
        p.append(kpi("p99 latency", f"{lat['p99']:,.2f} ms"))
    p.append("</div>")

    if lat:
        rows = [[k, lat.get(k)] for k in
                ("p50", "p90", "p95", "p99", "max", "mean") if k in lat]
        p.append("<h2>Latency (ms)</h2>" + table(rows, ["percentile", "ms"]))

    if errs:
        rows = [[k.replace("_", " "), v] for k, v in errs.items()]
        p.append("<h2>Outcome counters</h2>" + table(rows, ["counter", "count"]))

    codes = d.get("connect_status_codes") or d.get("http_status_codes")
    if isinstance(codes, dict) and codes:
        rows = [[k, v] for k, v in sorted(codes.items())]
        p.append("<h2>Status codes</h2>" + table(rows, ["code", "responses"]))

    if d.get("tunnels_opened") is not None:
        p.append("<h2>Tunnels</h2>" + table(
            [["opened", d["tunnels_opened"]],
             ["persistent", d.get("persistent", "n/a")],
             ["requests per tunnel", d.get("requests_per_tunnel", "n/a")]],
            ["metric", "value"]))

    if d.get("notes"):
        p.append("<h2>Method notes</h2><ul>")
        p += [f"<li>{esc(n)}</li>" for n in d["notes"]]
        p.append("</ul>")
    if d.get("errors_sample"):
        p.append('<h2>Error sample</h2><div class="card mono"><ul>')
        p += [f"<li>{esc(e)}</li>" for e in d["errors_sample"][:10]]
        p.append("</ul></div>")
    return "".join(p)


def render_hold(d):
    """hold-tunnels.py's result JSON."""
    p = ['<div class="kpis">']
    p.append(kpi("requested", f"{d.get('requested', 0):,}"))
    est = d.get("established", 0)
    req = d.get("requested") or 1
    p.append(kpi("established", f"{est:,}",
                 "ok" if est == req else "bad"))
    p.append(kpi("min alive in hold", f"{d.get('min_alive_during_hold', 0):,}",
                 "ok" if d.get("min_alive_during_hold") == est else "warn"))
    p.append(kpi("setup time", f"{d.get('setup_seconds', 0):,.1f} s"))
    p.append("</div>")

    for key, title in (("failures", "Setup failures"),
                       ("primed_failures", "Prime failures")):
        f = d.get(key) or {}
        if f:
            p.append(f"<h2>{esc(title)}</h2>" + table(
                [[k, v] for k, v in f.items()], ["error", "count"]))

    s = d.get("survival_samples") or []
    if s:
        p.append("<h2>Tunnel survival during hold</h2>" + table(
            [[x.get("t"), x.get("alive")] for x in s], ["t (s)", "alive"]))
    return "".join(p)


def render(d, path):
    label = d.get("label") or os.path.splitext(os.path.basename(path))[0]

    meta = []
    for k in ("mode", "proxy", "target_host", "servername", "arch", "start_time",
              "duration_seconds", "hold_seconds", "concurrency", "target_rps",
              "label"):
        if d.get(k) not in (None, ""):
            meta.append((k.replace("_", " "), d[k]))

    body = render_hold(d) if "established" in d and "survival_samples" in d \
        else render_client(d)

    unknown = [k for k in d if k not in {
        "label", "mode", "proxy", "target_host", "servername", "arch",
        "start_time", "duration_seconds", "hold_seconds", "concurrency",
        "target_rps", "achieved_rps", "achieved_qps", "success", "attempts",
        "latency_ms", "connect_error", "tls_error", "http_error", "timeout",
        "mtls_rejected", "connect_rejected", "connect_status_codes",
        "http_status_codes", "tunnels_opened", "persistent",
        "requests_per_tunnel", "notes", "errors_sample", "requested",
        "established", "min_alive_during_hold", "setup_seconds", "failures",
        "primed_failures", "survival_samples", "primed", "outcomes_sample",
        "identity_checked", "identity_mismatch", "zone", "path", "method",
        "body_bytes", "random_host", "host_count", "warmup_seconds",
        "latency_samples", "latency_scope", "measured_seconds", "bytes_sent",
        "bytes_received", "handshakes_completed", "client_cert",
        "insecure_skip_verify", "timeout_seconds", "tls_version",
        "answers_sample", "proto", "server", "sent", "received", "net_err",
        "truncated", "rcodes", "queries", "source_file",
    }]
    extra = ""
    if unknown:
        extra = ("<h2>Other reported fields</h2>" + table(
            [[k, d[k]] for k in sorted(unknown)], ["field", "value"]))

    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{esc(label)}</title><style>{CSS}</style></head>
<body><main>
<h1>{esc(label)}</h1>
<p class="sub">benchmark result &middot; rendered {datetime.now(timezone.utc):%Y-%m-%d %H:%M} UTC</p>
{body}
<h2>Run parameters</h2>
{table(meta, ["parameter", "value"])}
{extra}
<footer>Generated by <span class="mono">scripts/report.py</span> from
<span class="mono">{esc(path)}</span>. Rendered from the raw result file; no value
on this page is recomputed or estimated.</footer>
</main></body></html>"""


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("files", nargs="*", help="result JSON file(s)")
    ap.add_argument("--all", action="store_true",
                    help="render every benchmark/results/*.json")
    ap.add_argument("--results-dir", default="benchmark/results")
    ap.add_argument("--out-dir", default="reports")
    a = ap.parse_args()

    files = list(a.files)
    if a.all:
        files += sorted(glob.glob(os.path.join(a.results_dir, "*.json")))
    if not files:
        ap.error("give one or more result files, or --all")

    os.makedirs(a.out_dir, exist_ok=True)
    written, skipped = 0, 0
    for f in files:
        try:
            with open(f, encoding="utf-8") as fh:
                d = json.load(fh)
        except Exception as e:
            print(f"  SKIP {f}: {type(e).__name__}: {e}", file=sys.stderr)
            skipped += 1
            continue
        if not isinstance(d, dict):
            print(f"  SKIP {f}: not a JSON object", file=sys.stderr)
            skipped += 1
            continue
        label = d.get("label") or os.path.splitext(os.path.basename(f))[0]
        out = os.path.join(a.out_dir, f"{label}.html")
        with open(out, "w", encoding="utf-8") as fh:
            fh.write(render(d, f))
        print(f"  {out}")
        written += 1

    print(f"\n  {written} report(s) written to {a.out_dir}/"
          + (f", {skipped} skipped" if skipped else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
