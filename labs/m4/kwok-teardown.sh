#!/usr/bin/env bash
# M4 — remove KWOK (fake nodes + in-cluster controller) from core-internals.
# Leaves the persistent cluster and its real 2 nodes intact (kept for M5).
# Thin wrapper over `kwok-setup.sh teardown`. bash-3.2 compatible.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${HERE}/kwok-setup.sh" teardown
