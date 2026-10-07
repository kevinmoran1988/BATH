#!/bin/bash
# "make check" on TravisWheelerLab/BATH#36 as it stands, for one compiler, as an
# AVX2 build and as an SSE-only build. Temporary; not part of any pull request.
#
#   ssv_timing/check.sh [compiler]        default: gcc
#
# The tree checked out here plus the three kernel files in variants/pr/.
# Results: ssv_timing/check_out/<compiler>/summary.txt
K=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$K/.." && pwd); CC=${1:-gcc}
command -v $CC > /dev/null || { echo "$CC not found"; exit 1; }
[ -d $ROOT/easel ] || { echo "no easel in $ROOT:  git clone -b BATH https://github.com/TravisWheelerLab/easel $ROOT/easel"; exit 1; }
tag=$(echo ${TAG:-$CC} | tr -c 'A-Za-z0-9.\n' '_'); B=$K/check_build_$tag; R=$K/check_out/$tag; mkdir -p $B $R
echo "compiler: $($CC --version | head -1)" > $R/summary.txt
rc=0
for kind in avx sse; do T=$B/$kind
  echo "== $CC: $kind build and make check"
  rm -rf $T; mkdir -p $T/easel
  git -C $ROOT archive HEAD | tar -x -C $T || exit 1
  if git -C $ROOT/easel rev-parse HEAD > /dev/null 2>&1; then git -C $ROOT/easel archive HEAD | tar -x -C $T/easel; else cp -r $ROOT/easel/. $T/easel/; fi
  cp $K/variants/pr/ssvfilter_avx.c $K/variants/pr/ssvfilter_sse.c $T/src/impl_avx/ && cp $K/variants/pr/ssvfilter.c $T/src/impl_sse/ssvfilter.c || exit 1
  if [ -z "${NO_AUTOCONF:-}" ] && command -v autoconf > /dev/null; then ( cd $T && autoconf ) || exit 1
  else cp $K/configure.generated $T/configure && chmod +x $T/configure; fi
  if ( cd $T && ./configure CC=$CC $([ $kind = sse ] && echo --disable-avx) > $R/configure_$kind.log 2>&1 && make -j${JOBS:-8} > $R/make_$kind.log 2>&1 ); then
    ( cd $T && make check > $R/check_$kind.log 2>&1 ); c=$?
    echo "$kind: make check exit $c; $(grep -E 'exercises at level' $R/check_$kind.log | tr '\n' ' ')" | tee -a $R/summary.txt
    grep -E 'FAIL|\[fail' $R/check_$kind.log | head -10 >> $R/summary.txt
    [ $c -eq 0 ] || rc=1
  else echo "$kind: BUILD FAILED, see $R/make_$kind.log" | tee -a $R/summary.txt; tail -5 $R/make_$kind.log >> $R/summary.txt; rc=1; fi
done
exit $rc
