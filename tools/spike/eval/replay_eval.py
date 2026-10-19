#!/usr/bin/env python3
"""Replay evaluation for inline autocomplete: simulated typing against a completion backend.

Each corpus document is "typed" one character at a time. After every keystroke the harness
decides, as the product would, whether to ask for a suggestion:

  * gate: no request mid-word unless the fragment can still become a dictionary word, and none
    with more than 8 characters after the caret (always 0 in this append-only replay);
  * token healing: the partial word (with its leading whitespace) is backed off from the prompt
    and a GBNF grammar forces the continuation to start with exactly that fragment;
  * the suggestion shown is the generated text beyond the fragment, cut to N words (preset).

A simulated user then presses Tab (accepts the next word) whenever that word exactly matches
what they were about to type, and otherwise types the next character. A typed character that
matches the ghost text advances it without a new request (type-through); anything else drops it.

Metrics per preset: characters per accept (gross and net of the Tab press), % keystrokes saved,
acceptance rate, suggestion latency p50/p90, and generated tokens per accepted character as an
energy proxy. Generation is greedy, so one request generating up to the largest preset serves
every preset: the N-word suggestion is the first N words, and its latency is the time the N-th
word was complete in the stream.

Backend contract (llama-server's /completion; any engine exposing the same works):
  POST {backend}/completion  {"prompt", "n_predict", "grammar", "temperature": 0, "top_k": 1,
                              "cache_prompt": true, "stream": true}
  -> server-sent events "data: {...}" with "content" per token and a final {"stop": true,
     "timings": {...}}.

Usage:
  python3 -I replay_eval.py --model M.gguf [--server llama-server]   # starts llama-server
  python3 -I replay_eval.py --backend http://127.0.0.1:8080           # existing backend
"""
import argparse
import bisect
import http.client
import json
import os
import re
import statistics
import subprocess
import sys
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
MAX_SUFFIX_AFTER_CARET = 8  # llama.vim's max_line_suffix

# ---------------------------------------------------------------------------------------------
# Dictionary gate

# web2 (1934) predates much everyday vocabulary; this short, corpus-independent supplement covers
# common modern words. Everything else comes from /usr/share/dict.
MODERN = """email emails emailed online offline website websites app apps laptop laptops smartphone
wifi internet login logout signup username password passwords dashboard dashboards deploy deployed
deployment backend frontend database databases download downloads upload uploads uploaded okay ok
selfie podcast podcasts blog blogs blogger chatbot chatbots software hardware startup startups
covid vaccine vaccines streaming smartwatch bluetooth spreadsheet spreadsheets screenshot
screenshots onboarding offboarding workflow workflows teammate teammates feedback timeline
headphones earbuds airline airlines microwave fridge cellphone texting inbox homepage google
facebook youtube twitter instagram linkedin amazon microsoft apple iphone android windows linux
covid weekend weekends""".split()


class Dictionary:
    SUFFIXES = ["s", "es", "ed", "d", "ing", "er", "ers", "est", "ly", "ness", "ment", "ments",
                "able", "ful", "less", "ion", "ions", "ation", "ations", "al", "ally", "ity", "ive",
                "ize", "ized", "izing", "ise", "ised", "ising", "'s", "n't"]
    Y_SUFFIXES = ["ies", "ied", "ier", "iest", "ily", "iness"]
    E_DROP = ["ing", "ed", "er", "ers", "est", "able", "ation", "ations", "ion", "ions", "ity"]
    DOUBLE = ["ing", "ed", "er", "ers", "est", "y"]

    def __init__(self, paths=("/usr/share/dict/web2", "/usr/share/dict/propernames")):
        words = set(MODERN)
        for p in paths:
            if os.path.exists(p):
                with open(p, encoding="utf-8", errors="ignore") as f:
                    words.update(w.strip().lower() for w in f if w.strip().isalpha())
        self.words = words
        self.sorted = sorted(words)

    def _prefix_of_word(self, f):
        i = bisect.bisect_left(self.sorted, f)
        return i < len(self.sorted) and self.sorted[i].startswith(f)

    @staticmethod
    def _prefix_of_any(rest, options):
        return any(o.startswith(rest) for o in options)

    def can_become_word(self, f):
        f = f.lower()
        if not f or self._prefix_of_word(f):
            return True
        for k in range(len(f) - 1, 0, -1):
            stem, rest = f[:k], f[k:]
            if stem in self.words and self._prefix_of_any(rest, self.SUFFIXES):
                return True
            if stem + "y" in self.words and self._prefix_of_any(rest, self.Y_SUFFIXES):
                return True
            if stem + "e" in self.words and self._prefix_of_any(rest, self.E_DROP):
                return True
            if k >= 2 and stem[-1] == stem[-2] and stem[:-1] in self.words and self._prefix_of_any(rest, self.DOUBLE):
                return True
        return False


