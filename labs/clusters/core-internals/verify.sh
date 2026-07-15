#!/usr/bin/env bash
# core-internals profile — verify
# Asserts the kubeadv-core cluster exists, both nodes are Ready,
# and the API server answers. Read-only and idempotent.
set -euo pipefail

CLUSTER_NAME="kubeadv-core"
CTX="kind-${CLUSTER_NAME}"

if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "FAIL: kind cluster '${CLUSTER_NAME}' not found. Run create.sh first." >&2
  exit 1
fi

echo "Waiting for all nodes to be Ready ..."
kubectl --context "${CTX}" wait --for=condition=Ready node --all --timeout=180s

NODE_COUNT="$(kubectl --context "${CTX}" get nodes --no-headers | wc -l | tr -d ' ')"
if [ "${NODE_COUNT}" -ne 2 ]; then
  echo "FAIL: expected 2 nodes (1 control-plane + 1 worker), found ${NODE_COUNT}." >&2
  exit 1
fi

if ! kubectl --context "${CTX}" get node "${CLUSTER_NAME}-worker" >/dev/null; then
  echo "FAIL: worker node '${CLUSTER_NAME}-worker' not found." >&2
  exit 1
fi

kubectl --context "${CTX}" get --raw='/readyz' >/dev/null
echo "OK: core-internals profile verified — 2/2 nodes Ready, API server healthy."

if kubectl --context "${CTX}" -n kube-system get pod \
     "kube-apiserver-${CLUSTER_NAME}-control-plane" \
     -o jsonpath='{.spec.containers[0].command}' 2>/dev/null \
     | grep -q 'audit-policy-file'; then
  echo "audit mode: ENABLED — stream with: kubectl logs -n kube-system kube-apiserver-${CLUSTER_NAME}-control-plane"
else
  echo "audit mode: off — this cluster predates the audit default; recreate once: bash teardown.sh && bash create.sh"
fi

kubectl --context "${CTX}" get nodes
