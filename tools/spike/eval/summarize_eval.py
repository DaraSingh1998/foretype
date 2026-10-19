#!/usr/bin/env python3
"""results/eval/eval-*.json -> Markdown table. Usage: python3 -I summarize_eval.py DIR"""
import glob
import json
import os
import sys

d = sys.argv[1] if len(sys.argv) > 1 else "."
rows = ["| Model | Preset (words) | Keystrokes saved | Chars per accept (net of Tab) | Acceptance rate | Requests | Suggestion latency p50 / p90 | TTFT p50 / p90 | Tokens per accepted char |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
for p in sorted(glob.glob(os.path.join(d, "eval-*.json"))):
    r = json.load(open(p))
    for n, s in r["presets"].items():
        rows.append(f"| {r['label']} | {n} | {s['keystrokes_saved_pct']:.1f}% | {s['chars_per_accept']:.2f} ({s['chars_saved_per_accept_net']:.2f}) | "
                    f"{s['acceptance_rate_pct']:.1f}% | {s['requests']} | {s['latency_ms']['p50']:.0f} / {s['latency_ms']['p90']:.0f} ms | "
                    f"{s['ttft_ms']['p50']:.0f} / {s['ttft_ms']['p90']:.0f} ms | {s['tokens_per_accepted_char']:.2f} |")
print("\n".join(rows))
