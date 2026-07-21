#!/usr/bin/env bash
# capstone profile — teardown
set -euo pipefail

CLUSTER_NAME="kubeadv-capstone"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "Deleting kind cluster '${CLUSTER_NAME}' ..."
  kind delete cluster --name "${CLUSTER_NAME}"
  echo "Done."
else
  echo "Cluster '${CLUSTER_NAME}' does not exist — nothing to do."
fi
