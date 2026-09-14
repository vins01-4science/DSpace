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
#   S9  affected.sh fails loud when the Java tool exits non-zero without writing
#       stderr (a silent empty affected set must not pass).
#   S12 split-tests.sh fails loud when a class carrying test/suite annotations
#       matches neither surefire nor failsafe includes (coverage would be lost).
#   R0  ASM phase-0 reflection safety net is wired end to end: TestGraph.java
#       extracts reflection sites, affected.sh emits a force_full marker, and both
#       workflows fail closed (full reactor) when the marker is present.
#   G7  the R0/R1/R3/S7/S10/S14 probes execute the real logic (compile fixtures and
#       run TestGraph; run the merge-patch decision body; parse the workflow pins)
#       instead of only grepping for wiring strings. Executable parts need javac and
#       the local .m2 runtime jars, and are skipped on a bare CI runner.
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

# Newest non-sources/javadoc jar for a .m2 artifact path, or empty.
find_jar() {
  find "${M2:-$HOME/.m2/repository}/$1" -name '*.jar' \
    ! -name '*-sources.jar' ! -name '*-javadoc.jar' 2>/dev/null | sort -V | tail -1
}

# True when the test-graph runtime jars and a JDK javac are available locally, so the
# executable fixture probes can compile and run TestGraph. They are skipped on a bare
# CI runner (tooling-checks.yml installs only a JDK and the static wiring checks run).
tg_runtime_ok() {
  command -v javac >/dev/null 2>&1 || return 1
  local j
  for j in org/jacoco/org.jacoco.core org/ow2/asm/asm org/ow2/asm/asm-tree \
           org/ow2/asm/asm-commons org/xerial/sqlite-jdbc; do
    [ -n "$(find_jar "$j")" ] || return 1
  done
  return 0
}

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
  # G9: single source of truth — extract the shared blast regex from the lib.
  if [ ! -f "$TG/pipeline-lib.sh" ]; then fail "S5 pipeline-lib.sh missing"; return; fi
  re="$(sed -n "s/^BLAST_RE='\(.*\)'$/\1/p" "$TG/pipeline-lib.sh" | head -1)"
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

# ---------------------------------------------------------------------------
# S10 — merge-patch must not skip (and advance built-from) for a non-doc change
# ---------------------------------------------------------------------------
s10() {
  local y="$ROOT/.github/workflows/merge-patch.yml" n ok=1
  n="$(grep -c 'echo "skip=1"' "$y" 2>/dev/null || true)"
  if ! grep -q 'FALLBACK_MODULES' "$y" || ! grep -q 'INERT_RE' "$y" || [ "$n" -ne 1 ]; then
    fail "S10 merge-patch fallback missing (skip emissions=$n)"; return
  fi

  # Executable: run the real 'Compute affected tests' decision body against a stub
  # affected.sh + a real git repo, and assert the docs-skip / blast / module decisions.
  if ! command -v python3 >/dev/null 2>&1; then
    echo "  S10 executable fixture skipped (python3 absent)"
  else
    local d base rc
    d="$(newtmp)"
    python3 - "$y" "$d/step.sh" <<'PY' || { fail "S10 could not extract the affected step"; return; }
import sys, yaml

with open(sys.argv[1]) as fh:
    doc = yaml.safe_load(fh)
body = None
for s in doc['jobs']['patch']['steps']:
    if s.get('id') == 'affected':
        body = s.get('run')
        break
assert body, 'affected step not found'
body = body.replace('${{ steps.baseline.outputs.db }}', '$DB')
body = body.replace('${{ steps.baseline.outputs.base_sha }}', '$BASE')
body = body.replace('${{ github.sha }}', '$HEAD')
with open(sys.argv[2], 'w') as fh:
    fh.write('set -euo pipefail\n' + body)
PY
    mkdir -p "$d/repo/tools/test-graph"
    cp "$TG/pipeline-lib.sh" "$d/repo/tools/test-graph/pipeline-lib.sh"
    cat > "$d/repo/tools/test-graph/affected.sh" <<'STUB'
#!/usr/bin/env bash
out=target/test-graph/affected
mkdir -p "$out"
printf '%s' "${STUB_UT:-}" > "$out/ut.csv"
printf '%s' "${STUB_IT:-}" > "$out/it.csv"
[ "${STUB_FORCE:-0}" = "1" ] && echo "reflection probe" > "$out/force_full"
exit 0
STUB
    (
      cd "$d/repo" || exit 1
      git init -q .
      git config user.email t@t.t; git config user.name t
      printf '# base\n' > README.md
      mkdir -p dspace-api
      printf '<project/>\n' > dspace-api/pom.xml
      git add -A && git commit -qm base
    ) || { fail "S10 fixture repo init failed"; return; }
    base="$(git -C "$d/repo" rev-parse HEAD)"

    run_case() {
      local name="$1" path="$2" ut="$3" it="$4" force="$5"
      git -C "$d/repo" reset -q --hard "$base" >/dev/null 2>&1
      mkdir -p "$d/repo/$(dirname "$path")"
      printf 'x\n' > "$d/repo/$path"
      git -C "$d/repo" add -A >/dev/null 2>&1
      git -C "$d/repo" commit -qm "$name" >/dev/null 2>&1
      local head; head="$(git -C "$d/repo" rev-parse HEAD)"
      : > "$d/out"
      ( cd "$d/repo" && DB="$d/db.sqlite" BASE="$base" HEAD="$head" \
          GITHUB_OUTPUT="$d/out" STUB_UT="$ut" STUB_IT="$it" STUB_FORCE="$force" \
          bash "$d/step.sh" ) >"$d/$name.log" 2>&1
      echo $?
    }

    # 1) docs-only, index found nothing -> must skip (baseline already current).
    rc="$(run_case docs docs/guide.md "" "" 0)"
    { [ "$rc" -eq 0 ] && grep -q '^skip=1$' "$d/out" && grep -q '^blast=0$' "$d/out"; } \
      || { echo "  S10 docs-only did not skip (rc=$rc):"; sed 's/^/    /' "$d/docs.log"; ok=0; }

    # 2) unclassified non-doc with no known module -> must run the full reactor.
    rc="$(run_case unclassified libfoo/data.sql "" "" 0)"
    { [ "$rc" -eq 0 ] && ! grep -q '^skip=1$' "$d/out" && grep -q '^blast=1$' "$d/out"; } \
      || { echo "  S10 unclassified change skipped (rc=$rc):"; sed 's/^/    /' "$d/unclassified.log"; ok=0; }

    # 3) empty index set but a dspace module changed -> module-suite fallback.
    rc="$(run_case module dspace-api/src/main/java/org/x/New.java "" "" 0)"
    { [ "$rc" -eq 0 ] && ! grep -q '^skip=1$' "$d/out" && grep -q '^modules=dspace-api$' "$d/out"; } \
      || { echo "  S10 module fallback wrong (rc=$rc):"; sed 's/^/    /' "$d/module.log"; ok=0; }

    # 4) index found a UT -> narrowed run, never a skip.
    rc="$(run_case ut dspace-api/src/main/java/org/x/New.java FooTest "" 0)"
    { [ "$rc" -eq 0 ] && ! grep -q '^skip=1$' "$d/out" && grep -q '^ut=FooTest$' "$d/out"; } \
      || { echo "  S10 narrowed UT run wrong (rc=$rc):"; sed 's/^/    /' "$d/ut.log"; ok=0; }

    # 5) reflection marker present -> must force the full reactor, never a skip.
    rc="$(run_case force dspace-api/src/main/java/org/x/New.java "" "" 1)"
    { [ "$rc" -eq 0 ] && ! grep -q '^skip=1$' "$d/out" && grep -q '^blast=1$' "$d/out" \
        && grep -q 'Reflection safety net' "$d/force.log"; } \
      || { echo "  S10 reflection marker ignored (rc=$rc):"; sed 's/^/    /' "$d/force.log"; ok=0; }
  fi

  if [ "$ok" -eq 1 ]; then pass "S10 merge-patch skip gated (docs skip; blast/module/UT/reflection run)"
  else fail "S10 merge-patch fallback"; fi
}

