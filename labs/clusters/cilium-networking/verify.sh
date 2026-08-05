#!/usr/bin/env bash
# cilium-networking profile — verify
# Asserts the cilium-networking cluster exists, nodes are Ready,
# Cilium is healthy, and Hubble Relay is running. Read-only and idempotent.
set -euo pipefail

CLUSTER_NAME="cilium-networking"
CTX="kind-${CLUSTER_NAME}"

if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "FAIL: kind cluster '${CLUSTER_NAME}' not found. Run create.sh first." >&2
  exit 1
fi

echo "Waiting for all nodes to be Ready ..."
kubectl --context "${CTX}" wait --for=condition=Ready node --all --timeout=180s

NODE_COUNT="$(kubectl --context "${CTX}" get nodes --no-headers | wc -l | tr -d ' ')"
if [ "${NODE_COUNT}" -ne 3 ]; then
  echo "FAIL: expected 3 nodes (1 control-plane + 2 workers), found ${NODE_COUNT}." >&2
  exit 1
fi

kubectl --context "${CTX}" get --raw='/readyz' >/dev/null

echo "Checking Cilium status ..."
if ! cilium status --context "${CTX}" --wait --wait-duration 30s >/dev/null 2>&1; then
  echo "FAIL: Cilium is not healthy." >&2
  cilium status --context "${CTX}" 2>&1
  exit 1
fi

if ! kubectl --context "${CTX}" -n kube-system get deploy hubble-relay >/dev/null 2>&1; then
  echo "FAIL: Hubble Relay deployment not found." >&2
  exit 1
fi

HUBBLE_READY="$(kubectl --context "${CTX}" -n kube-system get deploy hubble-relay \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
if [ "${HUBBLE_READY:-0}" -lt 1 ]; then
  echo "FAIL: Hubble Relay has no ready replicas." >&2
  exit 1
fi

echo "OK: cilium-networking profile verified — 3/3 nodes Ready, Cilium healthy, Hubble Relay running."
kubectl --context "${CTX}" get nodes
