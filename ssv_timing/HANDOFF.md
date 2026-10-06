# Handoff: one slow cell in the reworked SSV kernel on Zen 2

You are on the machine where the problem shows: an AMD Threadripper 3990X (Zen 2), WSL2. The session that wrote this ran on a Ryzen 9 9950X (Zen 5), where the problem does not show, so it could not investigate further. Everything you need is in this directory.

## What to find out

1. Why `fold_pragma`, built with gcc 13 as the SSE-only build, is far slower than `main` for a model of about 200 positions on short sequences on this CPU.
2. A version of the kernel change that is not slower than `main` in any cell on this machine, with gcc 13 and gcc 15, in all three kernels (AVX2, the SSE kernel of the AVX2 build, the SSE-only build).

If 1 cannot be explained, 2 still matters: the user has to decide what to send upstream.

## Ground rules

- Local work only. Do not push, do not open or comment on pull requests or issues, do not contact anyone. The user reads everything first and posts it himself.
- Work inside this clone. Do not edit `ssv_timing/variants/` in place. Put experiments in `ssv_timing/debug/variants/<name>/` (see `debug.sh`).
- Time on one pinned core, with nothing else heavy running. Compare numbers taken back to back; do not compare with a number from an hour ago.
- Give the user a short status line at each step. If you find something you did not expect, stop and tell him before building on it.
- Keep measured and inferred apart, and say what you ran. A result from one cell is a result for that cell.
- If something needs `sudo` (for example installing `perf`), ask the user; do not work around it.
- Scores must never change. `debug.sh` checks 22,000 calls against the first version in `VARS` on every run.

## Background

`p7_SSVFilter()` scores a sequence against a profile along diagonals, in bands of up to 14 vectors (`MAX_BANDS`). A model of M positions has Q = ceil(M/16) vectors in the SSE kernels (ceil(M/32) with AVX2), at least 2. The kernels are built from macros in three files that hold the same code:

- `src/impl_avx/ssvfilter_avx.c`: AVX2 kernel of the default build
- `src/impl_avx/ssvfilter_sse.c`: SSE kernel of the default build
- `src/impl_sse/ssvfilter.c`: the SSE-only build (`./configure --disable-avx`); its long header comment explains the design

Upstream PR TravisWheelerLab/BATH#36 kept two running maxima in the band kernels. A maintainer measured no gain on an Intel Xeon and little on an EPYC 7642 (Zen 2), and a 13–61% slowdown for long models on short sequences with gcc 13. Two causes were found:

- The gain was specific to Zen 5, where a chained vector operation costs 2 cycles (it costs 1 here; `run.sh` measures it). Intel has only two ports for these operations, so shortening the chain gains nothing there.
- gcc 13 spilled all 16 vector registers to the stack in the wide-band kernels.

The rework has two parts:

- **fold**: each step folds its band vectors into a temporary `tv`, and `tv` joins the running maximum `xEv` once (`STEP_FIRST`, `STEP_SINGLE`, `STEP_JOIN`). A band of two vectors keeps the old chain (`STEP_CHAIN`).
- **pragma**: `#pragma GCC optimize ("no-tree-coalesce-vars")` at the top of the three files. With gcc's default, every band vector is copied to a scratch register and back at each step, and the wide bands run out of registers.

`ssv_timing/variants/` holds five versions of the three files:

| version | content |
|---|---|
| `main` | upstream main, b401850f |
| `main_pragma` | main with the pragma |
| `pr36` | PR 36 as posted |
| `fold` | the fold |
| `fold_pragma` | the fold with the pragma |

The branch head has `fold_pragma` in `src/`, as two commits.

## What has been measured

`ssv_timing/run.sh` times `p7_SSVFilter()` alone for all five versions. Its last output on this machine is in `ssv_timing/results/table_gcc.txt` and `table_gcc_13.txt`. Read both.

Zen 2, best and worst cell per version (change in time per call against `main`, models 100 to 3,841, sequence lengths 30 to 1,000):

| compiler, kernel | `main_pragma` | `fold` | `fold_pragma` |
|---|---|---|---|
| gcc 13, AVX2 | −35% to +2% | −22% to +4% | −40% to 0% |
| gcc 13, SSE-only | −30% to +4% | −11% to +7% | −31% to **+88%** |
| gcc 15, AVX2 | −35% to +9% | −23% to +4% | −39% to 0% |
| gcc 15, SSE-only | −29% to +1% | −12% to +13% | −31% to 0% |

On Zen 5 the same versions give 0 to −21%, −17 to −64% and −20 to −72%, with no slow cell.

With gcc 13 this machine also reproduces the maintainer's numbers for `pr36` (for example +26% at 1,000 × 30 and +48% at 3,841 × 30, AVX2).

## The slow cell

gcc 13.4, SSE-only build, model 200 (Q = 13, one band of 13 vectors), ns per call:

| sequence length | `main` | `main_pragma` | `fold` | `fold_pragma` |
|---|---|---|---|---|
| 1 | 23.1 | 18.5 | 27.9 | 19.3 |
| 5 | 37.1 | 30.5 | 41.1 | 31.5 |
| 10 | 52.7 | 47.0 | 57.6 | 47.7 |
| 30 | 122.0 | 112.3 | 118.6 | **230.0** |
| 100 | 345.5 | 348.8 | 316.5 | **461.3** |
| 300 | 986.1 | 1021.9 | 875.7 | 830.3 |
| 1000 | 3209.7 | 3342.1 | 2850.6 | 2771.0 |

