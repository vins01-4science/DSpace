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
 │   impact/test_covers/    │              │   test list (CI gate)  │
 │   class_refs/config_*    │              └────────────────────────┘
 └──────────────────────────┘
```

1. **Static graph** (`static`): scans compiled classes, records the
   class→class call/dependency edges (`edges.tsv`).
2. **Config refs** (`config`): scans source + Spring XML for property keys,
   config-file references, and bean declarations (`config_keys.tsv`,
   `bean_decls.tsv`, `property_refs.tsv`, `bean_refs.tsv`).
3. **Per-test coverage** (`build`): runs the module's tests under the
   `test-class-graph` Maven profile (attaches the JaCooco agent + the
   `PerTestCoverage` JUnit listener). After *every* test the listener dumps
   that test's JaCoCo execution data to `target/per-test/<Class>.<method>.exec`.
   `build` reads those files, computes which classes each test exercised, and
   writes the `impact` (class→tests) and `test_covers` (test→classes) tables
   plus a reverse closure over the static graph.
4. **Aggregate** (`aggregate`): unions the per-module (or per-shard) indexes
   into the repo-wide `root-index.sqlite`. Disjoint tables (`impact`,
   `test_covers`, `class_refs`) are unioned by key; the config/bean tables are
   **deduplicated**; `property_impact` is recomputed from the merged data.
5. **Impacted** (`impacted`): given a changed file / property / config /
   bean, returns the set of tests to run.

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
| `build`    | per-test coverage → partial index | `--module <dir> [--per-test dir] [--db file]` |
| `refine`   | method-level refinement via git diff | `--db <file> --per-test <dir> --classes <dir> (--diff <file\|-> \| --base <ref> [--head <ref>])` |
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

## Local: per-module workflow

```bash
cd dspace-tcg-phase0
bash tools/test-graph/run.sh static  --module dspace-api
bash tools/test-graph/run.sh config  --module dspace-api --root .
bash tools/test-graph/run.sh build   --module dspace-api --per-test dspace-api/target/per-test
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
  then builds the partial index from the shard's `target/per-test` directory.

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

Each shard observes a **disjoint** set of tests, so `impact`/`test_covers`/
`class_refs` union exactly. The module-level `config_*`/`bean_*` rows are
identical across that module's shards and are collapsed by the dedup step in
`aggregate`. The merged `root-index.sqlite` is therefore content-equivalent to a
single sequential build.

## CI: PR gate (`test-affected.yml`)

Downloads the latest `impact-index` artifact, computes the affected test set
from the PR diff via `affected.sh`, and runs only those tests (UT via
`-Dtest=`, IT via `-Dit.test=`), falling back to the full module suites when a
diff is too large or no index is available.

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
