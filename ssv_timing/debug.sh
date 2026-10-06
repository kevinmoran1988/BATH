#!/bin/bash
# SSV kernel debug kit: locate a slow cell. Temporary; not part of any pull request.
# Read ssv_timing/HANDOFF.md first.
#
#   ssv_timing/debug.sh [core] [compiler]        default: core 2, compiler gcc-13
#
# Environment knobs:
#   VARS="main main_pragma fold fold_pragma"   kernel versions to build and time
#   EXTRA="-falign-functions=64"               extra flags for the kernel file only
#   TAG=_align64                               suffix for binaries and result files of this run
#   KERNEL=sseonly | dispatch                  SSE-only build (default), or the SSE kernel of the AVX2 build
#   MODE=filter | band                         time p7_SSVFilter() (default), or the band kernel directly
#   SWEEPS="A B"                               which sweeps to run (see below); "" builds only
#   M_A=200  L_A="1 60 1"                      sweep A: one model, sequence lengths first/last/step
#   MS_B="112 128 144 160 176 192 208 224"     sweep B: one-band models of 7..14 vectors
#   LS_B="10 13 14 20 26 27 30 40 100"         sweep B: sequence lengths
#   PERF=1                                     also run perf stat on the cell M_P x L_P (default 200 x 30)
#
# A version's kernel source is taken from ssv_timing/debug/variants/<version>/
# if that directory exists, else from ssv_timing/variants/<version>/. To try a
# source change, copy a version there under a new name, edit it, and add the
# name to VARS. Do not edit ssv_timing/variants/ in place.
#
# It reuses the build made by ssv_timing/run.sh (ssv_timing/build_<compiler>/),
# and makes it if it is missing. Results go to ssv_timing/debug_results/<compiler>/.

K=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$K/.." && pwd)
CORE=${1:-2}; CC=${2:-gcc-13}
VARS=${VARS:-"main main_pragma fold fold_pragma"}
EXTRA=${EXTRA:-}; TAG=${TAG:-}; KERNEL=${KERNEL:-sseonly}; MODE=${MODE:-filter}
SWEEPS=${SWEEPS-"A B"}
M_A=${M_A:-200}; L_A=${L_A:-"1 60 1"}
MS_B=${MS_B:-"112 128 144 160 176 192 208 224"}; LS_B=${LS_B:-"10 13 14 20 26 27 30 40 100"}
PERF=${PERF:-0}; M_P=${M_P:-200}; L_P=${L_P:-30}
H=$K/harness

command -v $CC > /dev/null || { echo "$CC not found"; exit 1; }
tag=$(echo $CC | tr -c 'A-Za-z0-9\n' '_')
B=$K/build_$tag; R=$K/debug_results/$tag; DB=$K/debug_build/$tag; mkdir -p $R $DB

# the two library builds, as in run.sh
[ -d $ROOT/easel ] || git clone -q -b BATH https://github.com/TravisWheelerLab/easel $ROOT/easel || { echo "could not clone easel"; exit 1; }
for kind in avx sse; do
  T=$B/$kind
  if [ ! -f $T/src/libhmmer.a ]; then
    echo "== $CC: building the $kind library tree"
    rm -rf $T; mkdir -p $T/easel
    git -C $ROOT archive HEAD | tar -x -C $T && git -C $ROOT/easel archive HEAD | tar -x -C $T/easel || { echo "could not copy the source tree"; exit 1; }
    ( cd $T && autoconf && ./configure CC=$CC $([ $kind = sse ] && echo --disable-avx) > $B/configure_$kind.log 2>&1 \
        && make -j$(nproc) > $B/make_$kind.log 2>&1 ) || { echo "build failed, see $B/make_$kind.log"; exit 1; }
  fi
done
A=$B/avx; SS=$B/sse
flag() { grep -m1 "^$2 *=" $1/src/Makefile | cut -d= -f2-; }
CF=$(flag $A CFLAGS); SSEF=$(flag $A SSE_CFLAGS); PTF=$(flag $A PTHREAD_CFLAGS)

