#!/usr/bin/env python3
"""Turns llama-bench JSON and keystroke-loop JSON into the Markdown tables used in RESULTS.md.

Usage: python3 -I summarize.py RESULTS_DIR
"""
import glob
import json
import os
import sys


def load(path):
    with open(path) as f:
        return json.load(f)


def bench_rows(path):
    rows = []
    for r in load(path):
        n_p, n_g, d = r.get("n_prompt", 0), r.get("n_gen", 0), r.get("n_depth", 0)
        test = f"pp{n_p}" if n_p and not n_g else f"tg{n_g}" if n_g and not n_p else f"pp{n_p}+tg{n_g}"
        if d:
            test += f" @ d{d}"
        ms = r.get("avg_ns", 0) / 1e6
        rows.append((r.get("model_filename", "?"), r.get("model_size", 0), test,
                     r.get("avg_ts", 0.0), r.get("stddev_ts", 0.0), ms, r))
    return rows


def model_name(path):
    return os.path.basename(path).replace(".gguf", "")


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "."
    out = []

    tp = os.path.join(d, "llama-bench-throughput.json")
    if os.path.exists(tp):
        out += ["### Throughput (llama-bench, cold context)", "",
                "| Model | Size | Test | tok/s | ± |", "|---|---:|---|---:|---:|"]
        for m, size, test, ts, sd, _, _ in bench_rows(tp):
            out.append(f"| {model_name(m)} | {size / 1e9:.2f} GB | {test} | {ts:.1f} | {sd:.1f} |")
        out.append("")

    wp = os.path.join(d, "llama-bench-warm.json")
    if os.path.exists(wp):
        out += ["### Few-token prefill on a warm KV cache (llama-bench `-d`)", "",
                "Time for a k-token prefill with d tokens already in the cache. The last prefill token's logits",
                "give the first suggested token, so this is the model-side time to first token.", "",
                "| Model | Test | tok/s | ms per call |", "|---|---|---:|---:|"]
        for m, _, test, ts, _, ms, r in bench_rows(wp):
            n = r.get("n_prompt") or r.get("n_gen") or 1
            per_call = n / ts * 1000 if ts else 0
            out.append(f"| {model_name(m)} | {test} | {ts:.1f} | {per_call:.1f} |")
        out.append("")

    loops = sorted(glob.glob(os.path.join(d, "loop-*.json")))
    if loops:
        out += ["### Simulated keystroke loop (llama-server, cache_prompt, 1 slot)", "",
                "| Model | Cold prefill | Prefill tokens/keystroke p50 (max) | TTFT p50 | TTFT p90 | TTFT max | 8-token suggestion p50 | p90 | Decode ms/token p50 |",
                "|---|---|---:|---:|---:|---:|---:|---:|---:|"]
        for p in loops:
            r = load(p)
            c = r["cold_prefill"]
            cold = f"{c['prompt_n']} tok in {c['prompt_ms']:.0f} ms" if c.get("prompt_ms") else f"{c['wall_ms']:.0f} ms wall"
            pt, tt, st, dt = r["prefill_tokens"], r["ttft_ms"], r["suggestion_total_ms"], r["decode_ms_per_token"]
            out.append(f"| {r['model']} | {cold} | {pt['p50']:.0f} ({pt['max']:.0f}) | {tt['p50']:.1f} | {tt['p90']:.1f} | "
                       f"{tt['max']:.1f} | {st['p50']:.1f} | {st['p90']:.1f} | {dt['p50']:.2f} |")
        out.append("")

    print("\n".join(out))


if __name__ == "__main__":
    main()
