#!/usr/bin/env python3
"""Checks the app's translations against the Swift sources.

Every L("...") key in mac/Sources/Foretype must be in each language's Localizable.strings
(mac/Localization/<lang>.lproj; English needs none, its keys are the text), with the same
placeholders, and every LCount(...) key in each Localizable.stringsdict (English included).
Also lists translations no code uses any more. Exit status 1 on a problem.

    python3 scripts/check-localization.py
"""
import glob
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIT = r'"((?:[^"\\]|\\.)*)"'


def unescape(s):
    s = re.sub(r'\\u\{([0-9A-Fa-f]+)\}', lambda m: chr(int(m.group(1), 16)), s)
    return s.replace('\\"', '"').replace("\\'", "'").replace('\\n', '\n').replace('\\\\', '\\')


def code_keys():
    plain, counts = set(), set()
    for f in glob.glob(os.path.join(ROOT, 'mac/Sources/Foretype/*.swift')):
        src = open(f, encoding='utf-8').read()
        plain |= {unescape(m.group(1)) for m in re.finditer(r'\bL\(\s*' + LIT, src)}
        for m in re.finditer(r'\bL\(\w+ \? ' + LIT + r' : ' + LIT, src):
            plain |= {unescape(m.group(1)), unescape(m.group(2))}
        counts |= {unescape(m.group(1)) for m in re.finditer(r'\bLCount\([^"]*?' + LIT + r',\s*one:', src, re.S)}
    return plain, counts


def load(path):
    """A .strings or .stringsdict file as a dict (plutil reads both formats)."""
    out = subprocess.run(['plutil', '-convert', 'json', '-o', '-', path], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f'{path}: {out.stderr.strip()}')
    return json.loads(out.stdout)


def args(fmt):
    """The argument numbers a format string uses: %@ counts up, %2$@ names one."""
    used, nxt = set(), 1
    for m in re.finditer(r'%(?:(\d+)\$)?(?:#@\w+@|[@dlsfu.0-9]*[@dsfu])|%%', fmt):
        if m.group(0) == '%%':
            continue
        if m.group(1):
            used.add(int(m.group(1)))
        else:
            used.add(nxt)
            nxt += 1
    return used


def main():
    plain, counts = code_keys()
    problems = 0
    langs = sorted(os.path.basename(p)[:-6] for p in glob.glob(os.path.join(ROOT, 'mac/Localization/*.lproj')))
    for lang in langs:
        d = os.path.join(ROOT, 'mac/Localization', lang + '.lproj')
        if lang != 'en':
            strings = load(os.path.join(d, 'Localizable.strings'))
            for k in sorted(plain - strings.keys()):
                print(f'{lang}: missing {k!r}')
                problems += 1
            for k in sorted(strings.keys() - plain):
                print(f'{lang}: unused {k!r}')
            for k in sorted(plain & strings.keys()):
                if args(k) != args(strings[k]):
                    print(f'{lang}: placeholders differ for {k!r}: {strings[k]!r}')
                    problems += 1
        sd = os.path.join(d, 'Localizable.stringsdict')
        plurals = load(sd) if os.path.exists(sd) else {}
        for k in sorted(counts - plurals.keys()):
            print(f'{lang}: missing plural {k!r}')
            problems += 1
        for k in sorted(counts & plurals.keys()):
            want = {i + 1 for i in args(k)}  # the count is %1$ld, the key's arguments move up by one
            for name, var in plurals[k].items():
                if not isinstance(var, dict):
                    continue
                for form, text in var.items():
                    if form.startswith('NSString'):
                        continue
                    if args(text) - want or not args(text):
                        print(f'{lang}: plural {k!r} form {form!r} uses {sorted(args(text))}, expected {sorted(want)}')
                        problems += 1
    print(f'{len(plain)} strings, {len(counts)} counted, languages: {", ".join(langs)}; '
          + ('OK' if problems == 0 else f'{problems} problem(s)'))
    sys.exit(1 if problems else 0)


main()