# ---------------------------------------------------------------------------
# S9 — a tool that exits non-zero with NO stderr must not yield a silent empty set
# ---------------------------------------------------------------------------
s9() {
  local af="$TG/affected.sh" dir base head rc
  dir="$(newtmp)"
  mkdir -p "$dir/tools/test-graph"
  cp "$af" "$dir/tools/test-graph/affected.sh"
  cat > "$dir/tools/test-graph/run.sh" <<'STUB'
#!/usr/bin/env bash
# Fail loudly on the process exit code but write nothing (no stderr).
exit 1
STUB
  chmod +x "$dir/tools/test-graph/run.sh"
  (
    cd "$dir" || exit 1
    git init -q .
    git config user.email t@t.t; git config user.name t
    mkdir -p dspace-api/src/main/java/org/dspace/impact
    printf 'base\n' > dspace-api/README
    git add -A && git commit -qm base
    base="$(git rev-parse HEAD)"
    printf 'package org.dspace.impact;\npublic class Changed {}\n' \
      > dspace-api/src/main/java/org/dspace/impact/Changed.java
    git add -A && git commit -qm add
    head="$(git rev-parse HEAD)"
    bash tools/test-graph/affected.sh --db /dev/null --base "$base" --head "$head" \
      --out "$dir/out" > "$dir/out.log" 2>&1
    echo $? > "$dir/rc"
  ) || { fail "S9 affected.sh run crashed"; return; }
  rc="$(cat "$dir/rc" 2>/dev/null || echo 0)"
  if [ "$rc" -ne 0 ] && grep -q 'refusing to emit' "$dir/out.log"; then
    pass "S9 silent tool failure fails loud (no vacuous empty set)"
  else
    fail "S9 silent tool failure gave rc=$rc (want nonzero + 'refusing to emit')"
  fi
}

