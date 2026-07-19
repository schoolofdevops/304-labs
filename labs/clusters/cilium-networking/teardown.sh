#!/usr/bin/env bash
# cilium-networking profile — teardown
# Deletes the cilium-networking kind cluster and recreates core-internals
# (the persistent cluster used by most modules).
set -euo pipefail

CLUSTER_NAME="cilium-networking"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_CREATE="${PROFILE_DIR}/../core-internals/create.sh"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "Deleting kind cluster '${CLUSTER_NAME}' ..."
  kind delete cluster --name "${CLUSTER_NAME}"
  echo "Deleted."
else
  echo "kind cluster '${CLUSTER_NAME}' does not exist — nothing to tear down."
fi

if [ -x "${CORE_CREATE}" ]; then
  echo ""
  echo "Recreating core-internals cluster ..."
  bash "${CORE_CREATE}"
fi
