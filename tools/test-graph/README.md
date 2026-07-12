# Test Class Graph (test-graph)

A static + dynamic analysis tool that maps DSpace source changes to the exact tests that must re-run. It builds a SQLite index correlating every source class, property, config file, and Spring bean declaration to their test coverage — then uses that index to select only affected tests on each PR.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  dspace-test-trace (JUnit listener)                         │
│  PerTestCoverage: JMX → JaCoCo → per-test .exec files       │
└──────────────────────────┬───────────────────────────────────┘
                           │ target/per-test/*.exec
┌──────────────────────────▼───────────────────────────────────┐
│  TestGraph.java (single-file Java tool)                     │
│                                                              │
│  1. static   — ASM class hierarchy + method calls            │
│  2. config   — XML/properties/spring bean mapping            │
│  3. build    — per-test .exec → coverage → SQLite            │
│  4. refine   — git diff → method-level impacted tests        │
│  5. impacted — query the index for a specific file/property   │
│  6. validate — integrity checks on the index                 │
│  7. aggregate — merge per-module indexes → root index         │
└──────────────────────────────────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────┐
│  SQLite impact-index.sqlite                                  │
│  Tables: class_refs, test_covers, impact,                    │
│          property_refs, bean_refs, config_keys,              │
│          bean_decls, property_impact, config_consumers        │
└──────────────────────────────────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────┐
│  CI Workflows                                                │
│  impact-index.yml  — builds baseline on main push            │
│  test-affected.yml — runs only affected tests on PR          │
└──────────────────────────────────────────────────────────────┘
```

## Prerequisites

- **JDK 21** (for single-file source-code program execution)
- **Maven local repo** with:
  - `org.jacoco:org.jacoco.core` (0.8.x)
  - `org.ow2.asm:asm` (9.x)
  - `org.xerial:sqlite-jdbc` (3.x)
- **DSpace built** with `test-class-graph` profile active

## Quick Start

### 1. Build with per-test coverage

```bash
# Build DSpace with the test-class-graph profile
mvn install -P-assembly -Ptest-class-graph -DskipTests

# Run unit tests (generates per-test .exec files)
mvn test -pl dspace-api -Ptest-class-graph

# Or run integration tests too
mvn verify -pl dspace-api -Ptest-class-graph \
  -DskipUnitTests=false -DskipIntegrationTests=false
```

### 2. Build the full pipeline (single module)

```bash
cd dspace-api
tools/test-graph/run.sh static --module dspace-api
tools/test-graph/run.sh config --module dspace-api --root .
tools/test-graph/run.sh build  --module dspace-api
```

### 3. Build the repo-wide index

```bash
tools/test-graph/phase-all.sh --it --root .
# Output: target/test-graph/root-index.sqlite
```

### 4. Query impacted tests

```bash
TG="tools/test-graph/run.sh"

# Java source file
$TG impacted --db target/test-graph/root-index.sqlite \
  --file dspace-api/src/main/java/org/dspace/content/ItemServiceImpl.java

# Configuration property
$TG impacted --db target/test-graph/root-index.sqlite \
  --property mail.server

# Spring bean type
$TG impacted --db target/test-graph/root-index.sqlite \
  --bean ItemService

# Spring bean XML file
$TG impacted --db target/test-graph/root-index.sqlite \
  --beanfile dspace-api/src/main/resources/spring/api/discovery.xml

# XML config file (submission-forms, registries, item-submission)
$TG impacted --db target/test-graph/root-index.sqlite \
  --configfile dspace/config/submission-forms.xml
```

### 5. Method-level refinement

```bash
# Refine from git diff (base...HEAD)
$TG refine --db target/test-graph/root-index.sqlite \
  --base HEAD~3 --head HEAD \
  --per-test target/per-test --classes target/classes

# Refine a specific config file change
$TG refine --db target/test-graph/root-index.sqlite \
  --configfile dspace/config/submission-forms.xml \
  --diff /tmp/form-change.diff \
  --per-test target/per-test --classes target/classes
```

## Commands Reference

### `static` — Build static class graph

Extracts class hierarchy and method call edges via ASM bytecode analysis.

```
run.sh static [--module <name>] [--out <dir>]
```

| Option    | Default                  | Description                    |
|-----------|--------------------------|--------------------------------|
| `--module`| current dir basename     | Maven module name              |
| `--out`   | `target/test-graph`      | Output directory               |

**Output:** `class-edges.tsv`, `class-hierarchy.tsv` in the output directory.

### `config` — Map configuration references

Scans XML/properties/YAML for property keys, Spring bean declarations, and config-to-class consumer mappings.

```
run.sh config [--module <name>] [--root <dir>] [--out <dir>]
```

| Option    | Default                  | Description                    |
|-----------|--------------------------|--------------------------------|
| `--module`| current dir basename     | Maven module name              |
| `--root`  | none                     | Repo root for cross-module scan|
| `--out`   | `target/test-graph`      | Output directory               |

**Output:** `property-refs.tsv`, `bean-decls.tsv`, `config_keys.tsv`, `config_consumers.tsv`.

**Supported config files:**
- `dspace.cfg` / `*.properties` — key=value property extraction
- `dspace/config/*.xml` — `config_keys.tsv` entries + consumer-class mappings
- `**/spring/*.xml` / `*-services.xml` / `*-beans.xml` — Spring bean declarations
- `dspace/config/submission-forms.xml` → parsed with `DCInputsReader` consumer map
- `dspace/config/item-submission.xml` → parsed with `SubmissionConfigReader` consumer map
- `dspace/config/registries/*.xml` → mapped to `MetadataImporter` + authority services

### `build` — Build per-module impact index

Combines static graph edges, per-test coverage data, and config references into a SQLite database.

```
run.sh build [--module <name>] [--per-test <dir>] [--edges <dir>]
             [--config <dir>] [--db <file>]
```

| Option      | Default                         | Description                      |
|-------------|---------------------------------|----------------------------------|
| `--module`  | current dir basename            | Maven module name                |
| `--per-test`| `target/per-test`               | Directory with `.exec` files     |
| `--edges`   | `target/test-graph`             | Directory with `class-edges.tsv` |
| `--config`  | `target/test-graph`             | Directory with config TSV files  |
| `--db`      | `target/test-graph/impact-index.sqlite` | Output SQLite file     |

**SQLite Schema:**

```sql
class_refs(from_c TEXT, to_c TEXT, kind TEXT)    -- class hierarchy + call edges
test_covers(test TEXT, class TEXT)                -- per-test → class coverage
impact(class TEXT, test TEXT)                     -- transitive impact closure
property_refs(key TEXT, class TEXT)               -- property → class mapping
bean_refs(bean_type TEXT, bean_id TEXT, file TEXT) -- bean type → file mapping
config_keys(file TEXT, key TEXT)                  -- config file → property keys
bean_decls(file TEXT, bean_type TEXT, bean_id TEXT) -- bean declaration locations
property_impact(key TEXT, test TEXT)              -- property → test impact
config_consumers(file TEXT, class TEXT)           -- config file → consumer classes
```

### `refine` — Method-level refinement

Reduces class-level impact to method-level by analyzing what actually changed in a diff.

```
run.sh refine --db <index> --base <ref> [--head <ref>]
              [--per-test <dir>] [--classes <dir>]
              [--configfile <path>] [--diff <file>]
              [--csv]
```

| Option        | Required | Description                                    |
|---------------|----------|------------------------------------------------|
| `--db`        | yes      | Path to the impact index                       |
| `--base`      | yes      | Git ref (SHA, branch) for diff base            |
| `--head`      | no       | Git ref for diff head (default: HEAD)          |
| `--per-test`  | no       | Directory with per-test `.exec` files          |
| `--classes`   | no       | Directory with compiled `.class` files         |
| `--configfile`| no       | Config file path for config-only refinement    |
| `--diff`      | no       | Pre-generated diff file (`-` for stdin)        |
| `--csv`       | no       | Output only CSV test names (no stats)          |

**Examples:**

```bash
# Method-level from git diff
run.sh refine --db index.sqlite --base HEAD~5 --head HEAD \
  --per-test target/per-test --classes target/classes

# Config-file refinement
run.sh refine --db index.sqlite --configfile submission-forms.xml \
  --base HEAD~1 --head HEAD --per-test target/per-test --classes target/classes

# Pipe a custom diff
cat /tmp/my.diff | run.sh refine --db index.sqlite --diff - \
  --per-test target/per-test --classes target/classes
```

### `impacted` — Query impacted tests

Query the index for tests affected by changing a specific file, property, bean, or config.

```
run.sh impacted --db <index> [--file <path>] [--property <key>]
                [--bean <type>] [--beanfile <path>] [--configfile <path>]
                [--csv]
```

| Option        | Description                                          |
|---------------|------------------------------------------------------|
| `--file`      | Java source file path                                |
| `--property`  | Configuration property key (e.g., `mail.server`)     |
| `--bean`      | Spring bean type name (e.g., `ItemService`)          |
| `--beanfile`  | Spring XML file containing bean declarations         |
| `--configfile`| XML config file (submission-forms, registries, etc.) |
| `--csv`       | Output only CSV test names                           |

### `aggregate` — Merge module indexes

Merge multiple per-module indexes into a single root index.

```
run.sh aggregate --out <file> --db <file> [--db2 <file>] [--db3 <file>] ...
```

### `validate` — Integrity checks

Run integrity checks on the index (referential integrity, orphans, coverage stats).

```
run.sh validate --db <index> [--module <name>] [--per-test <dir>]
```

## Per-Module Workflow

The typical per-module workflow runs three steps:

```bash
# Step 1: Static graph (ASM bytecode analysis)
tools/test-graph/run.sh static --module dspace-api

# Step 2: Config references (XML, properties, Spring beans)
tools/test-graph/run.sh config --module dspace-api --root .

# Step 3: Build the index (coverage + graph + config → SQLite)
tools/test-graph/run.sh build --module dspace-api
```

Each produces intermediate files in `target/test-graph/`:

| File                  | Produced by | Consumed by |
|-----------------------|-------------|-------------|
| `class-edges.tsv`     | `static`    | `build`     |
| `class-hierarchy.tsv` | `static`    | `build`     |
| `property-refs.tsv`   | `config`    | `build`     |
| `bean-decls.tsv`      | `config`    | `build`     |
| `config_keys.tsv`     | `config`    | `build`     |
| `config_consumers.tsv`| `config`    | `build`     |
| `impact-index.sqlite` | `build`     | `impacted`, `refine`, `aggregate` |

## Repo-Wide Pipeline

`phase-all.sh` orchestrates the full pipeline across all modules:

```bash
tools/test-graph/phase-all.sh [options]
```

| Option          | Description                                      |
|-----------------|--------------------------------------------------|
| `--run-tests`   | Run `mvn test` per module (default)              |
| `--skip-tests`  | Reuse existing `.exec` files                     |
| `--it`          | Also run integration tests (`mvn verify`)        |
| `--modules "a b"`| Explicit module list (default: all dspace-*)   |
| `--root <dir>`  | Repo root for cross-module config scan           |
| `--out <file>`  | Root index output (default: `target/test-graph/root-index.sqlite`) |
| `--offline`     | Run Maven in offline mode                        |

## CI Integration

### Baseline Index (main branch)

**Workflow:** `.github/workflows/impact-index.yml`

Triggered on every push to `main`. Builds the repo-wide impact index and publishes it as a GitHub Actions artifact (`impact-index`, 90-day retention).

Steps:
1. Checkout + JDK 21
2. Fetch JaCoCo/ASM/SQLite JDBC dependencies
3. Install `dspace-test-trace` listener
4. Assemble test environment
5. Run `phase-all.sh --it` (unit + integration tests)
6. Validate index integrity
7. Upload `root-index.sqlite` as artifact

### PR Test Selection

**Workflow:** `.github/workflows/test-affected.yml`

Triggered on every pull request. Downloads the baseline index and runs only affected tests.

Steps:
1. Checkout PR head with full history
2. Download baseline `impact-index` artifact
3. Compute affected tests via `affected.sh` (diff analysis)
4. Run only affected tests:
   - Unit tests: `mvn test -Dtest=<csv>`
   - Integration tests: `mvn verify -Dit.test=<csv>`
5. Fallback: if no baseline index, run full suites of touched modules

### affected.sh

The `affected.sh` script bridges the diff and test selection:

```bash
tools/test-graph/affected.sh --db <index> --base <sha> [--head <sha>]
                              [--out <dir>] [--per-test <dir>] [--classes <dir>]
```

**Output files:**
- `ut.csv` — comma-separated unit test class names
- `it.csv` — comma-separated integration test class names
- `modules.txt` — newline-separated touched module names

**File type routing:**
- `*.java` in `src/main/java/` → `impacted --file`
- `*.java` in `src/test/java/` → self (changed test must re-run)
- `*.cfg`, `*.properties`, `*.yml`, `*.yaml` → `impacted --configfile`
- `spring/*.xml`, `*-services.xml`, `*-beans.xml` → `impacted --beanfile`
- `*.xml` (submission-forms, registries, item-submission) → `refine --configfile` (if per-test available) or `impacted --configfile`

## Maven Profile

The `test-class-graph` profile (defined in root `pom.xml`) enables per-test coverage collection:

```xml
<profile>
  <id>test-class-graph</id>
  <properties>
    <argLine>
      -javaagent:${path.to.jacoco.agent}=destfile=target/per-test/jacoco.exec,output=none
    </argLine>
  </properties>
  <dependencies>
    <dependency>
      <groupId>org.dspace</groupId>
      <artifactId>dspace-test-trace</artifactId>
      <version>${project.version}</version>
    </dependency>
  </dependencies>
</profile>
```

The `PerTestCoverage` listener (`dspace-test-trace` module) communicates with the JaCoCo agent via JMX (`org.jacoco:type=Runtime`) to dump and reset execution data after each test method, writing individual `.exec` files named `<TestClass>.<method>.exec`.

## Database Statistics

After a full build with `phase-all.sh --it`:

| Table              | Typical rows | Description                          |
|--------------------|-------------|--------------------------------------|
| `class_refs`       | ~10,000     | Class hierarchy + call edges         |
| `test_covers`      | ~1,600,000  | Per-test → class coverage            |
| `impact`           | ~1,880,000  | Transitive impact closure            |
| `property_refs`    | ~500        | Config property → class mapping      |
| `bean_refs`        | ~300        | Spring bean type → file mapping      |
| `config_keys`      | ~400        | Config file → property key mapping   |
| `bean_decls`       | ~500        | Bean declaration locations           |
| `property_impact`  | ~50,000     | Property → test impact               |
| `config_consumers` | ~600        | Config file → consumer class mapping |

## Troubleshooting

### "No baseline index" in CI

The `test-affected.yml` workflow falls back to running full module suites when no baseline artifact exists. Ensure `impact-index.yml` has run at least once on `main`.

### `ArrayIndexOutOfBoundsException` in config_keys

Malformed XML comments can produce TSV entries with fewer than 2 columns. The tool now guards against this with `if (r.length < 2) continue;`.

### Config file returns 0 tests

Ensure `config_consumers.tsv` exists in the config output directory. This file maps XML config files (submission-forms, registries, item-submission) to their consumer classes. Without it, `--configfile` queries for these files return empty results.

### Missing `config_consumers` table

If building with an older `TestGraph.java` that lacks the `config_consumers` table creation in `buildCmd`, rebuild the tool from source. The table is now created alongside other DDL tables.

## File Inventory

| File                      | Purpose                                        |
|---------------------------|------------------------------------------------|
| `TestGraph.java`          | Single-file Java tool (all commands)           |
| `run.sh`                  | Classpath resolver + Java executor             |
| `phase-all.sh`            | Repo-wide build pipeline                       |
| `affected.sh`             | Diff → affected test list                      |
| `README.md`               | This file                                      |

## Branch: feature/test-class-graph-phase0

Commits on this branch:

```
2528702 test-graph: fix buildCmd missing config_consumers table + guard malformed entries
311b694 test-graph: per-entity config refinement + fix pathToFqcn FQCN detection
29ff042 test-graph: config-aware method-level refinement (refine --configfile)
7f4e7db test-graph: map XML metadata/form config files to tests via curated consumer map
ed9cf44 Phase 3b: CI runs only tests affected by a PR (baseline index + diff selection)
ec69d7f Phase 2: method-level refinement via git diff (refine command)
81478e9 Phase 3: GitHub Actions workflow to build & publish impact-index.sqlite
067577a Phase 0.5.2: repo-wide aggregation pipeline (phase-all.sh) + cross-module index
839bfa9 feat: add config/property/bean impact mapping (Phase 0.5.1)
d31ea46 feat: add per-test coverage + class dependency graph for change impact
```