f3
f5
f6
s2s8
s5
s4
s10
s9
r0( ) {
  local tg="$TG/TestGraph.java" af="$TG/affected.sh"
  local m="$ROOT/.github/workflows/merge-patch.yml" t="$AFFECTED_YML" ok=1
  # TestGraph: detectors + the resolve subcommand + index table plumbing.
  for pat in 'reflectionResolveCmd' 'reflection-resolve' 'reflection_sites' \
             'java/util/ServiceLoader' 'java/lang/ClassLoader' 'java/lang/reflect/' \
             'java/lang/Class' 'forName' 'dynamic' ; do
    grep -qF -- "$pat" "$tg" || { echo "  R0 TestGraph missing: $pat"; ok=0; }
  done
  # affected.sh: collects changed classes, resolves targets, writes the marker.
  grep -qF 'CHANGED_CLASSES' "$af"   || { echo "  R0 affected.sh missing CHANGED_CLASSES"; ok=0; }
  grep -qF 'force_full' "$af"        || { echo "  R0 affected.sh missing force_full"; ok=0; }
  grep -qF 'reflection-resolve' "$af" || { echo "  R0 affected.sh missing reflection-resolve call"; ok=0; }
  grep -qF 'reflection_plan.txt' "$af" || { echo "  R0 affected.sh missing resolve plan"; ok=0; }
  grep -qF -- '--bean' "$af"          || { echo "  R0 affected.sh missing Spring bean lookup"; ok=0; }
  # both workflows consume the marker.
  grep -qF 'force_full' "$t" || { echo "  R0 test-affected.yml missing force_full"; ok=0; }
  grep -qF 'force_full' "$m" || { echo "  R0 merge-patch.yml missing force_full"; ok=0; }
  # the index build must emit reflection_sites, or every run fails closed to full.
  grep -qE '"\$TG" reflection --module' "$TG/phase-module.sh" \
    || { echo "  R0 phase-module.sh does not emit reflection_sites"; ok=0; }

  # Executable: compile a class with forName/loadClass/ServiceLoader sites, run the
  # real ASM pass, then resolve constant/dynamic targets against a synthetic index.
  if ! tg_runtime_ok; then
    echo "  R0 executable fixture skipped (runtime jars / javac absent)"
  else
    local m2="${M2:-$HOME/.m2/repository}" d mod tsv rc
    d="$(newtmp)"; mod="$d/mod"
    mkdir -p "$mod/src/org/dspace/probe0" "$mod/target/classes"
    cat > "$mod/src/org/dspace/probe0/ReflectProbe.java" <<'JAVA'
package org.dspace.probe0;

import java.util.ServiceLoader;

public class ReflectProbe {
    public static Class<?> constant() throws Exception {
        return Class.forName("org.dspace.core.Plugin");
    }
    public static Class<?> dynamic(String n) throws Exception {
        return Class.forName(n);
    }
    public static Class<?> loader() throws Exception {
        return ClassLoader.getSystemClassLoader().loadClass("org.dspace.other.Dynamic");
    }
    public static ServiceLoader<Runnable> svc() {
        return ServiceLoader.load(Runnable.class);
    }
}
JAVA
    if ! javac -d "$mod/target/classes" \
         "$mod/src/org/dspace/probe0/ReflectProbe.java" 2>"$d/javac.log"; then
      echo "  R0 javac failed:"; sed 's/^/    /' "$d/javac.log"; ok=0
    elif ! M2="$m2" bash "$TG/run.sh" reflection --module "$mod" >"$d/refl.log" 2>&1; then
      echo "  R0 reflection pass failed:"; sed 's/^/    /' "$d/refl.log"; ok=0
    else
      tsv="$mod/target/test-graph/reflection_sites.tsv"
      grep -qF $'\tforName\torg.dspace.core.Plugin' "$tsv" \
        || { echo "  R0 missed the constant forName target"; ok=0; }
      [ -n "$(awk -F'\t' '$2=="forName" && $3==""{print; exit}' "$tsv")" ] \
        || { echo "  R0 missed the dynamic forName site (empty target)"; ok=0; }
      grep -qF $'\tloadClass\torg.dspace.other.Dynamic' "$tsv" \
        || { echo "  R0 missed the loadClass target"; ok=0; }
      grep -qF $'\tserviceLoader\tjava.lang.Runnable' "$tsv" \
        || { echo "  R0 missed the ServiceLoader target"; ok=0; }
    fi
    sqlite3 "$d/roadmap.sqlite" <<'SQL'
CREATE TABLE reflection_sites(owner TEXT, kind TEXT, target TEXT);
INSERT INTO reflection_sites VALUES
 ('org.dspace.probe0.ConstantCaller','forName','org.dspace.core.Plugin'),
 ('org.dspace.probe0.DynamicCaller','forName',''),
 ('org.dspace.probe0.PrefixCaller','forNamePrefix','org.dspace.svc.');
SQL
    rc=0
    printf 'org.dspace.core.Plugin\norg.dspace.probe0.DynamicCaller\norg.dspace.svc.Impl\norg.other.Unrelated\n' \
      | M2="$m2" bash "$TG/run.sh" reflection-resolve --db "$d/roadmap.sqlite" \
        >"$d/plan" 2>"$d/plan.err" || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "  R0 reflection-resolve rc=$rc:"; sed 's/^/    /' "$d/plan.err"; ok=0
    else
      grep -qF $'resolve\torg.dspace.probe0.ConstantCaller' "$d/plan" \
        || { echo "  R0 did not resolve a constant target to its caller"; ok=0; }
      grep -qF $'dynamic\torg.dspace.probe0.DynamicCaller' "$d/plan" \
        || { echo "  R0 did not fail closed on a dynamic caller"; ok=0; }
      grep -qF $'dynamic\torg.dspace.svc.Impl' "$d/plan" \
        || { echo "  R0 did not fail closed on a border target"; ok=0; }
      grep -qF 'org.other.Unrelated' "$d/plan" \
        && { echo "  R0 flagged an unrelated class"; ok=0; }
    fi
    sqlite3 "$d/stale.sqlite" 'CREATE TABLE t(x);'
    rc=0
    printf 'org.dspace.core.Plugin\n' \
      | M2="$m2" bash "$TG/run.sh" reflection-resolve --db "$d/stale.sqlite" \
        >/dev/null 2>"$d/stale.err" || rc=$?
    { [ "$rc" -eq 3 ] && grep -q 'forcing full reactor' "$d/stale.err"; } \
      || { echo "  R0 stale index did not fail closed (rc=$rc)"; ok=0; }
  fi

  if [ "$ok" -eq 1 ]; then pass "R0 reflection safety net (extract -> resolve -> marker -> workflows)"
  else fail "R0 reflection safety net wiring"; fi
}
r0

