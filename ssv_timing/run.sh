#!/bin/bash
# SSV kernel timing kit. Temporary; not part of any pull request.
#
#   ssv_timing/run.sh [core] [compiler ...]      default: first CPU this shell may use, compiler gcc
#   e.g.  ssv_timing/run.sh 2 gcc gcc-13
#   VARS="main fold_pragma mine" and ROUNDS=1 in the environment change what is timed.
#
# Builds this tree twice per compiler, as the default AVX2 build and as an
# SSE-only build, then times p7_SSVFilter() alone on one pinned core for four
# versions of the kernel:
#   main          upstream main (b401850f)
#   main_pragma   main, plus "#pragma GCC optimize (no-tree-coalesce-vars)"
#   fold          fold each step's vectors, join the running maximum once
#   pr            TravisWheelerLab/BATH#36 as it stands: fold and pragma, both for gcc only
# (variants/ also holds pr36, the first version of the PR, and fold_pragma, the
# same as pr without the compiler guard; add them with VARS=.)
# Each version is the three kernel files in variants/, compiled with the
# build's own flags and linked in front of the library. So the result does not
# depend on which commit is checked out, and nothing but the kernel differs.
#
# Needs git, make and taskset. autoconf is used if present; otherwise the
# generated configure shipped next to this script. python3 and objdump are only
# needed for the summary. A few minutes per compiler. Summaries are written to
# ssv_timing/results/table_<compiler>.txt.

