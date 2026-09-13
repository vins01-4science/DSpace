# Round-3 Fix Plan — test-impact / baseline-delta pipeline

Status: **planned, not started**
Author context: round-3 adversarial review (subagent) verdict: `NOT-SOUND (3 blocking)`.
Repo: `/home/vins/dev/projects/DSpace7/dspace-tcg-phase0` (`vins-fork` = `vins01-4science/DSpace`)
Refs: `main = 50b9f6e20a7`, feature `task/test-class-graph-phase0 = 7e8083386f8`
Reviewed artifacts: `.github/workflows/{impact-index,merge-patch,test-affected}.yml`,
`tools/test-graph/{affected.sh,run.sh,phase-module.sh,split-tests.sh}`,
`TestGraph.java`, `PerTestCoverage.java`, `pom.xml` test-graph profile.

## Guiding principles
1. **No vacuous green.** Zero tests executed must never pass silently. A PR must not be able to
   edit the gate (`tools/`, `.github/`) and still get a green check.
2. **Blast radius is data, not a fallback.** The dependency/config blast rule must apply even when
   some tests *are* affected.
3. **One source of truth.** Reuse a single `CHANGED=` diff in each workflow; delete dead outputs.
4. **Every fix gets a probe.** Local harness for logic, one dynamic CI run for the integrated path.
5. **Fail loud** at trust boundaries (tooling, resolver, reports, zero-exec).

---

## Findings → work items

| ID | Sev | Finding | File:line | Est |
|----|-----|---------|-----------|-----|
| F1 | HIGH (blocking) | Tooling-only diff → `Nothing to test; exit 0` **before** the zero-report backstop → self-editing PR passes vacuously | `test-affected.yml:190-228` | 15m |
| F2 | HIGH (blocking) | Blast-radius (`pom.xml`/`dspace/config`) checked only in the final `else`; a dep bump + one test skips it | `test-affected.yml:178-201` | 10m |
| F3 | HIGH (blocking) | Changed/added test file written as bare FQCN but parsed as `Class.method` → class becomes `org.dspace` / `dspace` → new test never runs | `affected.sh:106,144-147` | 15m |
| F4 | MED | `merge-patch` has no blast rule: `pom.xml`-only push → `skip=1` → old DB copied, `built-from` advanced untested | `merge-patch.yml:195-200,282-300` | 20m |
| F5 | MED | `run.sh pick()` aborts (bare exit 1) on a missing m2 dir; friendly error at :19-22 is dead under `set -euo pipefail` | `run.sh:8-22` | 5m |
| F6 | LOW | E4 probe (`34718376625`) never executed the `RAN -eq 0` branch → proves no false-positive, not detection | probe | 20m |
| H1 | NIT | pom profile pins `org.jacoco.agent` `0.8.14` while resolver fetches `0.8.15` (drift trap) | `pom.xml:746` | 10m |
| H2 | NIT | Dead output: `modules.txt` has **zero consumers**; stale comments: "Jacobo" ×2; merge-patch rationale still talks about `-pl`/`modules.txt` | `affected.sh:150-160`, `test-affected.yml:108`, `impact-index.yml:110`, `merge-patch.yml:206-213` | 15m |
| H3 | NIT | `PerTestCoverage` exec key `Class.method` → parameterized invocations overwrite; `@Nested` → `Outer_Inner`, unmatchable by `-Dtest` | `PerTestCoverage.java:110-118` | 60m+ |
| H4 | NIT | Stale-class detection only when lists non-empty; renames/`$` silently merge | `TestGraph.java:829-830` | design |

---

## Batch 1 — BLOCKERS (one commit: `fix(ci): fail closed on blast-radius and self-editing PRs`)

### F1 + F2 — restructure `test-affected.yml` run step (lines 165-219)
Compute the diff **once** and hoist the blast check above the arms. **Broaden** the regex to the
pipeline's own surface so a tooling PR can never pass vacuously.

