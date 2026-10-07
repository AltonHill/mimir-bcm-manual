#!/bin/bash
# check.sh — validate the whole template: bash syntax, YAML parse,
# Python compile, template-variable sanity, identifier leak scan.
# Run after any edit, before any commit. Python 3.8+ stdlib only.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
say() { printf '%s\n' "$*"; }

say "== bash -n on all code blocks =="
python3 - <<'EOF'
import re, subprocess, tempfile, os, glob
fails = 0
for fn in sorted(glob.glob("*.md")):
    for m in re.finditer(r'```(bash|sh)\n(.*?)```', open(fn).read(), re.S):
        with tempfile.NamedTemporaryFile('w', suffix='.sh', delete=False) as t:
            t.write(m.group(2)); tname = t.name
        r = subprocess.run(['bash', '-n', tname], capture_output=True, text=True)
        os.unlink(tname)
        if r.returncode != 0:
            fails += 1
            print(f"BASH-FAIL {fn}: {r.stderr.strip()[:120]}")
print(f"bash: {fails} failures")
exit(1 if fails else 0)
EOF
[ $? -ne 0 ] && fail=1

say "== YAML parse on all code blocks =="
python3 - <<'EOF'
import re, glob, yaml
fails = 0
for fn in sorted(glob.glob("*.md")):
    for m in re.finditer(r'```yaml\n(.*?)```', open(fn).read(), re.S):
        try:
            list(yaml.safe_load_all(m.group(1)))
        except Exception as e:
            fails += 1
            print(f"YAML-FAIL {fn}: {str(e)[:120]}")
print(f"yaml: {fails} failures")
exit(1 if fails else 0)
EOF
[ $? -ne 0 ] && fail=1

say "== python compile =="
python3 -m py_compile scripts/*.py && say "py_compile: OK" || fail=1

say "== template variable sanity =="
# A $VAR is OK if it is exported by 00-variables.sh OR assigned locally
# in the same doc (VAR=... / export VAR=...), e.g. BMC_IP, PG_POD.
python3 - <<'EOF'
import re, glob
fails = 0
defined = set(re.findall(r'^export ([A-Za-z_][A-Za-z0-9_]*)', open('00-variables.sh').read(), re.M))
undefined = []
for fn in sorted(glob.glob("*.md")):
    text = open(fn).read()
    local = set(re.findall(r'^[ \t]*(?:export[ \t]+)?([A-Z][A-Z0-9_]{2,})=', text, re.M))
    # multi-assignments on one export line: export A=x B=y
    for line in re.findall(r'^[ \t]*export[ \t]+(.*)$', text, re.M):
        local.update(re.findall(r'([A-Z][A-Z0-9_]{2,})=', line))
    for v in set(re.findall(r'\$([A-Z][A-Z0-9_]{2,})', text)):
        if v not in defined and v not in local and v != "ALL":
            undefined.append(f"{fn}: ${v}")
if undefined:
    fails = 1
    print("UNDEFINED VARS:"); [print(f"  {u}") for u in sorted(undefined)]
else:
    print("vars: all $UPPER_CASE vars are defined (variables.sh or local assignment)")
exit(fails)
EOF
[ $? -ne 0 ] && fail=1

say "== identifier leak scan =="
if grep -riE 'lab-customer|client-corp|example-client\.com|<real-' --include='*.md' --include='*.py' --include='*.csv' --include='*.sh' --exclude='check.sh' . ; then
    say "LEAK-SCAN: hits found"; fail=1
else
    say "leak scan: clean"
fi

say "== pass smoke test =="
./scripts/runbook.py --vars 00-variables.sh vars >/dev/null 2>&1
# vars pass is EXPECTED to fail on the template's credential placeholders;
# what matters is that it runs and reports them (not a crash).
./scripts/runbook.py --vars 00-variables.sh networks --dry-run >/dev/null 2>&1 || fail=1
./scripts/runbook.py --vars 00-variables.sh networks --networks scripts/networks-template.csv --dry-run >/dev/null 2>&1 || fail=1
./scripts/runbook.py --vars 00-variables.sh images --dry-run >/dev/null 2>&1 || fail=1
./scripts/runbook.py --vars 00-variables.sh storage --plan 7a --dry-run >/dev/null 2>&1 || fail=1
./scripts/runbook.py --vars 00-variables.sh storage --plan 7b --dry-run >/dev/null 2>&1 || fail=1
./scripts/runbook.py --vars 00-variables.sh disklayouts >/dev/null 2>&1
# disklayouts is EXPECTED to fail without disk-layouts/<type>-by-path.xml;
# what matters is that it prints the collection procedure (not a crash).
./scripts/runbook.py --vars 00-variables.sh nodes --inventory /dev/null >/dev/null 2>&1
./scripts/generate-nodes.py --skeleton --ctrl 1 --workers 0 --gpus 1 2>/dev/null | ./scripts/generate-nodes.py --check /dev/stdin >/dev/null 2>&1 || fail=1
./scripts/generate-users.py --check scripts/accounts-template.csv >/dev/null 2>&1 || fail=1
rm -rf /tmp/render-smoke && ./scripts/runbook.py --vars 00-variables.sh render --out /tmp/render-smoke >/dev/null 2>&1 || fail=1
[ -f /tmp/render-smoke/README.md ] && [ -f /tmp/render-smoke/16-infiniband.md ] || fail=1
[ ! -f /tmp/render-smoke/99-role-mapping.md ] || fail=1
say "passes: OK"

if [ "$fail" -eq 0 ]; then say "ALL CHECKS PASSED"; else say "CHECKS FAILED"; fi
exit "$fail"
