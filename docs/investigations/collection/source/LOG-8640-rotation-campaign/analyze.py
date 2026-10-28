#!/usr/bin/env python3
"""Analyze compact receiver output for loss, duplication, and latency.

Receiver emits one JSON line per goloader event:
    {"file":"<ns>_<pod>_<container>","seqid":N,"ts_ms":<in ms>,"out_ms":<out ms>}

Usage: analyze.py FILE [FILE...] > report.json
"""
import json
import sys
import statistics

def parse_event(line):
    try:
        ev = json.loads(line)
        if int(ev["seqid"]) < 0:
            return None  # receiver-side unparsed marker
        return {
            "file": ev["file"],
            "seqid": int(ev["seqid"]),
            "ts_ms": int(ev["ts_ms"]),
            "out_ms": int(ev["out_ms"]),
        }
    except (json.JSONDecodeError, KeyError, TypeError, ValueError):
        return None


def main():
    streams = {}
    unparsed = 0
    for path in sys.argv[1:]:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                ev = parse_event(line)
                if ev is None:
                    unparsed += 1
                    continue
                streams.setdefault(ev["file"], []).append(ev)

    total_expected = 0
    total_collected = 0
    total_dups = 0
    total_missing = 0
    per_stream = []
    latencies_ms = []
    for fname, events in sorted(streams.items()):
        seqids = [e["seqid"] for e in events]
        dups = len(seqids) - len(set(seqids))
        min_s, max_s = min(seqids), max(seqids)
        got = set(seqids)
        missing = [s for s in range(min_s, max_s + 1) if s not in got]
        expected = (max_s - min_s + 1) if max_s > min_s else len(got)
        total_expected += expected
        total_collected += len(got)
        total_dups += dups
        total_missing += len(missing)
        for e in events:
            latencies_ms.append(e["out_ms"] - e["ts_ms"])
        per_stream.append({
            "file": fname,
            "collected": len(got),
            "duplicates": dups,
            "seqid_range": [min_s, max_s],
            "missing_count": len(missing),
            "first_missing": missing[:10],
        })

    lat_sorted = sorted(latencies_ms)

    def pct(p):
        return round(lat_sorted[int(len(lat_sorted) * p)] / 1000.0, 3) if lat_sorted else None

    report = {
        "streams": len(streams),
        "total_collected": total_collected,
        "total_expected_window": total_expected,
        "total_missing": total_missing,
        "total_duplicates": total_dups,
        "unparsed_lines": unparsed,
        "loss_percent": round(100.0 * total_missing / total_expected, 4) if total_expected else 0.0,
        "latency": {
            "count": len(latencies_ms),
            "mean_s": round(statistics.mean(latencies_ms) / 1000.0, 3) if latencies_ms else None,
            "p50_s": pct(0.50),
            "p95_s": pct(0.95),
            "p99_s": pct(0.99),
            "max_s": round(lat_sorted[-1] / 1000.0, 3) if lat_sorted else None,
        },
        "per_stream": per_stream,
    }
    json.dump(report, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