CONTRACTION_TAILS = ["s", "t", "re", "ve", "ll", "d", "m"]


def gate(dictionary, text_before, text_after=""):
    """Returns (allowed, reason). Mirrors the blueprint's policy gate for the replay."""
    if len(text_after.split("\n", 1)[0]) > MAX_SUFFIX_AFTER_CARET:
        return False, "suffix>8"
    m = re.search(r"\S*\Z", text_before)
    word = m.group(0) if m else ""
    run = re.search(r"[A-Za-z]+\Z", word)
    if not run:
        return True, "boundary"
    before = word[: run.start()]
    if before.endswith(("'", "\u2019")):
        tail = run.group(0).lower()
        return (any(c.startswith(tail) for c in CONTRACTION_TAILS), "contraction")
    if dictionary.can_become_word(run.group(0)):
        return True, "word-prefix"
    return False, "not-a-word-prefix"


# ---------------------------------------------------------------------------------------------
# Backend

def split_fragment(text):
    """Committed prompt text and the trailing partial word (with its leading whitespace)."""
    m = re.search(r"\s*\S*\Z", text)
    return text[: m.start()], m.group(0)


def gbnf_literal(s):
    out = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    return f'"{out}"'


UNIT = re.compile(r"\s*\S+")


def complete_units(display, final):
    """Words in `display` that are complete: followed by whitespace, or everything at stream end."""
    units = UNIT.findall(display)
    if final:
        return units
    return [u for u, end in zip(units, (mm.end() for mm in UNIT.finditer(display))) if end < len(display) and display[end].isspace()]


class Backend:
    def __init__(self, url, n_predict, presets, slot=True):
        u = urllib.parse.urlparse(url)
        self.host, self.port = u.hostname, u.port or 80
        self.n_predict = n_predict
        self.presets = presets
        self.slot = slot
        self.cache = {}
        self.calls = 0

    def suggest(self, header, committed, fragment):
        key = (header, committed, fragment)
        if key in self.cache:
            return self.cache[key]
        payload = {"prompt": header + committed, "n_predict": self.n_predict, "temperature": 0, "top_k": 1,
                   "cache_prompt": True, "stream": True}
        if self.slot:
            payload["id_slot"] = 0
        if fragment:
            payload["grammar"] = f"root ::= {gbnf_literal(fragment)} [^\\n]*"
        conn = http.client.HTTPConnection(self.host, self.port, timeout=120)
        t0 = time.perf_counter()
        conn.request("POST", "/completion", json.dumps(payload).encode(), {"Content-Type": "application/json"})
        resp = conn.getresponse()
        if resp.status != 200:
            raise RuntimeError(f"HTTP {resp.status}: {resp.read()[:300]!r}")
        gen, chunks, ttft, final = "", 0, None, {}
        ready = {}  # preset -> (ms, tokens)
        while True:
            line = resp.readline()
            if not line:
                break
            line = line.strip()
            if not line.startswith(b"data:"):
                continue
            obj = json.loads(line[5:].strip())
            if obj.get("stop"):
                final = obj
                break
            chunks += 1
            now = (time.perf_counter() - t0) * 1000
            if ttft is None:
                ttft = now
            gen += obj.get("content", "")
            if len(gen) >= len(fragment):
                done = len(complete_units(gen[len(fragment):], final=False))
                for n in self.presets:
                    if n not in ready and done >= n:
                        ready[n] = (now, chunks)
        end_ms = (time.perf_counter() - t0) * 1000
        conn.close()
        for n in self.presets:
            ready.setdefault(n, (end_ms, chunks))
        self.calls += 1
        t = final.get("timings", {})
        ok = gen.startswith(fragment)
        result = {
            "display": gen[len(fragment):] if ok else "",
            "grammar_ok": ok,
            "ttft_ms": ttft,
            "ready": ready,
            "tokens": chunks,
            "prompt_n": t.get("prompt_n"),
            "prompt_ms": t.get("prompt_ms"),
        }
        self.cache[key] = result
        return result


