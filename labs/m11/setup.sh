#!/usr/bin/env bash
# M11 capstone — one-step setup: create cluster + inject faults.
# Usage:
#   bash setup.sh            # full setup
#   bash setup.sh teardown   # remove lab resources (cluster stays)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIR="${HERE}/../clusters/capstone"
CONTEXT="kind-kubeadv-capstone"

if [ "${1:-}" = "teardown" ]; then
  echo "== M11 teardown =="
  K="kubectl --context ${CONTEXT}"
  # Remove faults
  $K taint nodes --all maintenance- 2>/dev/null || true
  $K delete flowschema throttle-serviceaccounts --ignore-not-found 2>/dev/null || true
  $K delete prioritylevelconfiguration capstone-throttle --ignore-not-found 2>/dev/null || true
  $K delete ns capstone-junk --ignore-not-found --wait=false 2>/dev/null || true
  $K delete ns capstone-app --ignore-not-found --wait=false 2>/dev/null || true
  # Restore CoreDNS if backup exists
  if [ -f "${HERE}/corefile-backup.txt" ]; then
    ORIGINAL=$(cat "${HERE}/corefile-backup.txt")
    $K -n kube-system create cm coredns --from-literal="Corefile=${ORIGINAL}" --dry-run=client -o yaml | $K apply -f -
    $K -n kube-system rollout restart deploy/coredns
  fi
  # Restore operator ConfigMap if backup exists
  if [ -f "${HERE}/operator-cm-backup.yaml" ]; then
    $K apply -f "${HERE}/operator-cm-backup.yaml"
    $K -n m5-system delete pod -l app=website-operator --wait=false 2>/dev/null || true
  fi
  # Restore Kueue quota
  $K patch clusterqueue capstone-cq --type=merge -p '{"spec":{"resourceGroups":[{"coveredResources":["cpu","memory"],"flavors":[{"name":"capstone-flavor","resources":[{"name":"cpu","nominalQuota":"4"},{"name":"memory","nominalQuota":"4Gi"}]}]}]}}' 2>/dev/null || true
  echo "== done (cluster kept) =="
  exit 0
fi

echo "=== M11 Capstone Setup ==="
echo ""

# Step 1: ensure capstone cluster exists
echo "--- Step 1: cluster ---"
bash "${CLUSTER_DIR}/create.sh"

# Step 2: inject faults
echo ""
echo "--- Step 2: inject faults ---"
bash "${HERE}/inject.sh"

echo ""
echo "=== Capstone ready for the war-room ==="
echo "Context: ${CONTEXT}"
echo "Teardown: bash ${HERE}/setup.sh teardown"
