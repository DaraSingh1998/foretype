#!/usr/bin/env python3
"""Builds corpus.jsonl from self_written.jsonl plus a filtered OpenAssistant/oasst1 slice.

oasst1 (Apache-2.0, https://huggingface.co/datasets/OpenAssistant/oasst1): the first 600 rows of
the validation split were fetched with the HF datasets-server rows API into oasst1-raw/. We keep
English, non-deleted, non-synthetic messages of 80-900 characters without code, markup or URLs:
every user ("prompter") message, then assistant replies (also human-written in oasst1) until the
oasst1 share reaches --oasst-words words.

Usage: python3 -I build_corpus.py [--oasst-words 1300]
"""
import argparse
import glob
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))


def clean_ok(t):
    return (80 <= len(t) <= 900 and "`" not in t and "http" not in t
            and not re.search(r"[<>{}\[\]|#*_$\\]", t)
            and len(re.findall(r"[^\x00-\x7f]", t)) < 3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--oasst-words", type=int, default=1300)
    args = ap.parse_args()

    docs = [json.loads(l) for l in open(os.path.join(HERE, "self_written.jsonl")) if l.strip()]
    for d in docs:
        d["source"] = "self-written"

    rows = []
    for f in sorted(glob.glob(os.path.join(HERE, "oasst1-raw", "rows-*.json"))):
        rows += [r["row"] for r in json.load(open(f))["rows"]]
    keep = [r for r in rows if r["lang"] == "en" and not r["deleted"] and not r["synthetic"]
            and r.get("review_result") is not False and clean_ok(r["text"].strip())]
    keep.sort(key=lambda r: (r["role"] != "prompter", r["message_id"]))
    words = 0
    for r in keep:
        if words >= args.oasst_words:
            break
        text = re.sub(r"[ \t]+", " ", r["text"].strip())
        header = ("A chat message written in a chat app:\n\n" if r["role"] == "prompter"
                  else "A reply written in a chat app:\n\n")
        docs.append({"id": f"oasst1-{r['message_id'][:8]}", "register": f"chat-{r['role']}",
                     "header": header, "text": text, "source": "oasst1 (Apache-2.0)"})
        words += len(text.split())

    out = os.path.join(HERE, "corpus.jsonl")
    with open(out, "w") as f:
        for d in docs:
            f.write(json.dumps(d, ensure_ascii=False) + "\n")
    by = {}
    for d in docs:
        k = d["source"]
        by.setdefault(k, [0, 0, 0])
        by[k][0] += 1
        by[k][1] += len(d["text"].split())
        by[k][2] += len(d["text"])
    print(json.dumps({"docs": len(docs), "by_source": {k: {"docs": v[0], "words": v[1], "chars": v[2]} for k, v in by.items()}}))


if __name__ == "__main__":
    main()
