#!/usr/bin/env bash
# Local, network-free harness for the round-3/round-4 pipeline fixes.
#
#   F3  affected.sh classifies a changed/added test file by its bare FQCN
#       (NewFeatureTest -> ut.csv, FooIT -> it.csv), not by a stripped package.
#   F5  run.sh reports a missing required jar with a friendly error and exit 1
#       instead of aborting silently under `set -e`.
#   F6  the zero-report backstop extracted from test-affected.yml exits 1 when
#       tests were selected but no surefire/failsafe report exists.
#   S2/S8 the diff used for blast/selection uses --no-renames --diff-filter=ADMRT,
#       so a guarded file renamed out of its prefix or replaced by a symlink is
#       still visible.
#   S5  BLAST_RE (extracted from test-affected.yml) matches the whole build/test
#       surface and does not match docs.
#   S4  the per-named-class assertion fails when a selected class produced no
#       report and passes when it did.
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

# ---------------------------------------------------------------------------
# S2/S8 — diff must expose renames (both sides) and typechanges
# ---------------------------------------------------------------------------
s2s8() {
  local dir base head new old
  dir="$(newtmp)"
  (
    cd "$dir" || exit 1
    git init -q .
    git config user.email t@t.t; git config user.name t
    mkdir -p dspace/config tools
    printf 'cfg\n' > dspace/config/d.cfg
    printf 'tool\n' > tools/x.sh
    git add -A && git commit -qm base
    base="$(git rev-parse HEAD)"
    # rename a guarded file OUT of its prefix + replace a file with a symlink
    git mv dspace/config/d.cfg dspace/moved.cfg
    rm tools/x.sh && ln -s /etc/hostname tools/x.sh
    git add -A && git commit -qm attack
    head="$(git rev-parse HEAD)"
    new="$(git diff --no-renames --name-only --diff-filter=ADMRT "$base...$head")"
    old="$(git diff --name-only --diff-filter=ADMR "$base...$head")"
    printf 'NEW\n%s\nOLD\n%s\n' "$new" "$old"
  ) > "$dir/out" 2>&1 || { fail "S2/S8 diff run crashed"; return; }

  new="$(sed -n '/^NEW$/,/^OLD$/p' "$dir/out" | grep -vE '^(NEW|OLD)$' || true)"
  old="$(sed -n '/^OLD$/,$p' "$dir/out" | grep -v '^OLD$' || true)"
  if printf '%s\n' "$new" | grep -qx 'dspace/config/d.cfg' \
     && printf '%s\n' "$new" | grep -qx 'dspace/moved.cfg' \
     && printf '%s\n' "$new" | grep -qx 'tools/x.sh'; then
    pass "S2/S8 --no-renames+ADMRT exposes rename-old-path and typechange"
  else
    fail "S2/S8 new diff list missing guarded paths: $(printf '%s ' $new)"
  fi
  # Regression guard: the old command hid these (this is what S2/S8 exploited).
  if printf '%s\n' "$old" | grep -qx 'dspace/config/d.cfg' \
     || printf '%s\n' "$old" | grep -qx 'tools/x.sh'; then
    echo "NOTE: S2/S8 old-command no longer hides the attack (flags still safe)"
  fi
}

# ---------------------------------------------------------------------------
# S5 — BLAST_RE covers the build/test surface, not docs
# ---------------------------------------------------------------------------
s5() {
  local re p ok=1
  re="$(grep -m1 '^[[:space:]]*BLAST_RE=' "$AFFECTED_YML" | sed -E "s/.*BLAST_RE='([^']*)'.*/\1/")"
  if [ -z "$re" ]; then fail "S5 could not extract BLAST_RE"; return; fi
  for p in src/main/assembly/testEnvironment.xml dspace-test-trace/pom.xml \
           Dockerfile docker-compose.yml checkstyle.xml \
           .github/workflows/test-affected.yml tools/test-graph/run.sh \
           dspace/config/dspace.cfg dspace-api/pom.xml; do
    printf '%s\n' "$p" | grep -qE "$re" || { echo "  S5 NOT matched: $p"; ok=0; }
  done
  for p in README.md docs/guide.adoc; do
    printf '%s\n' "$p" | grep -qE "$re" && { echo "  S5 false match: $p"; ok=0; }
  done
  if [ "$ok" -eq 1 ]; then pass "S5 BLAST_RE covers build/test surface and skips docs"
  else fail "S5 BLAST_RE surface"; fi
}

extract_s4_block() {
  awk '
    /# >>> S4: per-named-class report assertion/ { f=1; next }
    /# <<< S4: per-named-class report assertion/ { exit }
    f { print }
  ' "$AFFECTED_YML"
}

# ---------------------------------------------------------------------------
# S4 — every specifically-named selected class must produce a report
# ---------------------------------------------------------------------------
s4() {
  local block d1 d2 out rc
  block="$(extract_s4_block)"
  if [ -z "$block" ]; then fail "S4 could not extract assertion block"; return; fi

  # negative: selected WantedTest, only an unrelated report exists -> fail
  d1="$(newtmp)"
  mkdir -p "$d1/dspace-api/target/surefire-reports"
  : > "$d1/dspace-api/target/surefire-reports/TEST-org.dspace.OtherTest.xml"
  out="$(cd "$d1" && UT_CSV=WantedTest IT_CSV= bash -c "$block" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'NO report'; then
    pass "S4 missing selected class fails loud (exit 1)"
  else
    fail "S4 negative (rc=$rc; out=$out)"
  fi

  # positive: the report names the selected class (as surefire writes it) -> pass
  d2="$(newtmp)"
  mkdir -p "$d2/dspace-api/target/surefire-reports"
  : > "$d2/dspace-api/target/surefire-reports/TEST-org.dspace.impact.WantedTest.xml"
  ( cd "$d2" && UT_CSV=WantedTest IT_CSV= bash -c "$block" ) >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "S4 present selected class passes"
  else
    fail "S4 positive (rc=$rc)"
  fi
}

f3
f5
f6
s2s8
s5
s4

if [ "$FAIL" -eq 0 ]; then
  echo "ALL LOCAL CHECKS PASSED"
else
  echo "LOCAL CHECKS FAILED" >&2
fi
exit "$FAIL"
