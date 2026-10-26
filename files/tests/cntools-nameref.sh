#!/usr/bin/env bash
# Static check for CNTools nameref collisions: a function that writes through
# printf -v / local -n / ${!name} / read (directly or by forwarding its
# arguments) must not declare a local with the same name as a variable a
# caller passes to it. Bash would then write the callee's local and the caller
# would keep its old value. This bug class has recurred, so every change runs
# this scan.
#
# Covered shapes: arguments on continuation lines, indented and "function"
# definitions, locals declared inside then/do blocks, forwarding through a
# local copy (local out="$1"; callee "${out}"), callees with any name, and
# "$@"-executing wrappers (spinners, review helpers) whose own locals shadow
# a name passed through them. Library functions defined twice also fail,
# because only one of the definitions would run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
command -v python3 >/dev/null 2>&1 || { printf 'SKIP: python3 is required for the nameref scan\n'; exit 0; }

hits="$(CNTOOLS_DIR="${CNTOOLS_DIR:-${REPO_ROOT}/scripts/common-helper-scripts/cntools}" python3 -I - <<'PY'
import re, glob, os, shlex, functools
C = os.environ["CNTOOLS_DIR"]
defre = re.compile(r'^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*([{(])')
lib_files = sorted(glob.glob(f"{C}/core/*.sh") + glob.glob(f"{C}/lib/*.sh"))
files = lib_files + sorted(glob.glob(f"{C}/modules/root/**/action.sh", recursive=True))
funcs = {}
for f in files:
    raw = open(f, errors='replace').read().split('\n')
    logical = []; i = 0
    while i < len(raw):          # join continuation lines, keep the first line number
        ln = i + 1; s = raw[i]
        while s.endswith('\\') and i + 1 < len(raw):
            i += 1; s = s[:-1] + ' ' + raw[i].strip()
        logical.append((ln, s)); i += 1
    cur = None; body = []; closer = '}'; indent = ''
    for ln, line in logical:
        m = defre.match(line)
        if m and cur is None:
            closer = '}' if m.group(2) == '{' else ')'
            indent = line[:len(line) - len(line.lstrip())]
            rest = line[m.end():].rstrip()
            if rest.endswith(closer):
                funcs.setdefault(m.group(1), []).append((f, [(ln, rest[:-1])])); continue
            cur = m.group(1); body = []; continue
        if cur is not None:
            if line.rstrip() == indent + closer:
                funcs.setdefault(cur, []).append((f, body)); cur = None
            else:
                body.append((ln, line))
localre = re.compile(r'(?:^|[;{(\s]|then|do|else)\s*(local|declare)((?:\s+-[a-zA-Z]+)*)\s+([^;&|]*)')
def locals_of(body):
    names = set()
    for _, l in body:
        for m in localre.finditer(l):
            if re.search(r'-[a-zA-Z]*[Fpf]', m.group(2)): continue
            rest = re.sub(r'"[^"]*"|\'[^\']*\'|\$\([^)]*\)', '""', m.group(3))
            names.update(re.findall(r'(?:^|\s)([A-Za-z_][A-Za-z0-9_]*)(?==|\s|$)', rest))
    return names
info = {}
for n, defs in funcs.items():
    f, body = defs[-1]
    info[n] = dict(file=f, body=body, locals=locals_of(body))
P = r'\$\{?([1-9])(?::-[^}]*)?\}?'
def pos_ref(a):
    m = re.fullmatch(P, a); return int(m.group(1)) if m else None
def aliases(body):            # local out="$1" → out stands for argument 1
    al = {}
    for _, l in body:
        for m in re.finditer(r'([A-Za-z_][A-Za-z0-9_]*)="\$\{?([1-9])(?::-[^}]*)?\}?"', l):
            al[m.group(1)] = int(m.group(2))
    return al
