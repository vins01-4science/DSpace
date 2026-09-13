#!/usr/bin/env bash
# Local, network-free harness for the round-3 pipeline fixes.
#
#   F3  affected.sh classifies a changed/added test file by its bare FQCN
#       (NewFeatureTest -> ut.csv, FooIT -> it.csv), not by a stripped package.
#   F5  run.sh reports a missing required jar with a friendly error and exit 1
#       instead of aborting silently under `set -e`.
#   F6  the zero-report backstop extracted from test-affected.yml exits 1 when
#       tests were selected but no surefire/failsafe report exists.
#
# Usage: tools/test-graph/tests/run-local-checks.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TG="$ROOT/tools/test-graph"
AFFECTED_YML="$ROOT/.github/workflows/test-affected.yml"

FAIL=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
newtmp() { local d; d="$(mktemp -d)"; TMPDIRS+=("$d"); echo "$d"; }

# ---------------------------------------------------------------------------
# F3 — affected.sh test-file provenance
# ---------------------------------------------------------------------------
f3() {
  local dir stub base head out ut it
  dir="$(newtmp)"
  mkdir -p "$dir/tools/test-graph"
  cp "$TG/affected.sh" "$dir/tools/test-graph/affected.sh"
  # Stub the Java tool: the changed test file must be classified from the diff
  # alone, so the tool contributes nothing.
  cat > "$dir/tools/test-graph/run.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$dir/tools/test-graph/run.sh"

  (
    cd "$dir" || exit 1
    git init -q .
    git config user.email t@t.t; git config user.name t
    mkdir -p dspace-api/src/test/java/org/dspace/impact
    printf 'base\n' > dspace-api/README
    git add -A && git commit -qm base
    base="$(git rev-parse HEAD)"
    printf 'package org.dspace.impact;\npublic class NewFeatureTest {}\n' \
      > dspace-api/src/test/java/org/dspace/impact/NewFeatureTest.java
    printf 'package org.dspace.impact;\npublic class FooIT {}\n' \
      > dspace-api/src/test/java/org/dspace/impact/FooIT.java
    git add -A && git commit -qm add
    head="$(git rev-parse HEAD)"
    bash tools/test-graph/affected.sh --db /dev/null --base "$base" --head "$head" \
      --out "$dir/out" >/dev/null 2>&1
  ) || { fail "F3 affected.sh run crashed"; return; }

  ut="$(cat "$dir/out/ut.csv" 2>/dev/null || true)"
  it="$(cat "$dir/out/it.csv" 2>/dev/null || true)"
  if [ "$ut" = "NewFeatureTest" ] && [ "$it" = "FooIT" ]; then
    pass "F3 NewFeatureTest -> ut.csv, FooIT -> it.csv"
  else
    fail "F3 classification (ut='$ut' it='$it'; want ut=NewFeatureTest it=FooIT)"
  fi
}

# ---------------------------------------------------------------------------
# F5 — run.sh friendly error on a missing ~/.m2
# ---------------------------------------------------------------------------
f5() {
  local dir out rc
  dir="$(newtmp)"
  out="$(M2="$dir/nope" bash "$TG/run.sh" validate --db /dev/null 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'ERROR: missing a required jar'; then
    pass "F5 run.sh prints missing-jar error and exits 1"
  else
    fail "F5 run.sh (rc=$rc; out=$out)"
  fi
}

# ---------------------------------------------------------------------------
# F6 — zero-report backstop (extracted from the real workflow)
# ---------------------------------------------------------------------------
extract_backstop() {
  awk '
    /^[[:space:]]*RAN=\$\(find \. -path/ { f=1 }
    f { print }
    f && /^[[:space:]]*fi[[:space:]]*$/ { exit }
  ' "$AFFECTED_YML"
}

f6() {
  local backstop zdir pdir out rc
  backstop="$(extract_backstop)"
  if [ -z "$backstop" ]; then fail "F6 could not extract backstop from workflow"; return; fi

  # negative: UT selected, no reports -> must fail
  zdir="$(newtmp)"
  out="$(cd "$zdir" && UT_CSV=x eval "$backstop" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'NO surefire/failsafe reports'; then
    pass "F6 zero-report backstop fails loud (exit 1)"
  else
    fail "F6 backstop (rc=$rc; out=$out)"
  fi

  # positive: a report exists -> must pass
  pdir="$(newtmp)"
  mkdir -p "$pdir/dspace-api/target/surefire-reports"
  : > "$pdir/dspace-api/target/surefire-reports/TEST-X.xml"
  ( cd "$pdir" && UT_CSV=x eval "$backstop" ) >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "F6 backstop passes when a report exists"
  else
    fail "F6 backstop false-negative (rc=$rc)"
  fi
}

f3
f5
f6

if [ "$FAIL" -eq 0 ]; then
  echo "ALL LOCAL CHECKS PASSED"
else
  echo "LOCAL CHECKS FAILED" >&2
fi
exit "$FAIL"
