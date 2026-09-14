#!/usr/bin/env bash
# Shared, single-source definitions for the affected-test pipeline (review G9).
#
# The workflows source this file so the JaCoCo plugin version and the
# blast-radius surface are defined exactly once. Keep it dependency-free
# (bash + coreutils + awk only): it is sourced by CI steps and by the local
# harness fixtures.

# ---------------------------------------------------------------------------
# jacoco_version [pom.xml]
# Print the version of the jacoco-maven-plugin declared in pluginManagement.
# ---------------------------------------------------------------------------
jacoco_version() {
  awk 'BEGIN{RS="</plugin>"} /<artifactId>[[:space:]]*jacoco-maven-plugin[[:space:]]*<\/artifactId>/{ if (match($0,/<version>[^<]+<\/version>/)) { s=substr($0,RSTART,RLENGTH); gsub(/<\/?version>/,"",s); print s; exit } }' "${1:-pom.xml}"
}

# ---------------------------------------------------------------------------
# Blast radius: a change to any of these paths invalidates the whole index,
# so the gate must fall back to the full reactor rather than a narrowed set.
# ---------------------------------------------------------------------------
BLAST_RE='(^|/)pom\.xml$|^dspace/config/|^dspace-test-trace/|^src/|^\.github/|^\.mvn/|^tools/|(^|/)Dockerfile|(^|/)docker-compose|(^|/)checkstyle\.xml$'

# Genuinely inert changes: documentation and licence text cannot alter which
# behaviour the tests exercise, so they may skip a rebuild.
INERT_RE='\.md$|\.adoc$|^LICENSE$|^NOTICE$'
