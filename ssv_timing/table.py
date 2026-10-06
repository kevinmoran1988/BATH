# Summary tables: change in time per p7_SSVFilter() call against main; negative is faster.
import sys
R, rounds = sys.argv[1], int(sys.argv[2])
V = ['main', 'main_pragma', 'pr36', 'fold', 'fold_pragma']
Ms = [32, 64, 100, 200, 400, 1000, 2000, 3841]; Ls = [30, 100, 300, 1000]
def load(prefix, v):
    best = {}
    for r in range(1, rounds + 1):
        for ln in open(f"{R}/{prefix}_{v}_r{r}.txt"):
            M, L, a, s = ln.split(); k = (int(M), int(L)); t = (float(a), float(s))
            best[k] = tuple(min(x, y) for x, y in zip(best.get(k, (1e18, 1e18)), t))
    return best
def table(title, prefix, col):
    d = {v: load(prefix, v) for v in V}
    print(f"{title}: main_pragma / pr36 / fold / fold_pragma, % change against main   [main, ns per call]")
    print("  model " + "".join(f"{'sequence ' + str(L):>36s}" for L in Ls))
    for M in Ms:
        print(f"  {M:5d} " + "".join("   " + " /".join(f"{(d[v][(M, L)][col] / d['main'][(M, L)][col] - 1) * 100:+4.0f}" for v in V[1:])
                                     + f"  [{d['main'][(M, L)][col]:8.0f}]" for L in Ls))
    print()
table("AVX2 build, AVX2 kernel", 'd', 0)
table("AVX2 build, SSE kernel", 'd', 1)
table("SSE-only build", 's', 0)
