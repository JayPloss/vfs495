#!/bin/bash
# Offline reconstruction metric: decode every saved stream with the current build and
# score all pairs through libfprint (scripts/pair_scores.py, bozorth3, match >= 40),
# split over $JOBS processes. Mirrored copies of three images are the impostors.
# Usage: scripts/eval_swipes.sh <stream-dir> [exclude-pattern]
# Prints the summary for all swipes and, with an exclude pattern, for the rest.
# Images go to a private temp dir that is removed afterwards (fingerprint data).
set -e
src=$1; excl=$2; JOBS=${JOBS:-8}
here=$(cd "$(dirname "$0")/.." && pwd)
PY=${PY:-python3}
w=$(mktemp -d); chmod 700 "$w"; trap 'rm -rf "$w"' EXIT
for f in "$src"/*.stream; do
  "$here/target/release/vfs495" --base "$here" decode --feed --input "$f" --out "$w/$(basename "$f" .stream).pgm" >/dev/null 2>&1 \
    || echo "decode failed: $(basename "$f")"
done
mkdir "$w/imp"
for f in $(ls "$w"/*.pgm | tail -3); do
  "$PY" - "$f" "$w/imp/$(basename "$f")" <<'EOF'
import sys
d=open(sys.argv[1],'rb').read().split(b'\n',3)
w,h=map(int,d[1].split()); px=d[3]
open(sys.argv[2],'wb').write(d[0]+b'\n'+d[1]+b'\n'+d[2]+b'\n'+b''.join(px[i*w:(i+1)*w][::-1] for i in range(h)))
EOF
done
run() { # label, images...
  local label=$1; shift; local n=$# out=$w/out.$label; : >"$out"
  for j in $(seq 0 $((JOBS - 1))); do
    idx=$(seq $j $JOBS $((n - 1)) | paste -sd,)
    [[ -z $idx ]] && continue
    VFS_TPL=$idx "$PY" "$here/scripts/pair_scores.py" "$@" -- "$w"/imp/*.pgm 2>/dev/null | grep ': genuine' >>"$out" &
  done
  wait
  "$PY" - "$label" "$out" <<'EOF'
import sys, re, statistics as st
gen=[]; imp=[]
for l in open(sys.argv[2]):
    g=re.search(r'genuine \[(.*?)\]',l).group(1); i=re.search(r'impostor \[(.*?)\]',l).group(1)
    gen+=[int(x) for x in g.split(',') if x.strip()]; imp+=[int(x) for x in i.split(',') if x.strip()]
gs=sorted(gen)
import os
if os.environ.get("VERBOSE"):
    for l in sorted(open(sys.argv[2])):
        n=l.split(':')[0].strip(); g=[int(x) for x in re.search(r'genuine \[(.*?)\]',l).group(1).split(',') if x.strip()]
        print(f"  {n[-12:-4]} mean {st.mean(g):5.1f}  >=40 {sum(v>=40 for v in g)}/{len(g)}")
print(f"{sys.argv[1]:<7} GENUINE n={len(gen)} >=40: {sum(v>=40 for v in gen)} ({100*sum(v>=40 for v in gen)/len(gen):.0f}%)  >=25: {sum(v>=25 for v in gen)}  median {st.median(gen)}  mean {st.mean(gen):.1f}  min {gs[0]} | IMPOSTOR max {max(imp)} mean {st.mean(imp):.1f}")
EOF
}
run all "$w"/*.pgm
[[ -n $excl ]] && run subset $(ls "$w"/*.pgm | grep -v -- "$excl")
exit 0
