#!/usr/bin/env bash
# M6 — verify the kwok-scale control plane is up and answering.
set -euo pipefail
CLUSTER="${CLUSTER:-kwok-scale}"
CTX="kwok-${CLUSTER}"

if ! kwokctl get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "FAIL: kwok-scale cluster not found. Create it: bash create.sh"
  exit 1
fi
kwokctl --name "${CLUSTER}" get kubeconfig > "${KUBECONFIG:-/tmp/m6.kubeconfig}"
if kubectl --context "${CTX}" get --raw /healthz >/dev/null 2>&1; then
  N=$(kubectl --context "${CTX}" get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)
  echo "OK: kwok-scale control plane healthy — ${N} fake node(s) Ready."
  echo "context: ${CTX}"
else
  echo "FAIL: API server not answering /healthz. Containers may still be starting."
  exit 1
fi
