#!/bin/bash
# Per-band SSV kernel timing for one compiler. Temporary; not part of any pull request.
#
#   ssv_timing/bands.sh [compiler] [core]       default: gcc, first CPU this shell may use
#   e.g.  ssv_timing/bands.sh gcc
#         ssv_timing/bands.sh gcc-12 6
#
# Builds this tree as an AVX2 build and an SSE-only build, then times
# p7_SSVFilter() for one-band models of every band width, 2 to 14 vectors
# (model length 32 x width for AVX2, 16 x width for SSE), at sequence lengths
# 30, 100, 300 and 1000, for four versions of the kernel:
#   main          upstream main (b401850f)
#   main_pragma   main with the gcc pragma
#   fold          the fold alone
#   pr            TravisWheelerLab/BATH#36 as it stands: fold and pragma, both for gcc only
# Each version is the three kernel files in variants/, compiled with the build's
# own flags and linked in front of the library, so the commit checked out does
# not matter. ROUNDS (default 3) separate runs per cell; the table takes the best.
#
# Needs git, make, taskset. autoconf is used if present; otherwise a generated
# configure shipped next to this script is used. python3 is only needed for the
# summary table. Run it on a quiet machine: on a cluster, inside a job, not on
# a login node. easel must be in the tree (see below) since compute nodes often
# have no network.
#
# Results: ssv_timing/band_out/<compiler>/   (table.txt is the summary)

K=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$K/.." && pwd)
CC=${1:-gcc}
CORE=${2:-$(taskset -cp $$ 2> /dev/null | sed 's/.*: *//; s/[,-].*//')}; CORE=${CORE:-0}
ROUNDS=${ROUNDS:-3}; JOBS=${JOBS:-8}
command -v $CC > /dev/null || { echo "$CC not found"; exit 1; }
if [ ! -d $ROOT/easel ]; then
  echo "== fetching easel (branch BATH)"
  git clone -q -b BATH https://github.com/TravisWheelerLab/easel $ROOT/easel || { echo "no easel in $ROOT and could not clone it; on a machine with network run:  git clone -b BATH https://github.com/TravisWheelerLab/easel $ROOT/easel"; exit 1; }
fi
tag=$(echo ${TAG:-$CC} | tr -c 'A-Za-z0-9.\n' '_'); B=$K/build_$tag; R=$K/band_out/$tag; mkdir -p $B $R      # the build directory is shared with run.sh
VARS="main main_pragma fold pr"; LS="30,100,300,1000"; H=$K/harness
{ echo "compiler: $($CC --version | head -1)"
  echo "cpu:     $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2)"
  echo "host:     $(hostname)   kernel $(uname -r)"
  echo "date:     $(date)"
  echo "core:     $CORE   (allowed: $(taskset -cp $$ 2> /dev/null | sed 's/.*: *//'))"; } > $R/machine.txt
command -v lscpu > /dev/null && lscpu > $R/lscpu.txt 2>&1

echo "== $CC: building (AVX2 build and SSE-only build), $JOBS jobs"
for kind in avx sse; do T=$B/$kind
  if [ ! -f $T/src/libhmmer.a ]; then
    rm -rf $T; mkdir -p $T/easel
    git -C $ROOT archive HEAD | tar -x -C $T || { echo "could not copy the source tree"; exit 1; }
    if git -C $ROOT/easel rev-parse HEAD > /dev/null 2>&1; then git -C $ROOT/easel archive HEAD | tar -x -C $T/easel; else cp -r $ROOT/easel/. $T/easel/; fi
    if [ -z "${NO_AUTOCONF:-}" ] && command -v autoconf > /dev/null; then ( cd $T && autoconf ) || exit 1
    else cp $K/configure.generated $T/configure && chmod +x $T/configure; fi
    ( cd $T && ./configure CC=$CC $([ $kind = sse ] && echo --disable-avx) > $B/configure_$kind.log 2>&1 \
        && make -j$JOBS > $B/make_$kind.log 2>&1 ) || { echo "build failed ($kind): see $B/configure_$kind.log and $B/make_$kind.log"; tail -3 $B/make_$kind.log; exit 1; }
  fi
