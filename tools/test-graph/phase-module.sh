#!/usr/bin/env bash
# phase-module.sh - build a PARTIAL test-impact index for one module + one
# shard, for later merging with `aggregate`.
#
# Unlike phase-all.sh (which runs a module's full suite sequentially), this
# script scopes the tests to a single shard (a subset of test classes) so the
# work can be spread across parallel CI workers. Each invocation produces one
# partial `impact-index.sqlite` containing only the coverage observed while
# running that shard's tests; `aggregate` unions all partials into the
# repository-wide index.
#
# Usage:
#   phase-module.sh <module> [--shard <N> <TOTAL>] [--tests <ut-csv> <it-csv>] [--it] [--root <dir>] [--db-out <file>]
#
#   <module>      Maven module directory (e.g. dspace-api)
#   --shard N TOTAL   Run only shard N (1-based) of TOTAL, via split-tests.sh
#   --tests U I       Run an explicit affected-test subset (comma-separated simple
#                     class names; merge-patch mode — bypasses split-tests)
#   --skip-tests      Skip the test-run phase entirely (delta partial build:
#                     static + config + index from existing target/per-test execs)
#   --it           Also run integration tests (Failsafe) for the shard/subset
#   --root <dir>   Repo root, passed to the `config` step (for cross-module refs)
#   --db-out <file>   Where to write the partial index (default module/target/...)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

MODULE="${1:?phase-module.sh: module required}"
shift
SHARD=""
TOTAL=""
RUN_IT=0
ROOT_ARG=""
DB_OUT=""
UT_LIST=""
IT_LIST=""
SKIP_TESTS=0
MVN="${MVN:-mvn}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shard)  SHARD="$2"; TOTAL="$3"; shift 3 ;;
    --tests)  UT_LIST="$2"; IT_LIST="$3"; shift 3 ;;
    --skip-tests) SKIP_TESTS=1; shift ;;
    --it)     RUN_IT=1; shift ;;
    --root)   ROOT_ARG="--root $2"; shift 2 ;;
    --db-out) DB_OUT="$2"; shift 2 ;;
    *) echo "phase-module.sh: unknown option: $1" >&2; exit 2 ;;
  esac
done

TG="$REPO/tools/test-graph/run.sh"
PER_TEST="$REPO/$MODULE/target/per-test"

# 1) Static class graph + config/property/bean refs (module-wide; identical for
#    every shard of this module, so the merged graph is unaffected by sharding).
"$TG" static  --module "$MODULE"
"$TG" config  --module "$MODULE" $ROOT_ARG

# 2) Run this shard's tests with the test-class-graph profile (JaCoCo agent +
#    PerTestCoverage listener). Start from a clean per-test dir so the produced
#    .exec files belong to THIS shard only (critical for correct partial index).
#    --skip-tests (merge-patch delta build) preserves the .exec files written
#    by an earlier step and goes straight to the index build.
[[ "$SKIP_TESTS" -eq 0 ]] && rm -rf "$PER_TEST"

if [[ "$SKIP_TESTS" -eq 1 ]]; then
  : # per-test execs already present; build the delta partial below
elif [[ -n "$UT_LIST" || -n "$IT_LIST" ]]; then
  # Explicit affected-test subset (merge-patch mode): run ONLY these tests and
  # let `build` produce a delta partial whose coverage is absent for everything
  # else. Aggregating it into the existing baseline refreshes just those classes.
  if [[ -n "$UT_LIST" ]]; then
    "$MVN" -pl "$MODULE" -Ptest-class-graph -DskipUnitTests=false -DskipIntegrationTests=true \
      test "-Dtest=$UT_LIST" \
      || echo "!! unit tests failed for $MODULE (continuing to build partial index)"
  fi
  if [[ "$RUN_IT" -eq 1 && -n "$IT_LIST" ]]; then
    "$MVN" -pl "$MODULE" -Ptest-class-graph -DskipUnitTests=true -DskipIntegrationTests=false \
      verify "-Dit.test=$IT_LIST" \
      || echo "!! integration tests failed for $MODULE (continuing)"
  fi
elif [[ -n "$SHARD" && -n "$TOTAL" ]]; then
  bash "$REPO/tools/test-graph/split-tests.sh" --module "$MODULE" --total "$TOTAL"
  # Pass the test list inline (comma-separated FQCNs). Surefire/Failsafe's
  # `-Dtest=@file` form is unreliable in this build, but an inline `-Dtest`
  # list works from any CWD, so we build it from the shard file.
  UT_REL="target/test-graph/shard-$((SHARD-1))-ut.txt"
  IT_REL="target/test-graph/shard-$((SHARD-1))-it.txt"
  if [[ -s "$MODULE/$UT_REL" ]]; then
    UT_LIST="$(paste -sd, "$MODULE/$UT_REL")"
    "$MVN" -pl "$MODULE" -Ptest-class-graph -DskipUnitTests=false -DskipIntegrationTests=true \
      test "-Dtest=$UT_LIST" \
      || echo "!! unit tests failed for $MODULE shard $SHARD (continuing to build partial index)"
  fi
  if [[ "$RUN_IT" -eq 1 && -s "$MODULE/$IT_REL" ]]; then
    IT_LIST="$(paste -sd, "$MODULE/$IT_REL")"
    "$MVN" -pl "$MODULE" -Ptest-class-graph -DskipUnitTests=true -DskipIntegrationTests=false \
      verify "-Dit.test=$IT_LIST" \
      || echo "!! integration tests failed for $MODULE shard $SHARD (continuing)"
  fi
else
  if [[ "$RUN_IT" -eq 1 ]]; then
    "$MVN" -pl "$MODULE" -Ptest-class-graph -DskipUnitTests=false -DskipIntegrationTests=false \
      verify \
      || echo "!! tests failed for $MODULE (continuing to build partial index)"
  else
    "$MVN" -pl "$MODULE" -Ptest-class-graph -DskipUnitTests=false -DskipIntegrationTests=true \
      test \
      || echo "!! tests failed for $MODULE (continuing to build partial index)"
  fi
fi

# 3) Build the partial index from only this shard's per-test .exec files.
DB="${DB_OUT:-$REPO/$MODULE/target/test-graph/impact-index.sqlite}"
"$TG" build --module "$MODULE" --per-test "$PER_TEST" \
    --classes "$REPO/$MODULE/target/classes:$REPO/$MODULE/target/test-classes" --db "$DB"
echo "phase-module: wrote $DB"
