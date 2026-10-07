#!/bin/bash
# Grid test, per-band test and "make check" for one compiler, then one archive
# of the results.
# Temporary; not part of any pull request.
#
#   ssv_timing/both.sh [compiler]         default: gcc
#
# Run it on a quiet machine: on a cluster, inside a job on a compute node. easel
# must already be in the tree if the node has no network:
#   git clone -b BATH https://github.com/TravisWheelerLab/easel
# About 20 minutes. Leaves ssv_results_<host>_<compiler>.tgz in the top directory.
K=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$K/.." && pwd); CC=${1:-gcc}
CORE=$(taskset -cp $$ 2> /dev/null | sed 's/.*: *//; s/[,-].*//'); CORE=${CORE:-0}
$K/run.sh $CORE $CC   || { echo "grid test failed"; exit 1; }
$K/bands.sh $CC $CORE || { echo "per-band test failed"; exit 1; }
$K/check.sh $CC       || echo "make check did not pass; see ssv_timing/check_out"
out=ssv_results_$(hostname -s)_$(echo $CC | tr -c 'A-Za-z0-9.\n' '_').tgz
( cd $ROOT && tar czf $out ssv_timing/results ssv_timing/band_out ssv_timing/check_out ) && echo && echo "all done: $ROOT/$out"