r1() {
  local tg="$TG/TestGraph.java" ok=1
  # Phase 2 string/border analysis: constant-folded concat + package borders.
  for pat in 'RE_BORDER' 'borderPrefix' 'StringConcatFactory' 'visitInvokeDynamicInsn' \
             '"Prefix"' 'borders.add' 'cls.startsWith(p)' ; do
    grep -qF -- "$pat" "$tg" || { echo "  R1 TestGraph missing: $pat"; ok=0; }
  done

  # Executable: a concatenated / StringBuilder / String.format target must become a
  # namespace border; a local constant must still resolve to its literal target.
  if ! tg_runtime_ok; then
    echo "  R1 executable fixture skipped (runtime jars / javac absent)"
  else
    local m2="${M2:-$HOME/.m2/repository}" d mod tsv
    d="$(newtmp)"; mod="$d/mod"
    mkdir -p "$mod/src/org/dspace/probe1" "$mod/target/classes"
    cat > "$mod/src/org/dspace/probe1/BorderProbe.java" <<'JAVA'
package org.dspace.probe1;

public class BorderProbe {
    public static Class<?> concat(String n) throws Exception {
        return Class.forName("org.dspace." + n);
    }
    public static Class<?> sb(String n) throws Exception {
        return Class.forName(new StringBuilder("org.dspace.svc.").append(n).toString());
    }
    public static Class<?> formatted(String n) throws Exception {
        return Class.forName(String.format("org.dspace.fmt.%s", n));
    }
    public static Class<?> local() throws Exception {
        String c = "org.dspace.core.Plugin";
        return Class.forName(c);
    }
}
JAVA
    if ! javac -d "$mod/target/classes" \
         "$mod/src/org/dspace/probe1/BorderProbe.java" 2>"$d/javac.log"; then
      echo "  R1 javac failed:"; sed 's/^/    /' "$d/javac.log"; ok=0
    elif ! M2="$m2" bash "$TG/run.sh" reflection --module "$mod" >"$d/refl.log" 2>&1; then
      echo "  R1 reflection pass failed:"; sed 's/^/    /' "$d/refl.log"; ok=0
    else
      tsv="$mod/target/test-graph/reflection_sites.tsv"
      grep -qF $'\tforNamePrefix\torg.dspace.svc.' "$tsv" \
        || { echo "  R1 missed the StringBuilder border"; ok=0; }
      grep -qF $'\tforNamePrefix\torg.dspace.fmt.' "$tsv" \
        || { echo "  R1 missed the String.format border (G3)"; ok=0; }
      grep -qF $'\tforNamePrefix\torg.dspace.' "$tsv" \
        || { echo "  R1 missed the concat border"; ok=0; }
      grep -qF $'\tforName\torg.dspace.core.Plugin' "$tsv" \
        || { echo "  R1 lost local-constant propagation"; ok=0; }
    fi
  fi

  if [ "$ok" -eq 1 ]; then pass "R1 string/border analysis (concat/StringBuilder/format -> border)"
  else fail "R1 string/border analysis"; fi
}
r1

r2() {
  local af="$TG/affected.sh" ok=1
  # Phase-3 static wiring: a single refine pass over the diff replaces the per-file
  # class-level `impacted --file` lookup for changed .java.
  for pat in 'HAVE_JAVA' 'refine --csv --db "$DB" --diff' 'diff.patch' ; do
    grep -qF -- "$pat" "$af" || { echo "  R2 affected.sh missing: $pat"; ok=0; }
  done
  if grep -qF -- 'impacted --csv --db "$DB" --file "$REPO/$f"' "$af"; then
    echo "  R2 java arm still calls class-level impacted --file"; ok=0
  fi
  # Phase-3 functional: with a stubbed tool, the refined set must be what affected.sh
  # emits for a changed .java, and no class-level --file lookup may be issued.
  local dir base head ut
  dir="$(newtmp)"
  mkdir -p "$dir/tools/test-graph"
  cp "$af" "$dir/tools/test-graph/affected.sh"
  cat > "$dir/tools/test-graph/run.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$*" in *"refine --csv"*) echo NarrowedTest ;; esac
exit 0
STUB
  chmod +x "$dir/tools/test-graph/run.sh"
  touch "$dir/db.sqlite"
  (
    cd "$dir" || exit 1
    git init -q .
    git config user.email t@t.t; git config user.name t
    mkdir -p dspace-api/src/main/java/org/dspace/impact
    printf 'base\n' > dspace-api/README
    git add -A && git commit -qm base
    base="$(git rev-parse HEAD)"
    printf 'package org.dspace.impact;\npublic class Changed {}\n' \
      > dspace-api/src/main/java/org/dspace/impact/Changed.java
    git add -A && git commit -qm add
    head="$(git rev-parse HEAD)"
    export STUB_LOG="$dir/stub.log"; : > "$STUB_LOG"
    bash tools/test-graph/affected.sh --db "$dir/db.sqlite" --base "$base" --head "$head" \
      --out "$dir/out" >/dev/null 2>&1
  ) || { fail "R2 affected.sh run crashed"; return; }
  ut="$(cat "$dir/out/ut.csv" 2>/dev/null || true)"
  if [ "$ut" != "NarrowedTest" ] || ! grep -q 'refine' "$dir/stub.log" \
     || grep -q -- '--file' "$dir/stub.log"; then
    ok=0
    echo "  R2 functional: ut='$ut' (want NarrowedTest); refine_called=$(grep -c refine "$dir/stub.log" 2>/dev/null || echo 0); file_lookup=$(grep -c -- '--file' "$dir/stub.log" 2>/dev/null || echo 0)"
  fi
  if [ "$ok" -eq 1 ]; then pass "R2 method-level refine wired (java -> refine, no class-level --file)"
  else fail "R2 refine wiring"; fi
}
r2

