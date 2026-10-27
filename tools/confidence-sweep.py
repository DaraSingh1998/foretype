#!/usr/bin/env python3
"""Sweep confidence-gate bars over an ft-replay --confidence-log (one JSON line per keystroke
showing a model suggestion). Per position kind, for each bar: suggestions kept, right ones kept
(of all right ones: what the gate costs), precision of what is kept, and wrong ones removed."""
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
for kind, mid in (("mid-word", True), ("after a word", False)):
    r = [x for x in rows if x["mid"] == mid]
    right = sum(x["right"] for x in r); wrong = len(r) - right
    print(f"\n{kind}: {len(r)} shown, {right} right ({100*right/max(1,len(r)):.1f}%)")
    print(f"{'bar':>6} {'kept':>6} {'right kept':>11} {'precision':>10} {'wrong removed':>14}")
    for bar in (0, .02, .04, .06, .08, .1, .12, .15, .2, .25, .3, .4, .5):
        k = [x for x in r if x["p"] >= bar]
        kr = sum(x["right"] for x in k)
        print(f"{bar:>6.2f} {100*len(k)/max(1,len(r)):>5.1f}% {100*kr/max(1,right):>10.1f}% {100*kr/max(1,len(k)):>9.1f}% {100*(wrong-(len(k)-kr))/max(1,wrong):>13.1f}%")
# Calibration: right rate per probability band.
print("\ncalibration (first-word probability band: right rate, n)")
for lo, hi in ((0,.05),(.05,.1),(.1,.2),(.2,.3),(.3,.5),(.5,.7),(.7,.9),(.9,1.01)):
    for mid in (True, False):
        b = [x for x in rows if lo <= x["p"] < hi and x["mid"] == mid]
        if b:
            print(f"  {lo:.2f}-{hi:.2f} {'mid ' if mid else 'word'}: {100*sum(x['right'] for x in b)/len(b):5.1f}% of {len(b)}")