src() { [ -f $K/debug/variants/$1/$2 ] && echo $K/debug/variants/$1/$2 || echo $K/variants/$1/$2; }
echo "== $CC, $KERNEL kernel, mode $MODE, extra flags: ${EXTRA:-none}${TAG:+, tag $TAG}"
for v in $VARS; do
  if [ $KERNEL = sseonly ]; then
    f=$(src $v ssvfilter.c); [ -f $f ] || { echo "no source for $v"; exit 1; }
    $CC $CF $PTF $SSEF $EXTRA -DHAVE_CONFIG_H -I$SS/easel -I$SS/src/impl_sse -I$SS/src -o $DB/${v}${TAG}_sseonly.o -c $f || exit 1
    $CC -O3 -I$SS/src -I$SS/src/impl_sse -I$SS/easel -o $DB/focus_${v}${TAG}_sseonly $H/ssv_focus.c $DB/${v}${TAG}_sseonly.o $SS/src/libhmmer.a $SS/easel/libeasel.a -lm -lpthread || exit 1
    $CC -O3 -I$SS/src -I$SS/easel -o $DB/score_${v}${TAG}_sseonly $H/score_sseonly.c $DB/${v}${TAG}_sseonly.o $SS/src/libhmmer.a $SS/easel/libeasel.a -lm -lpthread || exit 1
  else
    f=$(src $v ssvfilter_sse.c); [ -f $f ] || { echo "no source for $v"; exit 1; }
    $CC $CF $PTF $SSEF $EXTRA -DHAVE_CONFIG_H -I$A/easel -I$A/src/impl_avx -I$A/src -o $DB/${v}${TAG}_dispatch.o -c $f || exit 1
    $CC -O3 -DFOCUS_DISPATCH -I$A/src -I$A/easel -o $DB/focus_${v}${TAG}_dispatch $H/ssv_focus.c $DB/${v}${TAG}_dispatch.o $A/src/libhmmer.a $A/easel/libeasel.a -lm -lpthread || exit 1
  fi
  # the 13-vector band kernel, as text, for reading and diffing
  objdump -d --no-show-raw-insn $DB/${v}${TAG}_$KERNEL.o | awk '/<calc_band_13>:/{p=1} p&&/^$/{exit} p' > $R/asm_band13_${v}${TAG}_$KERNEL.txt
done

# scores must not change: compare each version with the first one in VARS
if [ $KERNEL = sseonly ]; then
  first=${VARS%% *}
  for v in $VARS; do taskset -c $CORE $DB/score_${v}${TAG}_sseonly 2000 1 > $R/score_${v}${TAG}.txt 2> /dev/null; done
  for v in $VARS; do [ $v = $first ] || echo "scores $v against $first: $(diff $R/score_${first}${TAG}.txt $R/score_${v}${TAG}.txt | grep -c '^[<>]') of $(wc -l < $R/score_${v}${TAG}.txt) calls differ"; done
fi

labels() { for v in $VARS; do printf "%s=%s " $v $R/$1_${v}${TAG}_${KERNEL}_$MODE.txt; done; }

for sw in $SWEEPS; do
  if [ $sw = A ]; then
    echo; echo "== sweep A: model $M_A, sequence lengths $L_A (first last step), ns per call"
    for v in $VARS; do taskset -c $CORE $DB/focus_${v}${TAG}_$KERNEL $M_A $L_A 64 $MODE > $R/A_${v}${TAG}_${KERNEL}_$MODE.txt; done
    python3 $K/debug_table.py $(labels A) | tee $R/tableA${TAG}_${KERNEL}_$MODE.txt
  fi
  if [ $sw = B ]; then
    echo; echo "== sweep B: one-band models (vectors = ceil(model/16)), ns per call"
    for v in $VARS; do : > $R/B_${v}${TAG}_${KERNEL}_$MODE.txt
      for M in $MS_B; do for L in $LS_B; do taskset -c $CORE $DB/focus_${v}${TAG}_$KERNEL $M $L $L 1 64 $MODE >> $R/B_${v}${TAG}_${KERNEL}_$MODE.txt; done; done; done
    python3 $K/debug_table.py $(labels B) | tee $R/tableB${TAG}_${KERNEL}_$MODE.txt
  fi
done

if [ "$PERF" = 1 ]; then
  echo; echo "== perf stat, model $M_P, sequence length $L_P"
  if perf stat -e cycles -- true > /dev/null 2>&1 && ! perf stat -e cycles -- true 2>&1 | grep -q 'not supported\|not counted'; then
    EV=${EV:-cycles,instructions,branches,branch-misses,L1-dcache-load-misses}
    for v in $VARS; do
      echo "-- $v"
      perf stat -e $EV -- taskset -c $CORE $DB/focus_${v}${TAG}_$KERNEL $M_P $L_P $L_P 1 64 $MODE 2>&1 | grep -vE '^$|Performance counter|seconds' | tee $R/perf_${v}${TAG}_${KERNEL}_$MODE.txt
    done
    echo "(set EV=... for other events; 'perf list' shows what this CPU offers, e.g. the ls_* and ex_ret_* groups on Zen 2)"
  else
    echo "hardware counters are not available here (perf missing, or not exposed to this kernel)"
  fi
fi
echo; echo "results in $R"
