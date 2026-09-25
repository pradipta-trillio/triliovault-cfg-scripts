#!/bin/bash
#
# restore_templates.sh — materialise the generated templates/bin/*.tpl files
#                        from their committed *.tpl.in sources.
#
# Four files under templates/bin/ are produced at install time rather than
# committed, because they carry cloud-specific content (ceph mon addresses,
# nova-compute.conf, the injected nova init script). They are listed in
# openstack-helm/.gitignore; the committed sources are the *.tpl.in stubs.
#
# They cannot simply be absent: configmap-etc-*.yaml pulls each one in through
# helm-toolkit.utils.template, which resolves to `include <template path>`, and
# `include` on a missing path is a hard render failure — not an empty string.
# So every path that renders the chart has to materialise them first.
#
# TWO MODES, and picking the wrong one is a live bug:
#
#   --if-missing  (default)  Write only the files that do not exist. This is the
#                 bootstrap case: a fresh clone, `make`, `helm lint`, or the
#                 installer's preflight. It must never clobber a rendered
#                 template, because a rendered datamover template has had its
#                 <INJECT_*> markers replaced with the cloud's nova config. Put
#                 the stub back and you ship a configmap containing the literal
#                 string "<INJECT_CONFIG_FILES>" — a bash syntax error that
#                 crash-loops the datamover.
#
#   --force       Restore ALL four unconditionally. Only sync_nova_compute.sh
#                 wants this, immediately before it injects: the injection
#                 consumes the marker lines, so without a restore first a second
#                 run finds no marker and silently injects nothing.
#
# Usage:  ./restore_templates.sh [--if-missing|--force]
#         Run from utils/, like every other script here (though it resolves its
#         own paths, so any CWD works).
#
set -euo pipefail

MODE="if-missing"
case "${1:-}" in
  --force)       MODE="force" ;;
  --if-missing|"") ;;
  *) echo "usage: $0 [--if-missing|--force]" >&2; exit 2 ;;
esac

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/bin" && pwd)"

FILES=(
  _triliovault-datamover-init.sh.tpl
  _triliovault-datamover.sh.tpl
  _triliovault-ceph.conf.tpl
  _triliovault-nova-compute.conf.tpl
)

written=0
for f in "${FILES[@]}"; do
  if [[ ! -f "$BIN_DIR/$f.in" ]]; then
    echo "ERROR: missing pristine source $BIN_DIR/$f.in" >&2
    exit 1
  fi
  if [[ "$MODE" == "force" || ! -f "$BIN_DIR/$f" ]]; then
    cp -f "$BIN_DIR/$f.in" "$BIN_DIR/$f"
    echo "written   $f"
    written=$((written + 1))
  else
    echo "kept      $f (already rendered)"
  fi
done

echo "templates/bin: $written file(s) written from *.tpl.in (mode: $MODE)"
