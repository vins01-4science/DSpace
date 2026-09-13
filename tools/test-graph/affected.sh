#!/usr/bin/env bash
# affected.sh — given the baseline impact index and a git diff (base...head),
# compute the tests that must be re-run, split into unit vs integration tests.
#
# Output (written to --out <dir>, default target/test-graph/affected):
#   ut.csv      comma-separated simple UT class names
#   it.csv      comma-separated simple IT class names
#
# Usage:
#   tools/test-graph/affected.sh --db <index.sqlite> --base <sha> [--head <sha>] [--out <dir>]
#
# Non-Spring XML config changes are routed through `refine --configfile` for method-level
# precision (refine reads the per-class line coverage straight from the index; when the index
# has no coverage it degrades to the class-level `impacted --configfile` set). No per-test
# .exec dir or compiled classes dir are needed.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

DB=""
BASE=""
HEAD="HEAD"
OUT_DIR="$REPO/target/test-graph/affected"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)   DB="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --head) HEAD="$2"; shift 2 ;;
    --out)  OUT_DIR="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$DB" || -z "$BASE" ]]; then
  echo "Usage: affected.sh --db <index> --base <sha> [--head <sha>] [--out <dir>]" >&2
  exit 2
fi

TG="$REPO/tools/test-graph/run.sh"
mkdir -p "$OUT_DIR"

# The three-dot diff below already diffs from the merge-base, so a PR whose base
# branch advanced after the fork point (a normal stale PR) is handled correctly.
# Only unrelated histories are an error; a moved base tip is a loud warning, not
# a hard failure (failing here turned every stale PR red — round-2 finding).
MB="$(git merge-base "$BASE" "$HEAD" 2>/dev/null)" || {
  echo "!! --base $BASE and --head $HEAD have no common ancestor — refusing to diff" >&2
  exit 1
}
if [ "$MB" != "$BASE" ]; then
  echo "!! note: --base $BASE is not an ancestor of --head $HEAD (baseline tip moved); diffing from merge-base $MB" >&2
fi
if ! DIFF_LIST="$(git diff --name-only --diff-filter=ADMR "$BASE...$HEAD" 2>&1)"; then
  echo "!! git diff $BASE...$HEAD failed: $DIFF_LIST" >&2
  exit 1
fi
mapfile -t FILES <<< "$DIFF_LIST"

is_java_src()  { [[ "$1" == */src/main/java/*.java || "$1" == */src/test/java/*.java ]]; }
is_test_file() { [[ "$1" == */src/test/java/*.java ]]; }
is_cfg()       { [[ "$1" == *.cfg || "$1" == *.properties || "$1" == *.yml || "$1" == *.yaml ]]; }
is_bean_xml()  { [[ "$1" == */spring/*.xml || "$1" == *-services.xml || "$1" == *-beans.xml ]]; }

class_from_file() {
  local rel
  rel="$(echo "$1" | sed -E 's#.*/src/(main|test)/java/##; s#\.java$##')"
  echo "${rel//\//.}"
}
is_it_class() {
  [[ "$1" == IT* || "$1" == *IT || "$1" == *ITCase ]]
}

declare -A ALL=()
# Changed/added test files are tracked by their bare FQCN: the tool emits
# `Class.method`, but a changed test's own class has no method attached, so it
# must NOT go through the method-stripping below (F3: stripping the last segment
# of a bare FQCN reduced `...NewFeatureTest` to its package and the new test
# never ran). A file may also appear in ALL via the lookup; sort -u dedupes.
declare -A TESTFILE=()
ERR_LOG="$OUT_DIR/impacted.err"
: > "$ERR_LOG"

impacted_for() { # args... -> feed stdout into the caller's read loop
  if ! "$TG" "$@" 2>>"$ERR_LOG"; then
    echo "!! $TG $* FAILED (see $ERR_LOG)" >&2
  fi
}

BAD_LINES=0
add_line() { # accept only class / class.method tokens; anything else = tool misbehavior
  local t="$1"
  [[ -z "$t" ]] && return 0
  if [[ "$t" =~ ^[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z0-9_$]+)*$ ]]; then
    ALL["$t"]=1
  else
    echo "!! ignoring non-test line from test-graph tool: '$t'" >&2
    BAD_LINES=1
  fi
}

for f in "${FILES[@]:-}"; do
  [[ -z "$f" ]] && continue
  if is_java_src "$f"; then
    if is_test_file "$f"; then
      TESTFILE["$(class_from_file "$f")"]=1   # bare FQCN, no method
    fi
    while IFS= read -r t; do
      add_line "$t"
    done < <(impacted_for impacted --csv --db "$DB" --file "$REPO/$f")
  elif is_cfg "$f"; then
    while IFS= read -r t; do
      add_line "$t"
    done < <(impacted_for impacted --csv --db "$DB" --configfile "$REPO/$f")
  elif is_bean_xml "$f"; then
    while IFS= read -r t; do
      add_line "$t"
    done < <(impacted_for impacted --csv --db "$DB" --beanfile "$REPO/$f")
  elif [[ "$f" == *.xml ]]; then
    # non-spring XML metadata/form config (submission-forms.xml, item-submission.xml,
    # dspace/config/registries/*.xml) — mapped to tests via the curated consumer-class map.
    # Method-level `refine --configfile` reads line coverage straight from the index and
    # degrades to the class-level `impacted --configfile` set when coverage is absent.
    while IFS= read -r t; do
      add_line "$t"
    done < <(impacted_for refine --csv --db "$DB" --configfile "$REPO/$f" \
                    --base "$BASE" --head "$HEAD")
  fi
done

if [ -s "$ERR_LOG" ]; then
  echo "!! test-graph tool emitted errors during impacted lookup (starting with):" >&2
  sed -n '1,10p' "$ERR_LOG" >&2
  echo "!! refusing to emit a possibly incomplete affected set" >&2
  exit 1
fi
if [ "$BAD_LINES" -ne 0 ]; then
  echo "!! test-graph tool emitted non-test output — affected set is not trustworthy" >&2
  exit 1
fi

UT=()
IT=()
add_class() { # $1 = FQCN or Class.method; classify by simple class name
  local simple="${1##*.}"
  if is_it_class "$simple"; then IT+=("$simple"); else UT+=("$simple"); fi
}
# Tool output is Class.method -> drop the method. Changed test files are bare
# FQCNs -> use as-is (the two are disjoint by construction; sort -u dedupes).
for t in "${!ALL[@]}";      do add_class "${t%.*}"; done
for c in "${!TESTFILE[@]}"; do add_class "$c";       done

: > "$OUT_DIR/ut.csv"
: > "$OUT_DIR/it.csv"
if ((${#UT[@]}));  then printf '%s\n' "${UT[@]}"  | sort -u | paste -sd, - > "$OUT_DIR/ut.csv";  fi
if ((${#IT[@]}));  then printf '%s\n' "${IT[@]}"  | sort -u | paste -sd, - > "$OUT_DIR/it.csv";  fi

echo "affected: ${#ALL[@]} tests (UT=$(< "$OUT_DIR/ut.csv" tr ',' '\n' | grep -c .) IT=$(< "$OUT_DIR/it.csv" tr ',' '\n' | grep -c .))"
echo "  UT_CSV : $(cat "$OUT_DIR/ut.csv")"
echo "  IT_CSV : $(cat "$OUT_DIR/it.csv")"
