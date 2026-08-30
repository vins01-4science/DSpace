# Test-Graph — change-impact test index

A self-contained toolchain that builds a **test-impact index** for the DSpace
backend: a SQLite database mapping every source class, property, config file,
and Spring bean declaration to the tests that must be re-run when it changes.
A GitHub Actions pipeline (`.github/workflows/impact-index.yml`) publishes the
index on every push to `main`; pull-request runs
(`.github/workflows/test-affected.yml`) download it and run **only** the tests
affected by the PR.

Everything lives under `tools/test-graph/` as a single-file Java program
(`TestGraph.java`) plus small shell drivers. No Maven module, no plugin — the
Java file is compiled and run directly (`run.sh`) with three runtime jars
resolved from your local `~/.m2`.

## How it works

```
            test execution                        aggregation
 ┌──────────────────────────┐              ┌────────────────────────┐
 │ JaCoCo agent (JMX)       │  per-test    │ TestGraph aggregate    │
 │   + PerTestCoverage      │  .exec files │   → root-index.sqlite   │
 │     (JUnit listener)     │ ───────────► │                        │
 └──────────────────────────┘              └────────────────────────┘
            │                                          │
            ▼                                          ▼
 ┌──────────────────────────┐              ┌────────────────────────┐
 │ TestGraph build          │              │ TestGraph impacted     │
 │   per-test .exec →       │              │   diff → affected     │
 │   cov_data (compact) +   │              │   test list (CI gate)  │
 │   class_refs/config_*    │              └────────────────────────┘
 └──────────────────────────┘
```

1. **Static graph** (`static`): scans compiled classes, records the
   class→class call/dependency edges (`edges.tsv`).
2. **Config refs** (`config`): scans source + Spring XML for property keys,
   config-file references, and bean declarations (`config_keys.tsv`,
   `bean_decls.tsv`, `property_refs.tsv`, `bean_refs.tsv`).
3. **Per-test coverage** (`build`): runs the module's tests under the
   `test-class-graph` Maven profile (attaches the JaCoCo agent + the
   `PerTestCoverage` JUnit listener). After *every* test the listener dumps
   that test's JaCoCo execution data to `target/per-test/<Class>.<method>.exec`.
   `build` reads those files, re-analyzes the compiled classes to get per-test
   **line** coverage for `org.dspace.*` classes (inner classes folded into
   their outer class; third-party classes are ignored), and stores it
   compactly: one deflated blob per class in `cov_data` (see *Index format*).
   The old `impact` (class→tests) and `test_covers` (test→classes) tables are
   no longer written — `impact` is derived at query time. `--classes` takes a
   path-separated list (default `<module>/target/classes`); the shard driver
   also passes `<module>/target/test-classes` so test-class coverage counts.
