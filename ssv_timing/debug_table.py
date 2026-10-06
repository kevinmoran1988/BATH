# Side-by-side table of focus runs.
#   debug_table.py label=file [label=file ...]
# Each file holds lines "M L ns". The first label is the reference; other
# columns show ns and the change against it. Cells 15% or more slower are
# marked "<<".
import sys

cols = [a.split('=', 1) for a in sys.argv[1:]]
data = {}
for lab, path in cols:
    d = {}
    for ln in open(path):
        p = ln.split()
        if len(p) == 3:
            d[(int(p[0]), int(p[1]))] = float(p[2])
    data[lab] = d
ref = cols[0][0]
keys = sorted(data[ref])
print(f"{'model':>6} {'L':>5} " + f"{ref + ' ns':>14}" + "".join(f"{lab + ' ns':>20} {'chg':>6}  " for lab, _ in cols[1:]))
for k in keys:
    row = f"{k[0]:6d} {k[1]:5d} {data[ref][k]:14.1f}"
    for lab, _ in cols[1:]:
        if k in data[lab]:
            c = (data[lab][k] / data[ref][k] - 1) * 100
            row += f"{data[lab][k]:20.1f} {c:+5.0f}% " + ("<<" if c >= 15 else "  ")
        else:
            row += f"{'-':>20} {'':>6}   "
    print(row)