```bash
UT_CSV=...; IT_CSV=...; BASELINE_FOUND=...; BASE_SHA=...; HEAD_SHA=...
CHANGED="$(git diff --name-only --diff-filter=ADMR "$BASE_SHA...$HEAD_SHA")" || {
  echo "!! git diff $BASE_SHA...$HEAD_SHA failed" >&2; exit 1; }

# High-blast-radius: dependencies, shared config, AND the pipeline itself.
BLAST_RE='(^|/)pom\.xml$|^dspace/config/|^\.github/|^tools/'
if [ "$BASELINE_FOUND" = "false" ] \
   || printf '%s\n' "$CHANGED" | grep -qE "$BLAST_RE"; then
  echo "Full reactor (no baseline, or blast-radius change: pom/config/workflows/tools)."
  mvn -B -V install -P-assembly -DskipUnitTests=false -DskipIntegrationTests=false -DfailIfNoTests=false
elif [ -n "$UT_CSV" ] && [ -n "$IT_CSV" ]; then   # unchanged arms
  ...
elif [ -n "$UT_CSV" ]; then ...
elif [ -n "$IT_CSV" ]; then ...
else
  # Not blast: keep the touched-module fallback for source the index missed.
  MODULES=$(printf '%s\n' "$CHANGED" | cut -d/ -f1 | grep '^dspace' | sort -u \
            | while read -r m; do [ -f "$m/pom.xml" ] && echo "$m"; done | paste -sd, -)
  [ -z "$MODULES" ] && { echo "Nothing to test (no source/config/blast changes)."; exit 0; }
  echo "Affected set empty but modules changed -> full suites of: $MODULES"
  mvn -B -V install -P-assembly -DskipUnitTests=true -DskipIntegrationTests=true -DfailIfNoTests=false
  mvn -B -V install -P-assembly -pl "$MODULES" -DskipUnitTests=false -DskipIntegrationTests=false -DfailIfNoTests=false
fi
# backstop (unchanged): count */target/*-reports/TEST-*.xml, fail if 0
```
- `exit 0` on docs-only remains **after** blast filtering, so it is only reachable for genuinely inert changes.
- Keeps the no-`-am` + `-pl` rationale comment for the module fallback.
- **Acceptance:** `tools/**`- or `.github/**`-only diff ⇒ full reactor (never `Nothing to test`); `pom.xml` + one test ⇒ full reactor.

### F4 — `merge-patch.yml` blast rule (lines 184-200)
Same `BLAST_RE` on `CHANGED` before deciding `skip=1`. If blast ⇒ set `blast=1` (no skip) and make
the "Run affected tests" step run the full reactor when `UT`/`IT` are empty and `blast==1`.
Non-blast docs-only keeps `skip=1` + "keep prior baseline" + `built-from` advance (still honest:
docs cannot change coverage).
- **Acceptance:** `pom.xml`-only push to `main` ⇒ merge-patch does **not** skip; full reactor runs; `built-from` = new SHA only after tests executed.

### F3 — `affected.sh` test-file provenance (lines 78-99, 101-107, 142-148)
Track changed/added test classes separately so no method-stripping is applied to them.

```bash
declare -A ALL=() TESTFILE=()
...
  if is_test_file "$f"; then
    TESTFILE["$(class_from_file "$f")"]=1   # FQCN, no method
  fi
...
add_class() { local cls="$1" simple="${1##*.}"
  if is_it_class "$simple"; then IT+=("$simple"); else UT+=("$simple"); fi; }
for t in "${!ALL[@]}";      do add_class "${t%.*}"; done   # tool emits Class.method
for c in "${!TESTFILE[@]}"; do add_class "$c";       done   # bare FQCN
```
- **Acceptance (local):** a changed `.../NewFeatureTest.java` ⇒ `ut.csv` contains `NewFeatureTest`
  (not `dspace`); a changed `.../FooIT.java` ⇒ `it.csv` contains `FooIT`.

---

## Batch 2 — WORTH FIXING (one commit: `fix(ci): harden resolver guard and dead-path error`)

