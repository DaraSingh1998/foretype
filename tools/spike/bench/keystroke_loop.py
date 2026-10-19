#!/usr/bin/env python3
"""Simulated warm-cache keystroke loop against llama-server.

Starts llama-server with one slot, fills the KV cache with a prompt (zero-token
warm-up), then "types" the following characters one at a time. Each keystroke
sends the whole text so far with cache_prompt=true, so the server keeps the
longest common token prefix and prefills only the few tokens that changed
(usually the re-tokenised current word). For each keystroke it records the
client-side time to first streamed token (TTFT), the full suggestion time, and
the server's own prompt/decode timings.

Stdlib only. Run with: python3 -I keystroke_loop.py --model M.gguf ...
"""
import argparse
import http.client
import json
import os
import statistics
import subprocess
import sys
import time

HEADER = "The following is an email written in Mail.\n\n"


def pct(xs, p):
    if not xs:
        return None
    s = sorted(xs)
    return s[round(p / 100 * (len(s) - 1))]


def summary(xs):
    xs = [x for x in xs if x is not None]
    if not xs:
        return None
    return {"n": len(xs), "p50": round(pct(xs, 50), 2), "p90": round(pct(xs, 90), 2),
            "min": round(min(xs), 2), "max": round(max(xs), 2), "mean": round(statistics.fmean(xs), 2)}


def request(port, payload):
    """POST /completion with streaming; returns (ttft_ms, total_ms, final_chunk, n_chunks)."""
    body = json.dumps(payload).encode()
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=120)
    t0 = time.perf_counter()
    conn.request("POST", "/completion", body, {"Content-Type": "application/json"})
    resp = conn.getresponse()
    if resp.status != 200:
        raise RuntimeError(f"HTTP {resp.status}: {resp.read()[:300]!r}")
    ttft = None
    final = None
    chunks = 0
    while True:
        line = resp.readline()
        if not line:
            break
        line = line.strip()
        if not line.startswith(b"data:"):
            continue
        data = line[5:].strip()
        if data == b"[DONE]":
            break
        obj = json.loads(data)
        if not obj.get("stop"):
            chunks += 1
            if ttft is None:
                ttft = (time.perf_counter() - t0) * 1000
        else:
            final = obj
            break
    total = (time.perf_counter() - t0) * 1000
    conn.close()
    return ttft, total, final or {}, chunks


def wait_healthy(port, proc, timeout_s=180):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"llama-server exited early with code {proc.returncode}")
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            conn.request("GET", "/health")
            r = conn.getresponse()
            r.read()
            conn.close()
            if r.status == 200:
                return
        except OSError:
            pass
        time.sleep(0.25)
    raise RuntimeError("llama-server did not become healthy in time")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--server", default="llama-server")
    ap.add_argument("--model", required=True)
    ap.add_argument("--label", default=None)
    ap.add_argument("--prompt-file", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "prompt.txt"))
    ap.add_argument("--context-chars", type=int, default=2000, help="text already in the field before typing starts")
    ap.add_argument("--keystrokes", type=int, default=60)
    ap.add_argument("--n-predict", type=int, default=8, help="tokens per suggestion")
    ap.add_argument("--interval-ms", type=int, default=150, help="simulated typing cadence")
    ap.add_argument("--port", type=int, default=8791)
    ap.add_argument("--ctx", type=int, default=4096)
    ap.add_argument("--server-log", default=None)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    text = open(args.prompt_file, encoding="utf-8").read()
    if args.context_chars + args.keystrokes > len(text):
        sys.exit("prompt file too short for --context-chars + --keystrokes")

    cmd = [args.server, "-m", args.model, "-c", str(args.ctx), "-ngl", "99", "-np", "1",
           "--host", "127.0.0.1", "--port", str(args.port)]
    log = open(args.server_log or os.devnull, "w")
    t_load = time.perf_counter()
    proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
    try:
        wait_healthy(args.port, proc)
        load_ms = (time.perf_counter() - t_load) * 1000
        base = {"cache_prompt": True, "temperature": 0, "top_k": 1, "stream": True, "id_slot": 0}

        # Cold prefill of the existing field text, generating nothing (llama.vim's warm-up).
        prompt = HEADER + text[: args.context_chars]
        _, cold_ms, cold_final, _ = request(args.port, {**base, "prompt": prompt, "n_predict": 0})
        cold_t = cold_final.get("timings", {})

        # One suggestion at the same text: everything cached.
        _, _, _, _ = request(args.port, {**base, "prompt": prompt, "n_predict": args.n_predict})

        rows = []
        for i in range(args.keystrokes):
            t_key = time.perf_counter()
            prompt = HEADER + text[: args.context_chars + i + 1]
            ttft, total, final, chunks = request(args.port, {**base, "prompt": prompt, "n_predict": args.n_predict})
            t = final.get("timings", {})
            rows.append({
                "i": i, "char": text[args.context_chars + i],
                "ttft_ms": round(ttft, 2) if ttft is not None else None,
                "total_ms": round(total, 2),
                "prompt_n": t.get("prompt_n"), "prompt_ms": t.get("prompt_ms"),
                "cache_n": t.get("cache_n"),
                "predicted_n": t.get("predicted_n"), "predicted_ms": t.get("predicted_ms"),
                "predicted_per_token_ms": t.get("predicted_per_token_ms"),
                "chunks": chunks,
            })
            wait = args.interval_ms / 1000 - (time.perf_counter() - t_key)
            if wait > 0:
                time.sleep(wait)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()

    result = {
        "label": args.label or os.path.basename(args.model),
        "model": os.path.basename(args.model),
        "settings": {k: getattr(args, k) for k in ("context_chars", "keystrokes", "n_predict", "interval_ms", "ctx")},
        "server_load_ms": round(load_ms, 1),
        "cold_prefill": {"wall_ms": round(cold_ms, 1), "prompt_n": cold_t.get("prompt_n"),
                         "prompt_ms": cold_t.get("prompt_ms"),
                         "prompt_per_second": cold_t.get("prompt_per_second")},
        "ttft_ms": summary([r["ttft_ms"] for r in rows]),
        "suggestion_total_ms": summary([r["total_ms"] for r in rows]),
        "prefill_tokens": summary([r["prompt_n"] for r in rows]),
        "server_prefill_ms": summary([r["prompt_ms"] for r in rows]),
        "decode_ms_per_token": summary([r["predicted_per_token_ms"] for r in rows]),
        "keystrokes": rows,
    }
    out = json.dumps(result, indent=2)
    if args.out:
        with open(args.out, "w") as f:
            f.write(out + "\n")
    brief = {k: result[k] for k in result if k != "keystrokes"}
    print(json.dumps(brief, indent=2))


if __name__ == "__main__":
    main()