What that shows:

- A fixed cost of about 110 ns per call, roughly 450 cycles at this CPU's clock. It is absent at length 10 and present at 30, and about the same at 100, so it does not grow with the sequence.
- It is stable: three separate runs gave 230.9, 230.9 and 228.2 ns. Each run is its own process, so the stack and heap addresses differed. That argues against an effect that depends on exact data addresses.
- Neither change alone has it, and gcc 15 does not have it.
- The AVX2 kernel does not have it.
- The SSE kernel of the AVX2 build, which is the same source in another object file, has a small version of it with gcc 13 (+6% at 200 × 30).
- Smaller penalties show in models that use a 13-vector band among others: against `main_pragma`, `fold_pragma` is about 40 ns slower at 400 × 30 and 55 ns slower at 1,000 × 30 (gcc 13, SSE-only).
- The other machine has the same gcc 13 package (Ubuntu 13.4.0-10ubuntu1), so very likely the same machine code, and there this cell is 51% faster than `main`. So this is something Zen 2 does with that code.
- Short-sequence cells on this CPU move by 5–10% with code layout alone: `main` itself differs by 6% between the SSE-only build and the SSE kernel of the AVX2 build at 400 × 30.

## How a call runs for a one-band model

For Q = 13 the band is 13 vectors wide and `CALC()` never enters its step loops (they run `Q - w` = 0 times). All the work is in three unrolled copies of `CONVERT_13`, each 13 steps:

1. the first, with a length check before every step (exits to `done1`)
2. the one inside the `i2` loop, with no checks; it runs once per full 13 residues while `i2 < L - Q`
3. the last, with length checks (exits to `done2`)

So a sequence of up to 13 residues uses only the first copy. Lengths 14 to 26 use the first and the last. From 27 on the middle copy runs too. Whether the penalty starts at 14 or at 27 tells you which transition causes it. Sweep A in `debug.sh` answers that.

In `fold_pragma` as gcc 13 compiles it for the SSE-only build, `calc_band_13` has 32 vector stores to the stack, 33 vector loads from it, 17 `por` with a stack operand (`beginv` lives on the stack) and one `pmaxub` with a stack operand. `debug.sh` writes the disassembly of `calc_band_13` for every version to `debug_results/<compiler>/asm_band13_*.txt`.

## Tools

```bash
ssv_timing/debug.sh 2 gcc-13
```

builds the four main versions against the existing library build and runs two sweeps: A (model 200, lengths 1 to 60) and B (one-band models of 7 to 14 vectors at a few lengths). Its header lists the knobs. The useful ones:

- `MODE=band` calls the band kernel directly and leaves `get_xE()` and the score conversion out.
- `KERNEL=dispatch` times the SSE kernel of the AVX2 build.
- `EXTRA="..." TAG=_name` compiles the kernel file with extra flags and keeps the results apart.
- `VARS="main fold_pragma myversion"` picks versions; a version is read from `ssv_timing/debug/variants/<name>/` if it exists.
- `PERF=1` runs `perf stat` on one cell. Set `EV=` for other events.

`perf` worked under WSL2 on the other machine (package `linux-perf`), with hardware counters. If it is missing here, ask the user to install it. On Zen 2 look at `ex_ret_brn_misp`, `ls_stlf`, `ls_bad_status2.stli_other` and whatever `perf list` offers for the op cache and for dispatch stalls.

`ssv_timing/run.sh 2 gcc gcc-13` is the full grid. `VARS=` and `ROUNDS=` work there too, and a version placed in `ssv_timing/debug/variants/<name>/` (all three files) is picked up.

## Suggested order

1. Run `debug.sh` as it is. Find the length where the penalty starts, and which band widths have it.
2. `MODE=band`: is it in the band kernel or around it?
3. `PERF=1` on `main` and `fold_pragma` at the bad cell. Compare cycles, instructions, branch misses, then the store-forwarding events. 450 cycles per call is large: about 25 branch mispredictions, or a few dozen failed store forwards.
4. Read the disassembly along the path a length-30 call takes. Compare with gcc 15's code for the same source, which is fine, and with `main_pragma` from gcc 13.
5. Layout: rebuild with flags such as `-falign-functions=64`, `-falign-jumps=32`, `-falign-labels=32`, `-fno-reorder-blocks`. If the penalty moves or goes, it is layout, not the code as such.
6. Bisect the source. Ideas: keep the chain for a 13-vector band as is done for two; declare `tv` inside each step's block instead of once per function; apply the pragma to some functions only with `__attribute__((optimize("no-tree-coalesce-vars")))`; try `-fira-region=all` or `-fno-ira-share-spill-slots` with the pragma.

## What the user is choosing between

1. Send the pragma alone and drop the fold. Smallest change; no large slow cell seen, worst +9%.
2. Fold with the pragma in the AVX2 kernel, pragma alone in the SSE kernels.
3. Fold with the pragma everywhere, if the slow cell can be explained and removed.
4. The fold alone.

The fold is worth 40–60% on Zen 3 and later by the other machine's measurements, so there is a reason to keep it if it can be made safe here.

## What to hand back

Write `ssv_timing/debug_results/REPORT.md` with:

- the cause, or how far you narrowed it, with the numbers that show it
- the version you recommend, as source for all three files under `ssv_timing/debug/variants/<name>/`
- the full `run.sh` tables for that version with gcc 13 and gcc 15, and a list of every cell more than 3% slower than `main`
- what you did not check

The user will carry that back to the other session.