### F5 — `run.sh` pick guard (lines 8-22)
```bash
pick() { local dir="$1" pat="$2"; [ -d "$dir" ] || return 0
  find "$dir" -name "$pat" ! -name '*-sources.jar' 2>/dev/null | sort -V | tail -1; }
```
- **Acceptance (local):** `M2=/tmp/nope bash tools/test-graph/run.sh validate --db /dev/null` prints the
  `ERROR: missing a required jar ...` message and exits 1 (not a silent `set -e` abort).

### F6 — real negative probe for the zero-report backstop
Primary: local harness that reproduces the run-step tail with a non-empty `UT_CSV` and zero report
files ⇒ asserts exit 1. Optional CI: throwaway branch hardcoding a bogus class, expect RED, close PR.
- **Acceptance:** harness prints the `!! tests were selected but NO ...` line and exits 1.

---

## Batch 3 — HYGIENE (one commit: `chore(ci): align jacoco pins and drop dead modules.txt`)

- **H1** `pom.xml:746` `org.jacoco.agent` → `0.8.15` (match plugin/core; or hoist a shared property).
- **H2** delete `modules.txt` emission + `MODULES:` log line in `affected.sh` (no consumers — verified);
  fix "Jacobo" → "JaCoCo" (`test-affected.yml:108`, `impact-index.yml:110`); rewrite the stale
  `-pl`/`modules.txt` rationale in `merge-patch.yml:206-213`.
- **H3/H4** add explicit limitation comments in `PerTestCoverage.java` + `TestGraph.java`
  (parameterized overwrite, `@Nested` unmatchable, sanitized-name collisions) — document now, fix later.

---

## Probe plan (dynamic)

| Probe | Setup | Expected | Cost |
|-------|-------|----------|------|
| E5 | branch off feature: edit `.github/workflows/test-affected.yml` **and** one test file | full reactor, **not** `Nothing to test` | ~40m |
| E7 | branch off feature: add `dspace-api/src/test/java/org/dspace/impact/NewProbeTest.java` (trivial `@Test`) | `Running UT NewProbeTest`, `Tests run: 1` | ~15m |
| E8 | push `pom.xml` comment-only to `main` | merge-patch does **not** skip; full reactor; `built-from` after tests | ~40m |
| E1′ | re-run a `tools/**`-only PR | full reactor (non-vacuous), not `Nothing to test` | ~40m |
| F5/F6 | local only | see Batch 2 | ~5m |

Close every probe PR; delete probe branches. Do not leave probe artifacts on `main` except harmless
doc comments (or revert with a follow-up run if we prefer a pristine tree).

## Definition of done
1. `bash -n tools/test-graph/*.sh`; all 3 workflows parse as YAML; no stale comments/`modules.txt`.
2. Local harnesses for F3, F5, F6 pass; `affected.sh` new-test classification verified.
3. E5, E7, E8 (+E1′) green with the **expected** arm in the log (paste line evidence).
4. `main` + feature refs updated (`--no-verify` push to `vins-fork`); all probe PRs closed; tracked tree clean.
5. Commit messages: Batch 1/2/3 as above; cherry-pick each to `task/test-class-graph-phase0`.

## Risks / rollback
- **Reactor-wide on `.github/**`+`tools/**`** makes pipeline PRs ~40m. Acceptable once; revisit with the
  sentinel option below. Rollback = narrow `BLAST_RE` (one-line revert).
- **F3 provenance refactor** could change selection; mitigated by `sort -u` at output + local harness.
- **Removing `modules.txt`**: grep shows zero in-repo consumers; if any external tool reads it, re-add
  behind the same emission.

## Open decision (pick one)
- **(A) RECOMMENDED** — `.github/**` + `tools/**` → full reactor (uniform, simple, safe).
- **(B)** — `.github/**` + `tools/**` → a cheap “self-test” job (actionlint + one sentinel test) instead
  of the full reactor; cheaper PRs, more code, and the sentinel path itself must be trusted.