r3() {
  local tg="$TG/TestGraph.java" ok=1
  # Phase 4 dynamic-dispatch edges: invokedynamic bootstrap/handles, class literals,
  # method handles and ConstantDynamic are extracted as class references.
  for pat in 'addValue' 'ConstantDynamic' 'getBootstrapMethod' 'org.objectweb.asm.Handle' '"indy"' ; do
    grep -qF -- "$pat" "$tg" || { echo "  R3 TestGraph missing: $pat"; ok=0; }
  done

  # Executable: a class referenced ONLY via a method handle (`Helper::name`) or a
  # class literal (`Helper.class`) must still produce a static edge to Helper.
  if ! tg_runtime_ok; then
    echo "  R3 executable fixture skipped (runtime jars / javac absent)"
  else
    local m2="${M2:-$HOME/.m2/repository}" d mod
    d="$(newtmp)"; mod="$d/mod"
    mkdir -p "$mod/src/org/dspace/probe3" "$mod/target/classes"
    cat > "$mod/src/org/dspace/probe3/Helper.java" <<'JAVA'
package org.dspace.probe3;

class Helper {
    static String name() {
        return "h";
    }
}
JAVA
    cat > "$mod/src/org/dspace/probe3/EdgeProbe.java" <<'JAVA'
package org.dspace.probe3;

import java.util.function.Supplier;

public class EdgeProbe {
    public static Supplier<String> ref() {
        return Helper::name;
    }
    public static Class<?> lit() {
        return Helper.class;
    }
}
JAVA
    if ! javac -d "$mod/target/classes" \
         "$mod/src/org/dspace/probe3/Helper.java" \
         "$mod/src/org/dspace/probe3/EdgeProbe.java" 2>"$d/javac.log"; then
      echo "  R3 javac failed:"; sed 's/^/    /' "$d/javac.log"; ok=0
    elif ! M2="$m2" bash "$TG/run.sh" static --module "$mod" >"$d/static.log" 2>&1; then
      echo "  R3 static pass failed:"; sed 's/^/    /' "$d/static.log"; ok=0
    else
      grep -qF $'org.dspace.probe3.EdgeProbe\torg.dspace.probe3.Helper' \
        "$mod/target/test-graph/edges.tsv" \
        || { echo "  R3 missed the method-handle/class-literal edge"; ok=0; }
    fi
  fi

  if [ "$ok" -eq 1 ]; then pass "R3 dynamic-dispatch edges extracted (indy/handles/class literals)"
  else fail "R3 dynamic-dispatch edge wiring"; fi
}
r3

s12() {
  local split="$TG/split-tests.sh" ok=1 dir base head
  # Static: the fail-loud path exists.
  for pat in 'UNMATCHED_TESTS' 'match neither' 'exit 1'; do
    grep -qF -- "$pat" "$split" || { echo "  S12 split-tests missing: $pat"; ok=0; }
  done
  dir="$(newtmp)"
  # Runnable class with a non-conventional name must NOT be silently dropped.
  mkdir -p "$dir/bad/src/test/java/org/x"
  printf 'package org.x;\nimport org.junit.Test;\npublic class FooSpec { @Test public void a(){} }\n' \
    > "$dir/bad/src/test/java/org/x/FooSpec.java"
  if bash "$split" --module "$dir/bad" --total 2 >"$dir/bad.log" 2>&1; then
    echo "  S12: FooSpec (@Test, unmatched name) did not fail loud"; ok=0
  elif ! grep -q 'match neither' "$dir/bad.log"; then
    echo "  S12: FooSpec failed but without the missing-include message"; ok=0
  fi
  # A helper (no test annotation) and a normal *Test must both pass, BarTest sharded.
  mkdir -p "$dir/ok/src/test/java/org/x"
  printf 'package org.x;\nimport org.junit.Test;\npublic class BarTest { @Test public void a(){} }\n' \
    > "$dir/ok/src/test/java/org/x/BarTest.java"
  printf 'package org.x;\npublic class Helper { public static int x=1; }\n' \
    > "$dir/ok/src/test/java/org/x/Helper.java"
  if ! bash "$split" --module "$dir/ok" --total 2 >"$dir/ok.log" 2>&1; then
    echo "  S12: helper-only module should not fail"; ok=0
  elif ! grep -rq 'BarTest' "$dir/ok/target/test-graph"; then
    echo "  S12: BarTest was not sharded"; ok=0
  fi
  if [ "$ok" -eq 1 ]; then pass "S12 split-tests fails loud on annotation-bearing unsharded tests"
  else fail "S12 split-tests silent-drop guard"; fi
}
s12

