#!/usr/bin/env bash
# core-internals profile — create
# kind cluster "kubeadv-core": 1 control-plane + 1 worker.
# Node image pinned via KIND_IMAGE (defaults to the course-tested v1.35.x tag).
# Idempotent: safe to re-run; exits 0 if the cluster already exists.
set -euo pipefail

CLUSTER_NAME="kubeadv-core"
KIND_IMAGE="${KIND_IMAGE:-kindest/node:v1.35.0}"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "kind cluster '${CLUSTER_NAME}' already exists — reusing it."
  kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null
  exit 0
fi

echo "Creating kind cluster '${CLUSTER_NAME}' (image: ${KIND_IMAGE}) ..."
kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_IMAGE}" --wait 120s --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
EOF

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
echo "core-internals profile ready: 1 control-plane + 1 worker (${KIND_IMAGE})"