# ---------------------------------------------------------------------------------------------
# Simulated user

def accept_ok(target, pos, unit):
    """The suggested word matches what the user types next, without splitting a word."""
    end = pos + len(unit)
    if not unit or not target.startswith(unit, pos):
        return False
    return end == len(target) or not (target[end - 1].isalnum() and target[end].isalnum())


def run_doc(doc, preset, backend, dictionary, stats):
    target, header = doc["text"], doc["header"]
    pos = 0
    sugg = None          # remaining ghost text (str) or None
    sugg_meta = None     # dict for the suggestion currently shown
    while pos < len(target):
        if sugg is None:
            allowed, why = gate(dictionary, target[:pos])
            stats["gate"][why] = stats["gate"].get(why, 0) + 1
            if not allowed:
                # The corpus has no typos, so every block delays a word the user really types.
                stats["gate_blocks"] += 1
                m = re.match(r"[A-Za-z']*", target[pos:])
                word = (re.search(r"[A-Za-z']*\Z", target[:pos]).group(0) + m.group(0)).lower()
                stats["blocked_words"][word] = stats["blocked_words"].get(word, 0) + 1
            else:
                committed, fragment = split_fragment(target[:pos])
                r = backend.suggest(header, committed, fragment)
                stats["requests"] += 1
                ms, toks = r["ready"][preset]
                stats["latency_ms"].append(ms)
                stats["ttft_ms"].append(r["ttft_ms"])
                stats["tokens"] += toks
                if not r["grammar_ok"]:
                    stats["grammar_fail"] += 1
                units = UNIT.findall(r["display"])[:preset]
                sugg = "".join(units) or None
                if sugg:
                    stats["shown"] += 1
                    sugg_meta = {"accepted": 0}
        if sugg:
            unit = UNIT.match(sugg).group(0)
            if accept_ok(target, pos, unit):
                pos += len(unit)
                stats["tabs"] += 1
                stats["accepted_chars"] += len(unit)
                if sugg_meta["accepted"] == 0:
                    stats["suggestions_accepted"] += 1
                sugg_meta["accepted"] += 1
                sugg = sugg[len(unit):] or None
                continue
        c = target[pos]
        pos += 1
        stats["typed"] += 1
        if sugg and sugg[0] == c:
            sugg = sugg[1:] or None
            stats["type_through"] += 1
        else:
            sugg = None
    stats["chars"] += len(target)


def pct(xs, p):
    xs = [x for x in xs if x is not None]
    if not xs:
        return None
    s = sorted(xs)
    return s[round(p / 100 * (len(s) - 1))]


def summarize(stats):
    tabs, acc = stats["tabs"], stats["accepted_chars"]
    keys = stats["typed"] + tabs
    return {
        "chars": stats["chars"],
        "keystrokes": keys,
        "keystrokes_saved_pct": round(100 * (1 - keys / stats["chars"]), 2) if stats["chars"] else None,
        "tabs": tabs,
        "accepted_chars": acc,
        "chars_per_accept": round(acc / tabs, 2) if tabs else None,
        "chars_saved_per_accept_net": round((acc - tabs) / tabs, 2) if tabs else None,
        "suggestions_shown": stats["shown"],
        "suggestions_accepted": stats["suggestions_accepted"],
        "acceptance_rate_pct": round(100 * stats["suggestions_accepted"] / stats["shown"], 2) if stats["shown"] else None,
        "requests": stats["requests"],
        "type_through_chars": stats["type_through"],
        "gate": stats["gate"],
        "gate_blocks": stats["gate_blocks"],
        "blocked_words": dict(sorted(stats["blocked_words"].items(), key=lambda kv: -kv[1])[:25]),
        "grammar_fail": stats["grammar_fail"],
        "latency_ms": {"p50": round(pct(stats["latency_ms"], 50), 1), "p90": round(pct(stats["latency_ms"], 90), 1),
                       "mean": round(statistics.fmean(stats["latency_ms"]), 1)} if stats["latency_ms"] else None,
        "ttft_ms": {"p50": round(pct(stats["ttft_ms"], 50), 1), "p90": round(pct(stats["ttft_ms"], 90), 1)} if stats["ttft_ms"] else None,
        "tokens_generated": stats["tokens"],
        "tokens_per_accepted_char": round(stats["tokens"] / acc, 3) if acc else None,
    }