@functools.lru_cache(None)
def direct_out(n):
    d = info[n]; al = aliases(d['body']); outs = set()
    for _, l in d['body']:
        for m in re.finditer(r'(?:printf -v|local -n \w+=|declare -n \w+=|-n \w+=|read -r(?: -a)?|mapfile -t|readarray -t)\s*"?\$\{?([A-Za-z_0-9]+)(?::-[^}]*)?\}?"?', l):
            v = m.group(1)
            if v.isdigit(): outs.add(int(v))
            elif v in al: outs.add(al[v])
        for m in re.finditer(r'\$\{!([A-Za-z_0-9]+)', l):
            v = m.group(1)
            if v.isdigit(): outs.add(int(v))
            elif v in al: outs.add(al[v])
    return frozenset(outs), al
calls = {}
callre = re.compile(r'(?<![A-Za-z0-9_$-])([a-z_][a-z0-9_]*)\b')
for n, d in info.items():
    lst = []
    for ln, l in d['body']:
        for m in callre.finditer(l):
            g = m.group(1)
            if g not in info or g == n: continue
            seg = re.split(r'\|\||&&|;|\s\|\s|\)\s*$', l[m.end():])[0]
            try: args = shlex.split(seg, posix=True)
            except Exception: continue
            lst.append((ln, g, args))
    calls[n] = lst
def arg_index(a, al):
    k = pos_ref(a)
    if k is None:
        m = re.fullmatch(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?', a)
        if m and m.group(1) in al: k = al[m.group(1)]
    return k
@functools.lru_cache(None)
def outputs(n, depth=0):
    if n not in info or depth > 8: return frozenset()
    outs, al = direct_out(n); outs = set(outs)
    for ln, g, args in calls[n]:
        go = outputs(g, depth + 1)
        for q, a in enumerate(args, 1):
            if q not in go: continue
            k = arg_index(a, al)
            if k: outs.add(k)
            if a in ('$@', '${@}'): outs |= set(go)
    return frozenset(outs)
@functools.lru_cache(None)
def shadow(n, p, depth=0):
    if n not in info or depth > 8: return frozenset()
    s = set(info[n]['locals']); al = direct_out(n)[1]
    for ln, g, args in calls[n]:
        for q, a in enumerate(args, 1):
            if arg_index(a, al) == p: s |= shadow(g, q, depth + 1)
            if a in ('$@', '${@}'): s |= shadow(g, p, depth + 1)
    return frozenset(s)
hits = set()
for n, d in info.items():
    rel = os.path.relpath(d['file'], C)
    for ln, g, args in calls[n]:
        outs = outputs(g)
        for q, a in enumerate(args, 1):
            if q in outs and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', a) and a in shadow(g, q):
                hits.add(f"{rel} {ln} {n} {g} arg{q} {a}")
# "$@" wrappers: the wrapper's locals shadow names its inner command writes.
wraps = {}
for n, d in info.items():
    for ln, l in d['body']:
        if re.search(r'(^\s*|[;&|(!]\s*|\bif\s+|\bthen\s+|\bdo\s+)"\$@"', l) or re.search(r'(^|\s)"\$\{@:\d\}"', l):
            wraps[n] = d['locals']
for n, d in info.items():
    rel = os.path.relpath(d['file'], C)
    for ln, g, args in calls[n]:
        if g not in wraps: continue
        for i, a in enumerate(args):
            if a in info and a != g:
                outs = outputs(a)
                for q, b in enumerate(args[i + 1:], 1):
                    if q in outs and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', b) and b in wraps[g]:
                        hits.add(f"{rel} {ln} {n} {g}→{a} arg{q} {b} (wrapper local)")
                break
# Library functions defined more than once (action entry points repeat by design).
for n, defs in funcs.items():
    where = sorted({os.path.relpath(f, C) for f, _ in defs if f in lib_files})
    if len([1 for f, _ in defs if f in lib_files]) > 1:
        hits.add(f"duplicate definition {n} in {', '.join(where)}")
for h in sorted(hits): print(h)
PY
)"
if [[ -n "${hits}" ]]; then
  printf 'FAIL: nameref collisions (file line caller callee argument variable):\n%s\n' "${hits}" >&2
  exit 1
fi
printf 'cntools nameref scan passed\n'
