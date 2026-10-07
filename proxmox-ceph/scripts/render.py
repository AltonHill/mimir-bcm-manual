#!/usr/bin/env python3
"""Cerberus — scripts/render.py.

Render the site-specific Markdown guide: copy every runbook/NN-name/README.md
into a fresh output directory with variables.sh values substituted.

Only variables DEFINED in runbook/00-overview/variables.sh are substituted
(${VAR} and $VAR forms). Shell loop/local variables used inside the docs
(e.g. ${NODE_NUM}, ${MGMT_IP} derived via eval) are left untouched — they are
resolved at deploy time on the node, not at render time.

Usage:
    scripts/render.py --out site-docs/
    scripts/render.py --vars /path/to/variables.sh --out site-docs/ [--force]

The template docs are never modified; render always writes a fresh directory.
Unfilled PLACEHOLDER / empty values are reported, not hidden.
"""

import argparse
import os
import re
import shutil
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TRACK_DIR = os.path.dirname(SCRIPT_DIR)
DEFAULT_VARS = os.path.join(TRACK_DIR, "runbook", "00-overview", "variables.sh")
RUNBOOK_DIR = os.path.join(TRACK_DIR, "runbook")


def parse_variables(path):
    """Parse NAME="${NAME:-default}" and NAME="value" assignments.

    Returns (values dict, placeholder_names list).
    Later assignments win. Environment overrides are NOT applied —
    the file is the single source of truth (matches the BCM track).
    """
    values = {}
    # ${NAME:-default} form (Cerberus convention)
    pat_default = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"\$\{\1:-(.*)\}"\s*(?:#.*)?$')
    # plain "value" / 'value' / bare forms
    pat_plain = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|(\S+))\s*(?:#.*)?$")
    with open(path) as f:
        for line in f:
            line = line.strip()
            m = pat_default.match(line)
            if m:
                values[m.group(1)] = m.group(2)
                continue
            m = pat_plain.match(line)
            if m:
                values[m.group(1)] = m.group(2) if m.group(2) is not None else (m.group(3) if m.group(3) is not None else m.group(4))
    # Expand nested references (e.g. FOO="$BAR/baz"), stable sort, max 10 rounds
    for _ in range(10):
        changed = False
        for k, v in list(values.items()):
            def repl(m, _v=values):
                name = m.group(1) or m.group(2)
                return _v.get(name, m.group(0))
            new = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)", repl, v)
            if new != v:
                values[k] = new
                changed = True
        if not changed:
            break
    return values


def substitute(text, values):
    """Substitute ${VAR} / $VAR for known vars only.

    ${VAR:-...} / ${VAR:=...} shell-default forms are left alone — they are
    runtime shell, resolved when the doc's commands run on the node.
    """
    # ${VAR} not followed by :- or :=
    def braced(m):
        name = m.group(1)
        return values.get(name, m.group(0))
    text = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}(?![:-])", braced, text)

    # $VAR (bare) — word boundary, not followed by identifier chars
    names = sorted(values, key=len, reverse=True)
    if names:
        pat = re.compile(r"\$(" + "|".join(re.escape(n) for n in names) + r")(?![A-Za-z0-9_])")
        text = pat.sub(lambda m: values[m.group(1)], text)
    return text


def main():
    ap = argparse.ArgumentParser(description="Render the site-specific Cerberus guide.")
    ap.add_argument("--vars", default=DEFAULT_VARS, help="variables.sh to read")
    ap.add_argument("--out", required=True, help="fresh output directory")
    ap.add_argument("--force", action="store_true", help="overwrite existing output dir")
    args = ap.parse_args()

    if not os.path.isfile(args.vars):
        sys.exit(f"variables file not found: {args.vars}")
    values = parse_variables(args.vars)

    if os.path.exists(args.out):
        if not args.force:
            sys.exit(f"refusing to overwrite existing {args.out} (use --force)")
        shutil.rmtree(args.out)
    os.makedirs(args.out)

    sections = sorted(d for d in os.listdir(RUNBOOK_DIR)
                      if os.path.isdir(os.path.join(RUNBOOK_DIR, d)))
    rendered = 0
    for section in sections:
        src = os.path.join(RUNBOOK_DIR, section, "README.md")
        if not os.path.isfile(src):
            continue
        with open(src) as f:
            text = f.read()
        out_dir = os.path.join(args.out, "runbook", section)
        os.makedirs(out_dir)
        with open(os.path.join(out_dir, "README.md"), "w") as f:
            f.write(substitute(text, values))
        rendered += 1

    # Report unfilled values (still PLACEHOLDER or empty)
    unfilled = sorted(n for n, v in values.items() if v in ("", "PLACEHOLDER"))
    print(f"rendered {rendered} sections -> {args.out}/")
    print(f"variables read: {len(values)} from {args.vars}")
    if unfilled:
        print("UNFILLED variables (still PLACEHOLDER or empty) — resolve before deploy:")
        for n in unfilled:
            print(f"  {n}")
    else:
        print("all variables have site values.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