s7() {
  local pc="$ROOT/dspace-test-trace/src/main/java/org/dspace/testtrace/PerTestCoverage.java" ok=1
  [ -f "$pc" ] || { fail "S7 PerTestCoverage.java not found"; return; }
  # Unique per-invocation key: a STABLE per-method invocation number appended to the
  # sanitized stem, so parameterized tests / retries no longer overwrite one file,
  # yet the key is identical across builds (no unbounded growth on merge).
  for pat in 'AtomicInteger' 'INVOCATIONS' 'ConcurrentHashMap' '"__"' 'Outer$Inner' '[^a-zA-Z0-9.$_-]' 'execFileName('; do
    grep -qF -- "$pat" "$pc" || { echo "  S7 PerTestCoverage missing: $pat"; ok=0; }
  done
  # The volatile pid/seq scheme (unstable keys) must be gone.
  if grep -qF 'ProcessHandle' "$pc"; then
    echo "  S7 still uses the volatile JVM-pid suffix"; ok=0
  fi
  # The old truncating single-file key must be gone.
  if grep -qF 'safe + ".exec"' "$pc"; then
    echo "  S7 still uses the truncating single-file key"; ok=0
  fi

  # Cross-build-path consistency: the shard (impact-index) and incremental
  # (merge-patch) paths must both install the listener from source. The
  # `cache: maven` key only reflects pom.xml, so a listener source change would
  # otherwise leave shards with a stale jar and emit plain keys while
  # merge-patch emits `__N` keys.
  local ii="$ROOT/.github/workflows/impact-index.yml" mp="$ROOT/.github/workflows/merge-patch.yml"
  grep -qF 'Rebuild dspace-test-trace listener from source' "$ii" \
    || { echo "  S7 impact-index does not rebuild the listener per shard"; ok=0; }
  grep -qF 'maven.build.cache.enabled=false' "$ii" \
    || { echo "  S7 impact-index listener install does not bypass the build cache"; ok=0; }
  grep -qF 'repository/org/dspace/dspace-test-trace' "$ii" \
    || { echo "  S7 impact-index does not purge the cached listener"; ok=0; }
  grep -qF 'install -f dspace-test-trace/pom.xml' "$mp" \
    || { echo "  S7 merge-patch does not install the listener in-job"; ok=0; }
  grep -qF 'deliberately NOT used' "$mp" \
    || { echo "  S7 merge-patch unexpectedly enables the build cache"; ok=0; }

  # Executable: compile the real listener and call execFileName twice — the names
  # must differ (no overwrite) and `$` must survive the sanitizer (nested selectable).
  local cp="" j
  for a in org/junit/platform/junit-platform-launcher \
           org/junit/platform/junit-platform-engine \
           org/junit/platform/junit-platform-commons \
           org/opentest4j/opentest4j org/apiguardian/apiguardian-api; do
    j="$(find_jar "$a")"; [ -n "$j" ] && cp="$cp:$j"
  done
  cp="${cp#:}"
  if [ -z "$cp" ] || ! command -v javac >/dev/null 2>&1; then
    echo "  S7 executable fixture skipped (junit-platform jars / javac absent)"
  else
    local d rc
    d="$(newtmp)"
    cat > "$d/S7Probe.java" <<'JAVA'
package org.dspace.testtrace;

public class S7Probe {
    public static void main(String[] args) {
        String a = PerTestCoverage.execFileName("org.x.Outer$Inner", "case1");
        String b = PerTestCoverage.execFileName("org.x.Outer$Inner", "case1");
        if (a.equals(b)) { System.err.println("overwrite: " + a); System.exit(1); }
        if (!a.contains("org.x.Outer$Inner.case1")) {
            System.err.println("dropped-': " + a); System.exit(2);
        }
        if (!a.matches("org\\.x\\.Outer\\$Inner\\.case1__[0-9]+")) {
            System.err.println("bad-shape: " + a); System.exit(3);
        }
        if (!a.endsWith("__1") || !b.endsWith("__2")) {
            System.err.println("unstable-counter: " + a + " / " + b); System.exit(4);
        }
        System.out.println(a);
        System.out.println(b);
    }
}
JAVA
    rc=0
    javac -cp "$cp" -d "$d" "$d/S7Probe.java" "$pc" >"$d/javac.log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "  S7 javac failed:"; sed 's/^/    /' "$d/javac.log"; ok=0
    else
      rc=0
      java -cp "$d:$cp" org.dspace.testtrace.S7Probe >"$d/run.log" 2>&1 || rc=$?
      if [ "$rc" -ne 0 ]; then
        echo "  S7 execFileName probe failed rc=$rc:"; sed 's/^/    /' "$d/run.log"; ok=0
      fi
    fi
  fi

  if [ "$ok" -eq 1 ]; then pass "S7 per-invocation coverage keys (distinct names; \$ preserved)"
  else fail "S7 per-invocation keys"; fi
}
s7

