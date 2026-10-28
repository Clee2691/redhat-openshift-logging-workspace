#!/usr/bin/env python3
"""Summarize one variant's artifacts: loss/latency + collector CPU/mem/events.

Usage: summarize.py <artifact-dir> [--test-node ip-10-0-1-201]
Prints a one-line human summary and writes summary.json in the dir.
"""
import json
import sys
import glob
import os

d = sys.argv[1]
test_node = "ip-10-0-57-45"
for i, a in enumerate(sys.argv):
    if a == "--test-node":
        test_node = sys.argv[i + 1]


def load(name):
    p = os.path.join(d, f"prom_{name}.json")
    try:
        return json.load(open(p))["data"]["result"]
    except Exception:
        return []


def series_sum(res, node_filter=False):
    """Sum values across series at each timestamp; optional node filter."""
    by_ts = {}
    for r in res:
        m = r["metric"]
        node = m.get("hostname") or m.get("node") or ""
        if node_filter and test_node not in node:
            continue
        for ts, v in r["values"]:
            if v in ("NaN", None):
                continue
            by_ts.setdefault(ts, []).append(float(v))
    sums = [sum(v) for v in by_ts.values()]
    ts = sorted(by_ts)
    return [(t, s) for t, s in zip(ts, sums)]


def stats(vals):
    if not vals:
        return None
    return {"avg": round(sum(vals) / len(vals), 3), "max": round(max(vals), 3)}


# cpu/mem: per-pod series; select test-node collector by hostname/node label
def node_of(r):
    m = r["metric"]
    return m.get("hostname") or m.get("node") or ""


cpu = load("cpu")
cpu_series = [r for r in cpu if test_node in node_of(r)]
cpu_vals = [float(v[1]) for r in cpu_series for v in r["values"] if v[1] != "NaN"]
mem = load("mem")
mem_series = [r for r in mem if test_node in node_of(r)]
mem_vals = [float(v[1]) for r in mem_series for v in r["values"] if v[1] != "NaN"]

# events/bytes/files: sum across all series (all on test-node collector anyway)
ev = series_sum(load("events_in"))
by = series_sum(load("bytes_in"))
fa = series_sum(load("files_added"))

report = json.load(open(os.path.join(d, "report.json")))

summary = {
    "variant": os.path.basename(d.rstrip("/")),
    "loss": {
        "streams": report["streams"],
        "collected": report["total_collected"],
        "missing": report["total_missing"],
        "duplicates": report["total_duplicates"],
        "loss_percent": report["loss_percent"],
        "unparsed_lines": report["unparsed_lines"],
    },
    "latency_s": report["latency"],
    "cpu_cores_test_node": stats(cpu_vals),
    "mem_bytes_test_node": stats(mem_vals),
    "events_in_per_sec_summed": stats([v for _, v in ev]),
    "bytes_in_per_sec_summed": stats([v for _, v in by]),
    "files_added_6m_summed": stats([v for _, v in fa]),
}
json.dump(summary, open(os.path.join(d, "summary.json"), "w"), indent=2)

l = summary["loss"]
lat = summary["latency_s"]
c = summary["cpu_cores_test_node"] or {}
m = summary["mem_bytes_test_node"] or {}
e = summary["events_in_per_sec_summed"] or {}
print(
    f"{summary['variant']:16s} loss={l['loss_percent']:7.3f}% miss={l['missing']:6d} dup={l['duplicates']:4d} "
    f"collected={l['collected']:8d} | lat p50={lat['p50_s']}s p95={lat['p95_s']}s p99={lat['p99_s']}s max={lat['max_s']}s | "
    f"cpu avg={c.get('avg')} max={c.get('max')} | mem avg={round((m.get('avg') or 0)/1e6)}MB max={round((m.get('max') or 0)/1e6)}MB | "
    f"ev/s avg={e.get('avg')} max={e.get('max')}"
)
