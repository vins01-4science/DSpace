#!/usr/bin/env bash
# affected.sh — given the baseline impact index and a git diff (base...head),
# compute the tests that must be re-run, split into unit vs integration tests,
# and the touched modules (for the fallback path).
#
# Output (written to --out <dir>, default target/test-graph/affected):
#   ut.csv      comma-separated simple UT class names
#   it.csv      comma-separated simple IT class names
#   modules.txt newline-separated touched module dirs (first path component)
#
# Usage:
#   tools/test-graph/affected.sh --db <index.sqlite> --base <sha> [--head <sha>] [--out <dir>]
#                                  [--per-test <dir>] [--classes <dir>]
#
# When --per-test (per-test JaCoCo .exec dir) and --classes (compiled classes dir) are given,
# non-Spring XML config changes are routed through `refine --configfile` for method-level
# precision instead of the class-level `impacted --configfile` fallback.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

DB=""
BASE=""
HEAD="HEAD"
OUT_DIR="$REPO/target/test-graph/affected"
PER_TEST=""
CLASSES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)   DB="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --head) HEAD="$2"; shift 2 ;;
    --out)  OUT_DIR="$2"; shift 2 ;;
    --per-test) PER_TEST="$2"; shift 2 ;;
    --classes)  CLASSES="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$DB" || -z "$BASE" ]]; then
  echo "Usage: affected.sh --db <index> --base <sha> [--head <sha>] [--out <dir>] [--per-test <dir>] [--classes <dir>]" >&2
  exit 2
fi

TG="$REPO/tools/test-graph/run.sh"
mkdir -p "$OUT_DIR"

mapfile -t FILES < <(git diff --name-only --diff-filter=ADMR "$BASE...$HEAD" 2>/dev/null || true)

is_java_src()  { [[ "$1" == */src/main/java/*.java || "$1" == */src/test/java/*.java ]]; }
is_test_file() { [[ "$1" == */src/test/java/*.java ]]; }
is_cfg()       { [[ "$1" == *.cfg || "$1" == *.properties || "$1" == *.yml || "$1" == *.yaml ]]; }
is_bean_xml()  { [[ "$1" == */spring/*.xml || "$1" == *-services.xml || "$1" == *-beans.xml ]]; }

module_of()    { echo "$1" | cut -d/ -f1; }
class_from_file() {
  local rel
  rel="$(echo "$1" | sed -E 's#.*/src/(main|test)/java/##; s#\.java$##')"
  echo "${rel//\//.}"
}
is_it_class() {
  [[ "$1" == IT* || "$1" == *IT || "$1" == *ITCase ]]
}

declare -A ALL=()
declare -A MODS=()

for f in "${FILES[@]:-}"; do
  [[ -z "$f" ]] && continue
  MODS["$(module_of "$f")"]=1
  if is_java_src "$f"; then
    if is_test_file "$f"; then
      ALL["$(class_from_file "$f")"]=1   # a changed test must re-run itself
    fi
    while IFS= read -r t; do
      [[ -n "$t" ]] && ALL["$t"]=1
    done < <("$TG" impacted --csv --db "$DB" --file "$REPO/$f" 2>/dev/null || true)
  elif is_cfg "$f"; then
    while IFS= read -r t; do
      [[ -n "$t" ]] && ALL["$t"]=1
    done < <("$TG" impacted --csv --db "$DB" --configfile "$REPO/$f" 2>/dev/null || true)
  elif is_bean_xml "$f"; then
    while IFS= read -r t; do
      [[ -n "$t" ]] && ALL["$t"]=1
    done < <("$TG" impacted --csv --db "$DB" --beanfile "$REPO/$f" 2>/dev/null || true)
  elif [[ "$f" == *.xml ]]; then
    # non-spring XML metadata/form config (submission-forms.xml, item-submission.xml,
    # dspace/config/registries/*.xml) — mapped to tests via the curated consumer-class map.
    # With coverage available, use method-level `refine --configfile` (precise); otherwise
    # the class-level `impacted --configfile` fallback.
    if [[ -n "$PER_TEST" && -n "$CLASSES" ]]; then
      while IFS= read -r t; do
        [[ -n "$t" ]] && ALL["$t"]=1
      done < <("$TG" refine --csv --db "$DB" --configfile "$REPO/$f" \
                     --base "$BASE" --head "$HEAD" --per-test "$PER_TEST" --classes "$CLASSES" 2>/dev/null || true)
    else
      while IFS= read -r t; do
        [[ -n "$t" ]] && ALL["$t"]=1
      done < <("$TG" impacted --csv --db "$DB" --configfile "$REPO/$f" 2>/dev/null || true)
    fi
  fi
done

UT=()
IT=()
for t in "${!ALL[@]}"; do
  cls="${t%.*}"            # drop the method name
  simple="${cls##*.}"
  if is_it_class "$simple"; then IT+=("$simple"); else UT+=("$simple"); fi
done

: > "$OUT_DIR/ut.csv"
: > "$OUT_DIR/it.csv"
: > "$OUT_DIR/modules.txt"
if ((${#UT[@]}));  then printf '%s\n' "${UT[@]}"  | sort -u | paste -sd, - > "$OUT_DIR/ut.csv";  fi
if ((${#IT[@]}));  then printf '%s\n' "${IT[@]}"  | sort -u | paste -sd, - > "$OUT_DIR/it.csv";  fi
if ((${#MODS[@]})); then printf '%s\n' "${!MODS[@]}" | sort -u > "$OUT_DIR/modules.txt"; fi

echo "affected: ${#ALL[@]} tests (UT=$(< "$OUT_DIR/ut.csv" tr ',' '\n' | grep -c .) IT=$(< "$OUT_DIR/it.csv" tr ',' '\n' | grep -c .)) across $(grep -c . "$OUT_DIR/modules.txt") modules"
echo "  UT_CSV : $(cat "$OUT_DIR/ut.csv")"
echo "  IT_CSV : $(cat "$OUT_DIR/it.csv")"
echo "  MODULES: $(paste -sd, - < "$OUT_DIR/modules.txt")"
