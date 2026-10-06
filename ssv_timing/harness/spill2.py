# stack stores+loads per step in each step loop, per band width; one line per object
import sys,re,subprocess
def loops(out,fn):
    m=re.search(r'^[0-9a-f]+ <'+re.escape(fn)+r'>:\n(.*?)(?=^\n|\Z)',out,re.S|re.M)
    if not m: return None
    ins=[]
    for ln in m.group(1).splitlines():
        mm=re.match(r'\s*([0-9a-f]+):\s+(\S+)\s*(.*)',ln)
        if mm: ins.append((int(mm.group(1),16),mm.group(2),mm.group(3)))
    addr={a:i for i,(a,_,_) in enumerate(ins)}; res=[]
    for i,(a,op,arg) in enumerate(ins):
        if not op.startswith('j'): continue
        t=re.match(r'([0-9a-f]+)',arg)
        if not (t and int(t.group(1),16) in addr and addr[int(t.group(1),16)]<i): continue
        body=ins[addr[int(t.group(1),16)]:i+1]
        w=int(fn.split('_')[-1]); sub=sum(1 for _,o,_ in body if re.match(r'v?psubs',o))
        if sub!=w: continue                      # a step loop does exactly one step per pass
        st=sum(1 for _,o,g in body if re.match(r'v?mov(dq[au]|aps|ups)',o) and re.search(r',\s*-?(0x)?[0-9a-f]*\(%r[sb]p',g))
        ld=sum(1 for _,o,g in body if re.search(r'\(%r[sb]p[^)]*\),',g) and re.search(r'%[xy]mm',g))
        res.append(st+ld)
    return res
for label,o in [a.split('=') for a in sys.argv[1:]]:
    out=subprocess.run(['objdump','-d','--no-show-raw-insn',o],capture_output=True,text=True).stdout
    cells=[]
    for w in (3,6,7,8,10,12,13,14):
        r=loops(out,f'calc_band_{w}'); cells.append(f"w{w}: "+"/".join(str(x) for x in r))
    print(f"{label:12s} "+"   ".join(cells))
