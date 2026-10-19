#!/usr/bin/env python3
"""Summarises run_apps.sh output (results/probe/*.jsonl) into the Markdown tables in RESULTS.md.

Usage: python3 -I analyze.py [RESULTS_PROBE_DIR [scenario,scenario,...]]
"""
import collections
import glob
import json
import os
import sys

ORDER = ["textedit", "safari", "safari-ce", "chrome", "chrome-ax", "chrome-ce-ax", "edge", "edge-ax", "notes",
         "stickies", "libreoffice-writer", "wordcraft", "teams", "vscode", "bundle-open", "bundle-exec"]


def scenarios(d):
    found = {os.path.basename(p).split(".")[0] for p in glob.glob(os.path.join(d, "*.jsonl"))}
    return [s for s in ORDER if s in found] + sorted(found - set(ORDER))
CALLS = ["AXFocusedUIElement", "AXValue", "AXSelectedTextRange", "AXBoundsForRange(caret,0)",
         "AXBoundsForRange(prev,1)", "AXAttributedStringForRange(1)"]


def pct(xs, p):
    if not xs:
        return None
    s = sorted(xs)
    return s[round(p / 100 * (len(s) - 1))]


def fmt(x, nd=1):
    return "–" if x is None else f"{x:.{nd}f}"


def lines(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(l) for l in f if l.strip()]


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results", "probe")
    out = []
    SCENARIOS = scenarios(d)
    if len(sys.argv) > 2:  # optional comma-separated subset
        SCENARIOS = [x for x in SCENARIOS if x in sys.argv[2].split(",")]

    out += ["### Field as first seen (`--once`)", "",
            "| Scenario | App | Role (description) | Value len | Selection | Marked range | Zero-length caret | Prev-char edge | Disagree px | AXFont |",
            "|---|---|---|---:|---|---|---|---|---:|---|"]
    for s in SCENARIOS:
        snaps = [o for o in lines(f"{d}/{s}.once.jsonl") if o["type"] == "snapshot" and o["reason"] == "once"]
        if not snaps:
            continue
        o = snaps[-1]
        c = o.get("caret", {})
        z = c.get("zeroLength") or {}
        p = c.get("prevCharTrailingEdge") or {}
        sel = o.get("selectedTextRange") or {}
        mk = o.get("markedRange")
        font = o.get("axFont") or {}
        zr = z.get("rect")
        pr = p.get("caret")
        out.append(
            f"| {s} | {o.get('app', {}).get('bundleId')} | {o.get('role')} ({o.get('roleDescription')}) | {o.get('valueLength')} | "
            f"{sel.get('location')}+{sel.get('length')} | {'none' if mk is None else str(mk['location']) + '+' + str(mk['length'])} | "
            f"{'–' if not zr else f'y={zr['y']} h={zr['h']} w={zr['w']}'} {('⚠ ' + ','.join(z.get('issues'))) if z.get('issues') else ''} | "
            f"{'–' if not pr else f'y={pr['y']}'} {('⚠ ' + ','.join(p.get('issues'))) if p.get('issues') else ''} | "
            f"{fmt(c.get('strategiesDisagreeByPx'), 0)} | {', '.join(f'{k.removeprefix("AXFont").removeprefix("AX")}={v}' for k, v in sorted(font.items())) or 'none'} |")
    out.append("")

    out += ["### Typing run (`--type`, 32 synthetic keystrokes at 120 ms)", "",
            "| Scenario | Keys seen by tap | Tap lag p50 | Snapshots (notif / poll-only) | AX notifications per keystroke | Keystroke → AX notification p50 / p90 / max | Snapshot AX cost p50 / p90 | Zero-length rect vs prev-char edge |",
            "|---|---:|---:|---|---|---|---|---|"]
    for s in SCENARIOS:
        L = lines(f"{d}/{s}.watch.jsonl")
        if not L:
            continue
        keys = [o for o in L if o["type"] == "key" and o["kind"] == "down"]
        snaps = [o for o in L if o["type"] == "snapshot" and "app" in o]
        summ = next((o for o in reversed(L) if o["type"] == "summary"), {})
        typer = [o for o in L if o["type"] == "typer" and o["status"] != "start"]
        typed = typer[-1].get("typed", 0) if typer else 0
        lag = [k["tapLagMs"] for k in keys if k.get("tapLagMs") is not None]
        since = [o["msSinceLastKeyDown"] for o in snaps
                 if o["reason"] not in ("poll",) and not o["reason"].startswith("appActivated")
                 and o.get("msSinceLastKeyDown") is not None and o["msSinceLastKeyDown"] < 500]
        ax = [o["axTotalMs"] for o in snaps]
        notif = summ.get("notifications", {})
        per_key = ", ".join(f"{k.replace('AX', '').replace('Changed', '')} {v / typed:.1f}"
                            for k, v in sorted(notif.items()) if typed and k in ("AXSelectedTextChanged", "AXValueChanged"))
        disagree = [o["caret"].get("strategiesDisagreeByPx") for o in snaps if o.get("caret", {}).get("strategiesDisagreeByPx") is not None]
        zbad = sum(1 for o in snaps if (o.get("caret", {}).get("zeroLength") or {}).get("issues"))
        roles = collections.Counter(o.get("role") for o in snaps)
        dis_txt = (f"differ by {collections.Counter(round(x) for x in disagree).most_common(1)[0][0]} px"
                   if disagree else "agree") + (f"; zero-length rejected {zbad}/{len(snaps)}" if zbad else "")
        out.append(
            f"| {s} ({'/'.join(r or '?' for r in roles)}) | {len(keys)} | {fmt(pct(lag, 50), 2)} ms | "
            f"{summ.get('snapshotsEmitted', 0) - summ.get('changesOnlySeenByPoll', 0)} / {summ.get('changesOnlySeenByPoll', 0)} | {per_key} | "
            f"{fmt(pct(since, 50))} / {fmt(pct(since, 90))} / {fmt(max(since) if since else None)} ms | "
            f"{fmt(pct(ax, 50))} / {fmt(pct(ax, 90))} ms | {dis_txt} |")
    out.append("")

    out += ["### Back-to-back snapshot cost (`--bench 30`, ms p50 / p90)", "",
            "| Scenario | App measured | Whole snapshot | " + " | ".join(CALLS) + " |",
            "|---|---|---|" + "---|" * len(CALLS)]
    for s in SCENARIOS:
        b = next((o for o in lines(f"{d}/{s}.bench.jsonl") if o["type"] == "bench"), None)
        if not b:
            continue
        pc = b["perCall"]
        cells = [f"{fmt(pc[k]['p50'], 2)} / {fmt(pc[k]['p90'], 2)}" if k in pc else "–" for k in CALLS]
        sm = b["snapshotMs"]
        out.append(f"| {s} | {(b.get('app') or {}).get('bundleId')} | {fmt(sm['p50'])} / {fmt(sm['p90'])} (max {fmt(sm['max'])}) | " + " | ".join(cells) + " |")
    out.append("")
    print("\n".join(out))


if __name__ == "__main__":
    main()