done
A=$B/avx; SS=$B/sse
flag() { grep -m1 "^$2 *=" $1/src/Makefile | cut -d= -f2-; }
CF=$(flag $A CFLAGS); AVXF=$(flag $A AVX_CFLAGS); SSEF=$(flag $A SSE_CFLAGS); PTF=$(flag $A PTHREAD_CFLAGS)
echo "flags:    CFLAGS=$CF AVX_CFLAGS=$AVXF SSE_CFLAGS=$SSEF" >> $R/machine.txt
grep -q 'define eslENABLE_AVX 1' $A/easel/esl_config.h 2> /dev/null || echo "note:     configure did not enable AVX2 on this machine" >> $R/machine.txt

echo "== $CC: compiling kernel versions and benchmarks"
IA="-DHAVE_CONFIG_H -I$A/easel -I$A/src/impl_avx -I$A/src"; IS="-DHAVE_CONFIG_H -I$SS/easel -I$SS/src/impl_sse -I$SS/src"
LA="$A/src/libhmmer.a $A/easel/libeasel.a -lm -lpthread"; LSS="$SS/src/libhmmer.a $SS/easel/libeasel.a -lm -lpthread"
for v in $VARS; do
  $CC $CF $PTF $AVXF $IA -o $B/${v}_avx.o     -c $K/variants/$v/ssvfilter_avx.c 2> $B/cc_${v}_avx.log     || { echo "compile failed: $v avx"; head -5 $B/cc_${v}_avx.log; exit 1; }
  $CC $CF $PTF $SSEF $IA -o $B/${v}_sse.o     -c $K/variants/$v/ssvfilter_sse.c 2> $B/cc_${v}_sse.log     || { echo "compile failed: $v sse"; head -5 $B/cc_${v}_sse.log; exit 1; }
  $CC $CF $PTF $SSEF $IS -o $B/${v}_sseonly.o -c $K/variants/$v/ssvfilter.c     2> $B/cc_${v}_sseonly.log || { echo "compile failed: $v sse-only"; head -5 $B/cc_${v}_sseonly.log; exit 1; }
  $CC -O3 -DFOCUS_AVX -I$A/src -I$A/easel -o $B/focus_avx_$v $H/band_focus.c $B/${v}_avx.o $B/${v}_sse.o $LA || exit 1
  $CC -O3 -I$SS/src -I$SS/src/impl_sse -I$SS/easel -o $B/focus_sse_$v $H/band_focus.c $B/${v}_sseonly.o $LSS || exit 1
  $CC -O3 -I$A/src  -I$A/easel  -o $B/score_$v  $H/ssv_scores_harness.c $B/${v}_avx.o $B/${v}_sse.o $LA || exit 1
  $CC -O3 -I$SS/src -I$SS/easel -o $B/scoreS_$v $H/score_sseonly.c $B/${v}_sseonly.o $LSS || exit 1
done
cat $B/cc_*.log 2> /dev/null | grep 'warning' | sed 's/^[^:]*:[0-9:]* *//' | sort | uniq -c > $R/kernel_warnings.txt

echo "== $CC: scores against main (22,000 calls per build)"
for p in score scoreS; do for v in $VARS; do taskset -c $CORE $B/${p}_$v 2000 1 > $R/${p}_$v.txt 2> /dev/null; done
  for v in main_pragma fold pr; do echo "$([ $p = score ] && echo AVX2-build || echo SSE-only) $v: $(diff $R/${p}_main.txt $R/${p}_$v.txt | grep -c '^[<>]') of $(wc -l < $R/${p}_$v.txt) calls differ"; done; done | tee $R/scores.txt

echo "== $CC: timing bands 2 to 14, $ROUNDS rounds, core $CORE"
for r in $(seq $ROUNDS); do for v in $VARS; do : > $R/avx_${v}_r$r.txt; : > $R/sse_${v}_r$r.txt
  for w in 2 3 4 5 6 7 8 9 10 11 12 13 14; do
    taskset -c $CORE $B/focus_avx_$v $((32*w)) $LS >> $R/avx_${v}_r$r.txt
    taskset -c $CORE $B/focus_sse_$v $((16*w)) $LS >> $R/sse_${v}_r$r.txt
  done; done; done

if command -v python3 > /dev/null; then { cat $R/machine.txt; echo; python3 $K/bandtab.py $K/band_out $tag; } > $R/table.txt 2>&1; cat $R/table.txt
else echo "python3 not found: no table made; the raw files in $R are enough"; fi
echo; echo "done: results in $R"