K=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$K/.." && pwd)
CORE=${1:-$(taskset -cp $$ 2> /dev/null | sed 's/.*: *//; s/[,-].*//')}; CORE=${CORE:-0}; [ $# -gt 0 ] && shift
[ $# -eq 0 ] && set -- gcc
OUT=$K/results; mkdir -p $OUT
H=$K/harness
VARS=${VARS:-"main main_pragma fold pr"}     # "main" must be first: it is the reference
ROUNDS=${ROUNDS:-3}
# a version is read from debug/variants/<version>/ if that exists, else from variants/<version>/
src() { [ -f $K/debug/variants/$1/$2 ] && echo $K/debug/variants/$1/$2 || echo $K/variants/$1/$2; }

if [ ! -d $ROOT/easel ]; then
  echo "== fetching easel (branch BATH)"
  git clone -q -b BATH https://github.com/TravisWheelerLab/easel $ROOT/easel || { echo "could not clone easel into $ROOT/easel"; exit 1; }
fi

{ echo "date:     $(date)"
  echo "cpu:     $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2)"
  echo "kernel:   $(uname -r)"
  echo "tree:     $(git -C $ROOT log --oneline -1), easel $(git -C $ROOT/easel log --oneline -1)"
  echo "core:     $CORE"; } > $OUT/machine.txt

for CC in "$@"; do
  command -v $CC > /dev/null || { echo "$CC not found, skipped"; continue; }
  tag=$(echo $CC | tr -c 'A-Za-z0-9\n' '_')
  B=$K/build_$tag; R=$OUT/$tag; mkdir -p $B $R
  echo "== $CC: building (AVX2 build and SSE-only build)"
  for kind in avx sse; do
    T=$B/$kind
    if [ ! -f $T/src/libhmmer.a ]; then
      rm -rf $T; mkdir -p $T/easel
      git -C $ROOT archive HEAD | tar -x -C $T && git -C $ROOT/easel archive HEAD | tar -x -C $T/easel || { echo "could not copy the source tree"; exit 1; }
      if [ -z "${NO_AUTOCONF:-}" ] && command -v autoconf > /dev/null; then ( cd $T && autoconf ) || exit 1
      else cp $K/configure.generated $T/configure && chmod +x $T/configure; fi
      ( cd $T && ./configure CC=$CC $([ $kind = sse ] && echo --disable-avx) > $B/configure_$kind.log 2>&1 \
          && make -j${JOBS:-8} > $B/make_$kind.log 2>&1 ) || { echo "build failed, see $B/configure_$kind.log and $B/make_$kind.log"; exit 1; }
    fi
  done
  A=$B/avx; SS=$B/sse
  flag() { grep -m1 "^$2 *=" $1/src/Makefile | cut -d= -f2-; }
  CF=$(flag $A CFLAGS); AVXF=$(flag $A AVX_CFLAGS); SSEF=$(flag $A SSE_CFLAGS); PTF=$(flag $A PTHREAD_CFLAGS)
  { cat $OUT/machine.txt; echo "compiler: $($CC --version | head -1)"; echo "flags:    CFLAGS=$CF AVX_CFLAGS=$AVXF SSE_CFLAGS=$SSEF"; } > $R/machine.txt

  echo "== $CC: compiling kernel versions and benchmarks"
  IA="-DHAVE_CONFIG_H -I$A/easel -I$A/src/impl_avx -I$A/src"; IS="-DHAVE_CONFIG_H -I$SS/easel -I$SS/src/impl_sse -I$SS/src"
  LA="$A/src/libhmmer.a $A/easel/libeasel.a -lm -lpthread"; LS="$SS/src/libhmmer.a $SS/easel/libeasel.a -lm -lpthread"
  for v in $VARS; do
    $CC $CF $PTF $AVXF $IA -o $B/${v}_avx.o     -c $(src $v ssvfilter_avx.c) || exit 1
    $CC $CF $PTF $SSEF $IA -o $B/${v}_sse.o     -c $(src $v ssvfilter_sse.c) || exit 1
    $CC $CF $PTF $SSEF $IS -o $B/${v}_sseonly.o -c $(src $v ssvfilter.c)     || exit 1
    $CC -O3 -I$A/src  -I$A/easel  -o $B/grid_$v   $H/ssv_grid_harness.c   $B/${v}_avx.o $B/${v}_sse.o $LA || exit 1
    $CC -O3 -I$A/src  -I$A/easel  -o $B/score_$v  $H/ssv_scores_harness.c $B/${v}_avx.o $B/${v}_sse.o $LA || exit 1
    $CC -O3 -I$SS/src -I$SS/easel -o $B/gridS_$v  $H/grid_sseonly.c       $B/${v}_sseonly.o $LS || exit 1
    $CC -O3 -I$SS/src -I$SS/easel -o $B/scoreS_$v $H/score_sseonly.c      $B/${v}_sseonly.o $LS || exit 1
  done
  $CC -O2 -mavx2 -o $B/lat $H/lat.c && { echo "chained vector operations on this CPU (1 cycle on most, 2 on Zen 5):"; taskset -c $CORE $B/lat; } > $R/latency.txt

  echo "== $CC: scores against main (22,000 calls per build)"
  for p in score scoreS; do
    for v in $VARS; do taskset -c $CORE $B/${p}_$v 2000 1 > $R/${p}_$v.txt 2> /dev/null; done
    for v in ${VARS#main }; do
      echo "$([ $p = score ] && echo 'AVX2 build' || echo 'SSE-only build') $v: $(diff $R/${p}_main.txt $R/${p}_$v.txt | grep -c '^[<>]') of $(wc -l < $R/${p}_$v.txt) calls differ"
    done
  done | tee $R/scores.txt

  echo "== $CC: timing, $ROUNDS rounds, core $CORE"
  for r in $(seq $ROUNDS); do for v in $VARS; do
    taskset -c $CORE $B/grid_$v  > $R/d_${v}_r$r.txt
    taskset -c $CORE $B/gridS_$v > $R/s_${v}_r$r.txt
  done; done

  command -v python3 > /dev/null || { echo "python3 not found: no summary made; the raw files in $R are enough"; continue; }
  { cat $R/machine.txt; echo; cat $R/latency.txt; echo; cat $R/scores.txt; echo
    python3 $K/table.py $R $ROUNDS $VARS
    echo "vector stack stores+loads per step, in each step loop, by band width (w)"
    echo "-- AVX2 kernel"
    python3 $H/spill2.py $(for v in $VARS; do printf "%s=%s " $v $B/${v}_avx.o; done)
    echo "-- SSE-only build"
    python3 $H/spill2.py $(for v in $VARS; do printf "%s=%s " $v $B/${v}_sseonly.o; done)
  } > $OUT/table_$tag.txt 2>&1
  echo; cat $OUT/table_$tag.txt
done
echo; echo "done: summaries are $OUT/table_*.txt"
