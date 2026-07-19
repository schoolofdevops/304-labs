#!/usr/bin/env bash
# M6 — delete the kwok-scale cluster and hand the machine back to core-internals.
#
# The scaling experiment is done on a throwaway cluster; nothing here is persistent.
# This recreates the persistent core-internals profile so M7+ continue on it.
#
# Usage:  bash teardown.sh
# Env: PATH + DOCKER_HOST (see create.sh).
set -euo pipefail

CLUSTER="${CLUSTER:-kwok-scale}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Deleting kwokctl cluster '${CLUSTER}' ..."
kwokctl delete cluster --name "${CLUSTER}" 2>/dev/null || true

echo "==> Recreating the persistent core-internals cluster (idempotent, ~40s) ..."
if [ -x "${HERE}/../core-internals/create.sh" ] || [ -f "${HERE}/../core-internals/create.sh" ]; then
  bash "${HERE}/../core-internals/create.sh"
else
  echo "   (core-internals/create.sh not found — recreate it manually before M7)"
fi

echo "==> Done. kwok-scale gone; core-internals is back for the next module."