s14() {
  local wfdir="$ROOT/.github/workflows" ok=1 report
  # S14: every external action must be pinned to a full 40-hex commit SHA, with the
  # human-readable tag kept in a trailing comment. Local reusable workflows (./...)
  # and docker:// refs are exempt. Parsed from the raw YAML so the pin and the
  # comment are validated together (not a substring tautology).
  if ! command -v python3 >/dev/null 2>&1; then
    echo "  S14 parse probe skipped (python3 absent)"
  else
    report="$(python3 - "$wfdir" <<'PY'
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
pat = re.compile(r'^\s*-?\s*uses:\s*["\']?(\S+?)["\']?\s*(?:#\s*(\S+))?\s*$')
bad = []
for f in sorted(root.glob('*.yml')):
    for n, line in enumerate(f.read_text().splitlines(), 1):
        m = pat.match(line)
        if not m:
            continue
        ref = m.group(1)
        if ref.startswith('./') or ref.startswith('docker://'):
            continue
        if '@' not in ref:
            bad.append(f"{f.name}:{n}: unpinned {ref}")
            continue
        name, _, pin = ref.rpartition('@')
        if not re.fullmatch(r'[0-9a-f]{40}', pin):
            bad.append(f"{f.name}:{n}: not a 40-hex SHA: {ref}")
        elif not m.group(2):
            bad.append(f"{f.name}:{n}: missing tag comment: {ref}")
for b in bad:
    print(b)
PY
)"
    if [ -n "$report" ]; then
      echo "  S14 unpinned/mis-pinned external action(s):"
      printf '%s\n' "$report" | sed 's/^/    /'
      ok=0
    fi
  fi
  # A pinned entry must keep the original tag as a comment for readability.
  if ! grep -rqE 'uses: actions/checkout@[0-9a-f]{40} # v7' "$wfdir"/*.yml; then
    echo "  S14 actions/checkout pin comment missing"; ok=0
  fi
  if [ "$ok" -eq 1 ]; then pass "S14 all external actions pinned by commit SHA (parsed)"
  else fail "S14 actions not pinned by SHA"; fi
}
s14

s1() {
  local wf="$ROOT/.github/workflows/gate-integrity.yml" co="$ROOT/.github/CODEOWNERS" ok=1
  # S1: an immutable pull_request_target gate must flag PRs that edit the pipeline
  # itself, and CODEOWNERS must name the protected paths for reviewer enforcement.
  [ -f "$wf" ] || { echo "  S1 gate-integrity.yml missing"; ok=0; }
  [ -f "$co" ] || { echo "  S1 CODEOWNERS missing"; ok=0; }
  if [ -f "$wf" ]; then
    grep -qF 'pull_request_target' "$wf" || { echo "  S1 gate is not pull_request_target"; ok=0; }
    grep -qF 'exit 1' "$wf" || { echo "  S1 gate does not fail the check"; ok=0; }
    grep -qF '\.github/' "$wf" || { echo "  S1 gate missing .github/ path"; ok=0; }
    grep -qF 'tools/' "$wf" || { echo "  S1 gate missing tools/ path"; ok=0; }
    grep -qF 'dspace-test-trace/' "$wf" || { echo "  S1 gate missing dspace-test-trace/ path"; ok=0; }
    grep -qF 'pom\.xml' "$wf" || { echo "  S1 gate missing pom.xml path"; ok=0; }
  fi
  if [ -f "$co" ]; then
    grep -qF '/.github/' "$co" || { echo "  S1 CODEOWNERS missing /.github/"; ok=0; }
    grep -qF '/tools/' "$co" || { echo "  S1 CODEOWNERS missing /tools/"; ok=0; }
    grep -qF '/dspace-test-trace/' "$co" || { echo "  S1 CODEOWNERS missing /dspace-test-trace/"; ok=0; }
    grep -qF 'pom.xml' "$co" || { echo "  S1 CODEOWNERS missing pom.xml"; ok=0; }
  fi

  # S1 executable probe (G1/G2): extract the gate's OWN run-script from the workflow
  # and execute it against a stubbed `gh`. It must fail on (a) a rename of a
  # protected file OUT of its prefix (previous_filename) and (b) a file list that
  # GitHub's 3000-entry cap truncated; it must pass on an inert PR. This replaces a
  # pure grep tautology with behaviour the gate actually exhibits.
  if [ -f "$wf" ]; then
    if ! command -v python3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
      echo "  S1 executable probe skipped (python3/jq unavailable)"
    else
      local gd; gd="$(mktemp -d 2>/dev/null)" || gd=""
      if [ -z "$gd" ]; then
        echo "  S1 executable probe skipped (mktemp failed)"
      else
        python3 - "$wf" >"$gd/gate.sh" <<'PY' 2>/dev/null || true
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for job in wf.get("jobs", {}).values():
    for step in job.get("steps", []):
        if "run" in step:
            sys.stdout.write(step["run"])
PY
        if [ ! -s "$gd/gate.sh" ]; then
          echo "  S1 executable probe skipped (could not extract run-script)"
        else
          sed -e 's/\${{ github.repository }}/test\/repo/g' \
              -e 's/\${{ github.event.pull_request.number }}/1/g' \
              "$gd/gate.sh" >"$gd/gate.run.sh"
          mkdir -p "$gd/bin"
          cat >"$gd/bin/gh" <<'GH'
#!/usr/bin/env bash
args="$*"
case "$FAKE_MODE" in
  rename)
    case "$args" in
      */files*) printf '%s\n' '{"filename":"dspace-api/Foo.java"}' \
                                '{"filename":"tools/test-graph/x.sh.new","previous_filename":"tools/test-graph/x.sh"}';;
      *) echo 2;;
    esac;;
  overcap)
    case "$args" in
      */files*) printf '%s\n' '{"filename":"dspace-api/Foo.java"}';;
      *) echo 5000;;
    esac;;
  inert)
    case "$args" in
      */files*) printf '%s\n' '{"filename":"dspace-api/Foo.java"}';;
      *) echo 1;;
    esac;;
  pom)
    case "$args" in
      */files*) printf '%s\n' '{"filename":"pom.xml"}';;
      *) echo 1;;
    esac;;
esac
GH
          chmod +x "$gd/bin/gh"
          local rc
          FAKE_MODE=rename PATH="$gd/bin:$PATH" GH_TOKEN=dummy bash "$gd/gate.run.sh" >"$gd/o1" 2>&1; rc=$?
          [ "$rc" -ne 0 ] || { echo "  S1 gate MISSED a rename-out of a protected path"; ok=0; }
          grep -q 'modifies the test pipeline' "$gd/o1" || { echo "  S1 gate rename path gave no reason"; ok=0; }
          FAKE_MODE=overcap PATH="$gd/bin:$PATH" GH_TOKEN=dummy bash "$gd/gate.run.sh" >"$gd/o2" 2>&1; rc=$?
          [ "$rc" -ne 0 ] || { echo "  S1 gate MISSED an over-cap file list"; ok=0; }
          grep -q 'Cannot fully enumerate' "$gd/o2" || { echo "  S1 gate over-cap path gave no reason"; ok=0; }
          FAKE_MODE=inert PATH="$gd/bin:$PATH" GH_TOKEN=dummy bash "$gd/gate.run.sh" >"$gd/o3" 2>&1; rc=$?
          [ "$rc" -eq 0 ] || { echo "  S1 gate false-positives on an inert PR"; ok=0; }
          FAKE_MODE=pom PATH="$gd/bin:$PATH" GH_TOKEN=dummy bash "$gd/gate.run.sh" >"$gd/o4" 2>&1; rc=$?
          [ "$rc" -ne 0 ] || { echo "  S1 gate MISSED a protected pom.xml change"; ok=0; }
          grep -q 'modifies the test pipeline' "$gd/o4" || { echo "  S1 gate pom.xml path gave no reason"; ok=0; }
        fi
        rm -rf "$gd"
      fi
    fi
  fi

  if [ "$ok" -eq 1 ]; then pass "S1 immutable gate-integrity check + CODEOWNERS (executable rename/over-cap probe)"
  else fail "S1 gate-integrity"; fi
}