4. **Aggregate** (`aggregate`): unions the per-module (or per-shard) indexes
   into the repo-wide `root-index.sqlite`. `cov_test`/`cov_class` share a
   global namespace (tests/classes deduplicated by name and renumbered);
   `cov_data` is merged per class (each source blob decoded, line sets
   unioned, re-encoded, deflated). The static graph/config/bean tables are
   unioned/**deduplicated**, and `property_impact` is recomputed from the
   merged coverage.
5. **Impacted** (`impacted`): given a changed file / property / config /
   bean, returns the set of tests to run. The class→tests map is derived by a
   reverse BFS over `class_refs` from the changed class, then unioning the
   tests that cover each reached class (from `cov_data`). **Refine** (`refine`)
   narrows the candidates further to tests whose covered lines actually
   intersect the git diff — entirely in memory from `cov_data`, with no `.exec`
   files or compiled classes required.

## Prerequisites

* JDK 21 (same as the DSpace build).
* The runtime jars in your local Maven repo
  (`org.jacoco:org.jacoco.core`, `org.ow2.asm:asm`, `org.xerial:sqlite-jdbc`).
  `run.sh` resolves them from `~/.m2`; CI fetches them with `mvn dependency:get`.
* `dspace-test-trace` installed (`mvn install -f dspace-test-trace/pom.xml -DskipTests`).
  This is the out-of-reactor JUnit listener the `test-class-graph` profile adds
  as a test dependency.

## Commands

All commands run via `bash tools/test-graph/run.sh <cmd> [options]`.

| Command | Purpose | Key options |
| --- | --- | --- |
| `static`   | build class dependency graph | `--module <dir> [--out edges.tsv]` |
| `config`   | extract property/config/bean refs | `--module <dir> [--out dir] [--root <repo>]` |
| `build`    | per-test coverage → partial index | `--module <dir> [--per-test dir] [--classes <dir>[:<dir>…]] [--db file]` |
| `refine`   | method-level refinement via git diff | `--db <file> (--diff <file\|-> \| --base <ref> [--head <ref>]) [--classes <dir>]` |
| `impacted` | query what tests a change hits | `--db <file> (--file \| --property \| --configfile \| --bean \| --beanfile) <value>` |
| `aggregate`| merge partial indexes → root | `--out <file> --db <m1> [--db2 <m2> ...]` |
| `validate` | sanity-check an index | `--module <dir> [--per-test dir] [--db file]` |

`impacted` examples:

```bash
bash tools/test-graph/run.sh impacted --db target/test-graph/root-index.sqlite \
  --file dspace-api/src/main/java/org/dspace/content/ItemServiceImpl.java
bash tools/test-graph/run.sh impacted --db target/test-graph/root-index.sqlite \
  --configfile dspace/config/transforms/dspace-types.xml
bash tools/test-graph/run.sh impacted --db target/test-graph/root-index.sqlite \
  --property mail.server
```

## Index format (compact)

The index is deliberately small: the previous incarnation stored one row per
(class, test) pair plus a raw test→class table and grew to ~800 MB when merged;
the merged `root-index.sqlite` is now a few MB.

```sql
CREATE TABLE cov_test(id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE cov_class(id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE cov_data(class_id INTEGER PRIMARY KEY, blob BLOB);
```

Each `cov_data` blob holds one class's coverage as a deflated, delta-encoded
stream (line numbers are relative to the previous line, test ids relative to
the previous test, all `varint`-encoded):

    repeat { varint(testId - lastTestId);
             varint(nCoveredLines);
             nCoveredLines × varint(line - prevLine) }

Because every test boots the same DSpace kernel, consecutive tests cover
near-identical line sets, so the deltas collapse and deflate compresses them
~100×. Queries only decompress the blobs of the classes in a change's closure.

Other tables (unchanged from the static/config phases): `class_refs(from_c,
to_c, kind)`, `property_refs`, `bean_refs`, `config_keys`, `bean_decls`,
`property_impact(key, test)`, `config_consumers`.

`impact` (class→tests) is **not stored** — it is derived at query time by a
reverse closure over `class_refs` (step 5 above). Dropping it is the main size
win: in the old format `impact` alone was ~400 MB, of which ~77% were rows for
third-party classes (`org.h2.*`, `org.jaxen.*`, …) that can never change and so
never need re-testing.

## Local: per-module workflow

```bash
cd dspace-tcg-phase0
bash tools/test-graph/run.sh static  --module dspace-api
bash tools/test-graph/run.sh config  --module dspace-api --root .
bash tools/test-graph/run.sh build   --module dspace-api --per-test dspace-api/target/per-test \
  --classes dspace-api/target/classes:dspace-api/target/test-classes
bash tools/test-graph/run.sh validate --module dspace-api --per-test dspace-api/target/per-test
```

## Repo-wide (sequential): `phase-all.sh`

`phase-all.sh [--it] [--root .] [--out <file>]` runs every module's
static → config → build, then aggregates into `root-index.sqlite`. Used for a
local full rebuild.

## Parallel pipeline (CI)

To cut wall-clock, the index is built by sharding tests across a CI matrix:
each cell runs **one module + one shard** (a subset of that module's test
classes) and produces a *partial* index from only that shard's coverage. A
final `merge` job downloads every partial and unions them with `aggregate`.

Two drivers support this:

* **`split-tests.sh --module <dir> --total <N>`** enumerates the module's test
  classes (FQCNs), classifies them as unit (`*Test`/`Test*`/`*Tests`/`*TestCase`)
  vs integration (`IT*`/`*IT`/`*ITCase`), skips inner and `Abstract*` classes,
  and writes round-robin shard lists
  `<module>/target/test-graph/shard-<i>-ut.txt` / `shard-<i>-it.txt`.
* **`phase-module.sh <module> --shard <N> <TOTAL> [--it] [--root .] [--db-out <file>]`**
  runs only that shard's tests (via `-Dtest=@shard-ut.txt` / `-Dit.test=@shard-it.txt`),
  then builds the partial index from the shard's `target/per-test` directory,
  passing `--classes <module>/target/classes:<module>/target/test-classes`.

### `.github/workflows/impact-index.yml`

Four jobs:

1. **`plan`** — emits the build matrix (one cell per `module × shard`) from a
   shard-count map.
2. **`assemble`** — installs all modules + the server-webapp test environment +
   `dspace-test-trace` into the Maven repo (populates `cache: maven`) **once**.
3. **`build`** — the matrix; each cell runs `phase-module.sh` and uploads a
   `idx-<module>-<shard>` artifact. `fail-fast: false`; a shard's test failure
   does not fail the job (the partial index is still produced — the PR gate runs
   the real affected tests and would surface failures).
4. **`merge`** — downloads all `idx-*` artifacts, runs `aggregate` into
   `root-index.sqlite`, validates, and publishes the `impact-index` artifact
   (90-day retention, with `built-from.txt` recording the source commit).

### Tuning shard counts

Edit the `SHARDS` array in the `plan` job. Higher numbers spread a module's
tests across more workers (lower per-job time, more jobs). Current defaults:

| Module | Shards |
| --- | --- |
| dspace-api | 8 |
| dspace-server-webapp | 4 |
| dspace-oai | 2 |
| dspace-services | 1 |
| dspace-rdf | 1 |
| dspace-sword | 1 |
| dspace-swordv2 | 1 |
| dspace-iiif | 1 |
| dspace-saml2 | 1 |

### Correctness note

Each shard observes a **disjoint** set of tests, so `cov_test`/`cov_class`/
`cov_data` merge exactly (tests/classes deduplicated globally, coverage blobs
unioned per class). The module-level `config_*`/`bean_*` rows are identical
across that module's shards and are collapsed by the dedup step in `aggregate`.
The merged `root-index.sqlite` is therefore content-equivalent to a single
sequential build.

### Shipping partials

`build` reuses the previous run's database file, so dropping the old tables
leaves free pages and the partial file can stay large (most of its size is
empty pages). `aggregate` writes a fresh file and is naturally small. To ship
individual partial artifacts compactly, run a `VACUUM` on them first
(`sqlite3 <file> 'VACUUM'`).

## CI: PR gate (`test-affected.yml`)

Downloads the latest `impact-index` artifact, computes the affected test set
from the PR diff via `affected.sh`, and runs only those tests (UT via
`-Dtest=`, IT via `-Dit.test=`), falling back to the full module suites when a
diff is too large or no index is available.

Because the compact index stores line-level coverage (`cov_data`), `refine`
can narrow the affected set without `target/per-test` `.exec` files or compiled
classes. `affected.sh` always routes non-Spring XML config changes through the
index-only `refine --configfile`; when the index has no coverage it degrades to
the class-level `impacted --configfile` set, so it never returns fewer tests.

## Troubleshooting

* **Partial index has 0 rows** — the module's tests did not run under the
  `test-class-graph` profile (JaCoCo agent missing, or no exec files in
  `target/per-test`). Check that `dspace-test-trace` is installed and the
  profile is active.
* **`aggregate` reports duplicate-looking rows** — expected only if the same
  partial is passed twice by mistake; the dedup step collapses legitimately
  repeated module-level config rows.
* **A shard job failed but the merge succeeded** — by design: `phase-module.sh`
  continues past test failures (`|| echo`) so the partial index is still
  produced. Inspect the shard's logs for the actual test failure.