def new_stats():
    return {"chars": 0, "typed": 0, "tabs": 0, "accepted_chars": 0, "shown": 0, "suggestions_accepted": 0,
            "requests": 0, "type_through": 0, "gate": {}, "gate_blocks": 0, "blocked_words": {}, "grammar_fail": 0,
            "latency_ms": [], "ttft_ms": [], "tokens": 0}


def wait_healthy(port, proc, timeout_s=180):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"llama-server exited early with code {proc.returncode}")
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            c.request("GET", "/health")
            r = c.getresponse()
            r.read()
            c.close()
            if r.status == 200:
                return
        except OSError:
            pass
        time.sleep(0.25)
    raise RuntimeError("llama-server did not become healthy")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--backend", help="URL of a running /completion backend")
    ap.add_argument("--model", help="GGUF to serve with a fresh llama-server (instead of --backend)")
    ap.add_argument("--server", default="llama-server")
    ap.add_argument("--port", type=int, default=8792)
    ap.add_argument("--corpus", default=os.path.join(HERE, "corpus", "corpus.jsonl"))
    ap.add_argument("--presets", default="2,4,7")
    ap.add_argument("--n-predict", type=int, default=16)
    ap.add_argument("--max-docs", type=int, default=0)
    ap.add_argument("--label")
    ap.add_argument("--server-log")
    ap.add_argument("--out")
    args = ap.parse_args()
    if not args.backend and not args.model:
        sys.exit("give --backend URL or --model GGUF")

    presets = sorted(int(x) for x in args.presets.split(","))
    docs = [json.loads(l) for l in open(args.corpus) if l.strip()]
    if args.max_docs:
        docs = docs[: args.max_docs]
    dictionary = Dictionary()

    proc = log = None
    url = args.backend
    if args.model:
        log = open(args.server_log or os.devnull, "w")
        proc = subprocess.Popen([args.server, "-m", args.model, "-c", "4096", "-ngl", "99", "-np", "1",
                                 "--host", "127.0.0.1", "--port", str(args.port)], stdout=log, stderr=subprocess.STDOUT)
        wait_healthy(args.port, proc)
        url = f"http://127.0.0.1:{args.port}"
    backend = Backend(url, args.n_predict, presets)
    stats = {n: new_stats() for n in presets}
    t0 = time.time()
    try:
        for i, doc in enumerate(docs):
            for n in reversed(presets):  # largest first: smaller presets mostly hit its cache
                run_doc(doc, n, backend, dictionary, stats[n])
            print(f"[{i + 1}/{len(docs)}] {doc['id']} requests so far: {backend.calls}", file=sys.stderr, flush=True)
    finally:
        if proc:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
            log.close()

    unique = list(backend.cache.values())
    result = {
        "label": args.label or (os.path.basename(args.model) if args.model else url),
        "backend": "llama-server (started by harness)" if args.model else url,
        "corpus": {"path": os.path.relpath(args.corpus, HERE), "docs": len(docs),
                   "words": sum(len(d["text"].split()) for d in docs), "chars": sum(len(d["text"]) for d in docs)},
        "settings": {"presets": presets, "n_predict": args.n_predict, "decoding": "greedy",
                     "token_healing": "GBNF prefix constraint", "max_suffix_after_caret": MAX_SUFFIX_AFTER_CARET},
        "wall_s": round(time.time() - t0, 1),
        "backend_requests": backend.calls,
        "prefill_tokens_per_request_p50": pct([u["prompt_n"] for u in unique], 50),
        "presets": {str(n): summarize(stats[n]) for n in presets},
    }
    text = json.dumps(result, indent=2)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text + "\n")
    print(text)


if __name__ == "__main__":
    main()
