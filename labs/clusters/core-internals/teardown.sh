#!/usr/bin/env bash
# core-internals profile — teardown
# Deletes the kubeadv-core kind cluster entirely (all workloads with it).
# Idempotent: exits 0 if the cluster is already gone.
# NOTE: only one cluster profile runs at a time — run this before creating
# a different profile (e.g. etcd-failure).
set -euo pipefail

CLUSTER_NAME="kubeadv-core"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  kind delete cluster --name "${CLUSTER_NAME}"
  echo "core-internals profile torn down: cluster '${CLUSTER_NAME}' deleted."
else
  echo "kind cluster '${CLUSTER_NAME}' already absent — nothing to do."
fi