g6() {
  local tg="$TG/TestGraph.java" mp="$ROOT/.github/workflows/merge-patch.yml" ok=1
  # G6/H4: stale test keys must be pruned (build + aggregate) and the merge-patch
  # full-reactor run must pass the compiled test-classes so the prune can fire.
  for pat in 'compiledClasses(' 'testClassOf(' 'testClassRoots(' '--test-classes' \
             'stale per-test key(s)' 'stale test key(s)'; do
    grep -qF -- "$pat" "$tg" || { echo "  G6 TestGraph.java missing: $pat"; ok=0; }
  done
  for pat in 'prune=$BLAST' '--test-classes' 'steps.affected.outputs.prune'; do
    grep -qF -- "$pat" "$mp" || { echo "  G6 merge-patch.yml missing: $pat"; ok=0; }
  done

  # Executable: exercise the real `aggregate` prune against a tiny synthetic DB.
  # Skipped when the test-graph runtime jars are not in the local .m2 (CI).
  local m2="${M2:-$HOME/.m2/repository}" j
  local jars_ok=1
  for j in org/jacoco/org.jacoco.core org/ow2/asm/asm org/ow2/asm/asm-tree \
           org/ow2/asm/asm-commons org/xerial/sqlite-jdbc; do
    [ -n "$(find "$m2/$j" -name '*.jar' ! -name '*-sources.jar' ! -name '*-javadoc.jar' 2>/dev/null | head -1)" ] \
      || jars_ok=0
  done
  if [ "$jars_ok" -eq 0 ] || ! command -v sqlite3 >/dev/null 2>&1; then
    echo "  G6 executable prune probe skipped (runtime jars / sqlite3 absent)"
  else
    local d mod src out1 out2 rc
    d="$(newtmp)"; mod="$d/mod"; src="$d/src.sqlite"
    mkdir -p "$mod/target/test-classes/org/x"
    : > "$mod/target/test-classes/org/x/KeepTest.class"
    sqlite3 "$src" <<'SQL'
CREATE TABLE class_refs(from_c TEXT,to_c TEXT,kind TEXT);
CREATE TABLE cov_test(id INTEGER PRIMARY KEY,name TEXT);
CREATE TABLE cov_class(id INTEGER PRIMARY KEY,name TEXT);
CREATE TABLE cov_data(class_id INTEGER PRIMARY KEY,blob BLOB);
CREATE TABLE property_refs(from_c TEXT,key TEXT,kind TEXT);
CREATE TABLE bean_refs(from_c TEXT,ref TEXT,kind TEXT);
CREATE TABLE config_keys(file TEXT,key TEXT);
CREATE TABLE bean_decls(file TEXT,bean_type TEXT,bean_id TEXT);
CREATE TABLE config_consumers(file TEXT,class TEXT);
INSERT INTO cov_test VALUES (0,'org.x.KeepTest.probe'),(1,'org.x.GoneTest.probe');
SQL
    rc=0
    M2="$m2" bash "$TG/run.sh" aggregate --out "$d/out1.sqlite" --db "$src" \
      --test-classes "$mod/target/test-classes" > "$d/log1" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "  G6 aggregate (--test-classes) failed rc=$rc:"; sed 's/^/    /' "$d/log1"; ok=0
    else
      local names
      names="$(sqlite3 "$d/out1.sqlite" 'SELECT name FROM cov_test' 2>/dev/null)"
      printf '%s\n' "$names" | grep -q 'org.x.KeepTest.probe' || { echo "  G6 pruned a live test class"; ok=0; }
      printf '%s\n' "$names" | grep -q 'org.x.GoneTest.probe' && { echo "  G6 kept a stale test class"; ok=0; }
    fi
    rc=0
    M2="$m2" bash "$TG/run.sh" aggregate --out "$d/out2.sqlite" --db "$src" \
      > "$d/log2" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "  G6 aggregate (no --test-classes) failed rc=$rc:"; sed 's/^/    /' "$d/log2"; ok=0
    else
      local names2
      names2="$(sqlite3 "$d/out2.sqlite" 'SELECT name FROM cov_test' 2>/dev/null)"
      printf '%s\n' "$names2" | grep -q 'org.x.GoneTest.probe' || { echo "  G6 pruned without test-classes (unsafe)"; ok=0; }
    fi
  fi

  if [ "$ok" -eq 1 ]; then pass "G6 stale test-key pruning (build + aggregate + merge-patch wiring)"
  else fail "G6 stale test-key pruning"; fi
}

s1
g6

if [ "$FAIL" -eq 0 ]; then
  echo "ALL LOCAL CHECKS PASSED"
else
  echo "LOCAL CHECKS FAILED" >&2
fi
exit "$FAIL"
