#!/usr/bin/env bash
# phase-all.sh — build a repo-wide test-impact index across modules.
#
# For each module it (optionally) runs the per-test coverage run, then
# extracts the static graph + config refs and builds the per-module index.
# Finally it merges every per-module index into a single
# root impact-index.sqlite (the artifact a CI job would publish).
#
# Usage:
#   tools/test-graph/phase-all.sh [options]
#
# Options:
#   --run-tests        run `mvn ... -Ptest-class-graph test` per module (default)
#   --skip-tests       reuse existing target/per-test/*.exec files
#   --it               also run integration tests (mvn verify, failsafe)
#   --modules "a b c"  explicit module list (default: every dspace-* module
#                      with a pom.xml except dspace-test-trace)
#   --root <dir>       repo root passed to `config` for cross-module config scan
#   --out <file>       root index output (default: target/test-graph/root-index.sqlite)
#   --mvn <cmd>        maven command (default: mvn, or set MVN env)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

RUN_TESTS=1
RUN_IT=0
MODULES=""
ROOT_ARG=""
OUT="$REPO/target/test-graph/root-index.sqlite"
MVN="${MVN:-mvn}"
OFFLINE=""   # CI runs online; pass --offline to reuse a local ~/.m2 cache

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-tests) RUN_TESTS=1 ;;
    --skip-tests) RUN_TESTS=0 ;;
    --it) RUN_IT=1 ;;
    --modules) MODULES="$2"; shift ;;
    --root) ROOT_ARG="--root $2"; shift ;;
    --out) OUT="$2"; shift ;;
    --mvn) MVN="$2"; shift ;;
    --offline) OFFLINE="-o" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -z "$MODULES" ]]; then
  MODULES=$(for d in "$REPO"/dspace-*; do
    [[ -f "$d/pom.xml" && "$d" != *dspace-test-trace ]] && echo "$(basename "$d")"
  done)
fi

TG="$REPO/tools/test-graph/run.sh"
DBS=()

for M in $MODULES; do
  echo "=================================================================="
  echo "MODULE: $M"
  echo "=================================================================="
  if [[ "$RUN_TESTS" -eq 1 ]]; then
    GOAL=test
    [[ "$RUN_IT" -eq 1 ]] && GOAL=verify
    echo ">> mvn -pl $M -Ptest-class-graph -DskipUnitTests=false ${RUN_IT:+-DskipIntegrationTests=false} $GOAL"
    "$MVN" $OFFLINE -pl "$M" -Ptest-class-graph -DskipUnitTests=false \
      ${RUN_IT:+-DskipIntegrationTests=false} "$GOAL" > "/tmp/phase-all-$M.log" 2>&1 \
      || { echo "!! $M tests failed (see /tmp/phase-all-$M.log)"; continue; }
  fi
  # static graph + config refs + per-module index
  "$TG" static   --module "$M"
  "$TG" config   --module "$M" $ROOT_ARG
  "$TG" build    --module "$M"
  DB="$REPO/$M/target/test-graph/impact-index.sqlite"
  if [[ -f "$DB" ]]; then
    DBS+=("$DB")
  else
    echo "!! $M produced no index, skipping from aggregate"
  fi
done

echo "=================================================================="
echo "AGGREGATE (${#DBS[@]} module indexes)"
echo "=================================================================="
ARGS=()
i=1
for DB in "${DBS[@]}"; do
  if [[ $i -eq 1 ]]; then ARGS+=(--db "$DB"); else ARGS+=(--db$i "$DB"); fi
  i=$((i+1))
done
"$TG" aggregate --out "$OUT" "${ARGS[@]}"
echo
echo "Root impact index: $OUT"
