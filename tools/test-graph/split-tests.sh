#!/usr/bin/env bash
# split-tests.sh - enumerate a module's test classes and split them into N
# roughly-equal shard files (UT vs IT separated), for parallel test execution.
#
# Usage:
#   split-tests.sh --module <dir> --total <N> [--out <dir>]
#
# Writes (under <module>/target/test-graph unless --out given):
#   shard-<i>-ut.txt   FQCNs of unit-test classes for shard i (0-based)
#   shard-<i>-it.txt   FQCNs of integration-test classes for shard i
#
# The UT/IT classification mirrors Surefire/Failsafe default includes so that
# `-Dtest=@shard-ut.txt` (Surefire) and `-Dit.test=@shard-it.txt` (Failsafe)
# select exactly the listed classes.
set -euo pipefail

MODULE=""
TOTAL=1
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --module) MODULE="$2"; shift 2 ;;
    --total)  TOTAL="$2"; shift 2 ;;
    --out)    OUT="$2"; shift 2 ;;
    *) echo "split-tests.sh: unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$MODULE" ]] || { echo "split-tests.sh: --module required" >&2; exit 2; }
[[ "$TOTAL" -ge 1 ]] || { echo "split-tests.sh: --total must be >= 1" >&2; exit 2; }

SRC="$MODULE/src/test/java"
OUT_DIR="${OUT:-$MODULE/target/test-graph}"
mkdir -p "$OUT_DIR"

# Create the (possibly empty) shard files up front so every shard has a file
# to pass to -Dtest, even when it ends up with zero classes of that kind.
for ((i=0; i<TOTAL; i++)); do
  : > "$OUT_DIR/shard-$i-ut.txt"
  : > "$OUT_DIR/shard-$i-it.txt"
done

is_ut() { [[ "$1" == *Test || "$1" == Test* || "$1" == *Tests || "$1" == *TestCase ]]; }
is_it() { [[ "$1" == IT* || "$1" == *IT || "$1" == *ITCase ]]; }

UT=()
IT=()
if [[ -d "$SRC" ]]; then
  while IFS= read -r f; do
    base="$(basename "$f" .java)"
    [[ "$base" == *\$* ]] && continue   # inner / anonymous classes
    [[ "$base" == Abstract* ]] && continue  # base classes, not runnable
    rel="${f#"$SRC"/}"; rel="${rel%.java}"; fqcn="${rel//\//.}"
    if is_it "$base"; then IT+=("$fqcn")
    elif is_ut "$base"; then UT+=("$fqcn")
    fi
  done < <(find "$SRC" -name '*.java' -type f)
fi

# Round-robin assignment into shards.
i=0
for c in "${UT[@]:-}"; do
  [[ -z "$c" ]] && continue
  echo "$c" >> "$OUT_DIR/shard-$((i % TOTAL))-ut.txt"
  i=$((i+1))
done
i=0
for c in "${IT[@]:-}"; do
  [[ -z "$c" ]] && continue
  echo "$c" >> "$OUT_DIR/shard-$((i % TOTAL))-it.txt"
  i=$((i+1))
done

echo "split-tests: module=$MODULE total=$TOTAL -> ${#UT[@]} UT, ${#IT[@]} IT classes"
for ((i=0; i<TOTAL; i++)); do
  u=$(grep -c . "$OUT_DIR/shard-$i-ut.txt" 2>/dev/null || echo 0)
  t=$(grep -c . "$OUT_DIR/shard-$i-it.txt" 2>/dev/null || echo 0)
  echo "  shard $i: ut=$u it=$t"
done
