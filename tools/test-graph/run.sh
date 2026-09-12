#!/usr/bin/env bash
# Runs the TestGraph single-file Java tool with the classpath it needs
# (JaCoCo core, ASM, SQLite JDBC) resolved from the local Maven repo.
set -euo pipefail

M2="${M2:-$HOME/.m2/repository}"

pick() { # glob prefix -> newest matching jar
  local dir="$1" pat="$2"
  find "$dir" -name "$pat" ! -name '*-sources.jar' 2>/dev/null | sort -V | tail -1
}

JACOCO_CORE="$(pick "$M2/org/jacoco/org.jacoco.core" 'org.jacoco.core-*.jar')"
ASM="$(pick "$M2/org/ow2/asm/asm" 'asm-*.jar')"
ASM_TREE="$(pick "$M2/org/ow2/asm/asm-tree" 'asm-tree-*.jar')"
ASM_COMMONS="$(pick "$M2/org/ow2/asm/asm-commons" 'asm-commons-*.jar')"
SQLITE="$(pick "$M2/org/xerial/sqlite-jdbc" 'sqlite-jdbc-*.jar')"

if [ -z "$JACOCO_CORE" ] || [ -z "$ASM" ] || [ -z "$SQLITE" ]; then
  echo "ERROR: missing a required jar (jacoco-core, asm, sqlite-jdbc) in $M2" >&2
  exit 1
fi

CP="$JACOCO_CORE:$ASM"
[ -n "$ASM_TREE" ] && CP="$CP:$ASM_TREE"
[ -n "$ASM_COMMONS" ] && CP="$CP:$ASM_COMMONS"
CP="$CP:$SQLITE"
DIR="$(cd "$(dirname "$0")" && pwd)"

exec java --class-path "$CP" "$DIR/TestGraph.java" "$@"
