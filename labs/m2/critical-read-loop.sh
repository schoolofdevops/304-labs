#!/usr/bin/env bash
# M2 — steady, light ConfigMap reads from the critical controller identity.
set -euo pipefail

DURATION="${DURATION:-45}"
INTERVAL="${INTERVAL:-0.2}"
CONTEXT="${CONTEXT:-kind-kubeadv-core}"
AS="${AS:-system:serviceaccount:nimbusai:nimbusai-critical}"

END=$(( $(date +%s) + DURATION ))
OK=0
ERR=0

echo "Critical reads: one nimbusai ConfigMap LIST every ${INTERVAL}s for ${DURATION}s as ${AS}"
while [ "$(date +%s)" -lt "${END}" ]; do
  if kubectl --context "${CONTEXT}" --as="${AS}" get configmaps -n nimbusai -o name \
      --request-timeout=5s >/dev/null 2>&1; then
    OK=$((OK + 1))
  else
    ERR=$((ERR + 1))
  fi
  sleep "${INTERVAL}"
done

echo "Critical read loop complete: ${OK} reads succeeded, ${ERR} failed."
