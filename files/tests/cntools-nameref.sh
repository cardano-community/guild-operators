#!/usr/bin/env bash
# Static check for CNTools nameref collisions: a function that writes through
# printf -v / local -n (directly or by forwarding its arguments) must not
# declare a local with the same name as a variable a caller passes to it.
# Bash would then write the callee's local and the caller would keep its old
# value. This bug class has recurred, so every change runs this scan.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
command -v python3 >/dev/null 2>&1 || { printf 'SKIP: python3 is required for the nameref scan\n'; exit 0; }

hits="$(CNTOOLS_DIR="${REPO_ROOT}/scripts/common-helper-scripts/cntools" python3 -I - <<'PY'
import re,glob,os,shlex,sys
C=os.environ["CNTOOLS_DIR"]
defre=re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{')
funcs={}  # name -> (file, body lines with lineno)
files=glob.glob(f"{C}/core/*.sh")+glob.glob(f"{C}/lib/*.sh")+glob.glob(f"{C}/modules/root/**/action.sh",recursive=True)
for f in files:
    cur=None;body=[]
    for i,line in enumerate(open(f,errors='replace'),1):
        m=defre.match(line)
        if m and cur is None:
            rest=line[m.end():].rstrip()
            if rest.endswith('}'):
                funcs.setdefault(m.group(1),[]).append((f,[(i,rest[:-1])])); continue
            cur=m.group(1);body=[];continue
        if cur is not None:
            if line.rstrip()=='}':
                funcs.setdefault(cur,[]).append((f,body));cur=None
            else: body.append((i,line))
localre=re.compile(r'^\s*(?:local|declare)\b([^;&|]*)')
def locals_of(body):
    names=set()
    for _,l in body:
        for seg in re.split(r';|&&|\|\|',l):
            m=localre.match(seg)
            if not m: continue
            rest=m.group(1)
            for tok in re.findall(r'(?:^|\s)(-[a-zA-Z]+|[A-Za-z_][A-Za-z0-9_]*)(?==|\s|$)',rest):
                if not tok.startswith('-'): names.add(tok)
    return names
indir=re.compile(r'printf -v|local -n|declare -n|\$\{!|read -r -a "\$|read -r "\$|mapfile|readarray')
info={}
for n,defs in funcs.items():
    f,body=defs[-1]
    text=''.join(l for _,l in body)
    info[n]=dict(file=f,body=body,locals=locals_of(body),indir=bool(indir.search(text)))
# forwards: within F, call G with "$@" or "$k" or "${k}" args -> map
fwd={}
for n,d in info.items():
    for _,l in d['body']:
        for g in re.findall(r'\b(cntools_[a-z0-9_]+)\b',l):
            if g not in info or g==n: continue
            after=l.split(g,1)[1]
            try: args=shlex.split(after.split('||')[0].split('&&')[0].split(';')[0].split('|')[0],posix=True)
            except Exception: continue
            for q,a in enumerate(args,1):
                if a in ('$@','${@}'):
                    fwd.setdefault(n,[]).append(('@',g,0))
                m=re.fullmatch(r'\$\{?([1-9])(?::-[^}]*)?\}?',a)
                if m: fwd.setdefault(n,[]).append((int(m.group(1)),g,q))
import functools
@functools.lru_cache(None)
def shadow(fn,p,depth=0):
    if depth>6 or fn not in info: return frozenset()
    s=set(info[fn]['locals'])
    for (k,g,q) in fwd.get(fn,[]):
        if k=='@': s|=shadow(g,p,depth+1)
        elif k==p: s|=shadow(g,q,depth+1)
    return frozenset(s)
def any_indir(fn,depth=0,seen=None):
    seen=seen or set()
    if fn in seen or fn not in info: return False
    seen.add(fn)
    if info[fn]['indir']: return True
    return any(any_indir(g,depth+1,seen) for (_,g,_) in fwd.get(fn,[]))
hits=[]
for n,d in info.items():
    for ln,l in d['body']:
        for g in set(re.findall(r'\b(cntools_[a-z0-9_]+)\b',l)):
            if g not in info or not any_indir(g): continue
            after=l.split(g,1)[1]
            try: args=shlex.split(after.split('||')[0].split('&&')[0].split(';')[0].split(' | ')[0],posix=True)
            except Exception: continue
            for q,a in enumerate(args,1):
                if re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*',a) and not a.isupper() and a in shadow(g,q):
                    # caller must own variable a? report anyway
                    hits.append((os.path.relpath(d['file'],C),ln,n,g,q,a))
for h in sorted(set(hits)): print(*h)
PY
)"
if [[ -n "${hits}" ]]; then
  printf 'FAIL: nameref collisions (file line caller callee argument variable):\n%s\n' "${hits}" >&2
  exit 1
fi
printf 'cntools nameref scan passed\n'
