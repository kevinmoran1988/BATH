# Per-band summary: change in time per call against main, best of the rounds found.
#   bandtab.py <out dir> <tag> [<tag> ...]
# One table per kernel and version: rows are band widths, columns are compilers,
# each cell is the change at sequence lengths 30 / 100 / 300 / 1000.
import sys, os, glob

out, tags = sys.argv[1], sys.argv[2:]
Ls = [30, 100, 300, 1000]


def load(tag, kern, v):
    best = {}
    for f in glob.glob(f"{out}/{tag}/{kern}_{v}_r*.txt"):
        for ln in open(f):
            p = ln.split()
            if len(p) == 3:
                k = (int(p[0]), int(p[1]))
                best[k] = min(best.get(k, 1e18), float(p[2]))
    return best


def name(tag):
    f = f"{out}/{tag}/machine.txt"
    return open(f).readline().split(':', 1)[1].strip() if os.path.exists(f) else tag


for tag in tags:
    print(f"{tag}: {name(tag)}; scores: {sum(int(l.split()[2]) for l in open(f"{out}/{tag}/scores.txt"))} differences")
print()
worst = []
for kern, per, label in (('avx', 32, 'AVX2 kernel'), ('sse', 16, 'SSE-only build')):
    for v, vl in (('pr', 'PR head (fold + pragma)'), ('main_pragma', 'pragma alone'), ('fold', 'fold alone')):
        d = {t: (load(t, kern, 'main'), load(t, kern, v)) for t in tags}
        print(f"{label}, {vl}: % change against main at sequence length 30 / 100 / 300 / 1000")
        print("  band  model " + "".join(f"{t:>24s}" for t in tags))
        for w in range(2, 15):
            M = per * w
            row = f"  {w:4d}  {M:5d} "
            for t in tags:
                m, x = d[t]
                cs = [(x[(M, L)] / m[(M, L)] - 1) * 100 if (M, L) in x and (M, L) in m else None for L in Ls]
                row += f"{'/'.join('  ?' if c is None else f'{c:+4.0f}' for c in cs):>24s}"
                for L, c in zip(Ls, cs):
                    if c is not None and c >= 3:
                        worst.append((c, label, vl, t, w, L))
            print(row)
        print()
print("cells 3% or more slower than main:")
for c, label, vl, t, w, L in sorted(worst, reverse=True):
    print(f"  {c:+5.0f}%  {t:10s} {label:15s} {vl:26s} band {w:2d}  L {L}")
if not worst:
    print("  none")
