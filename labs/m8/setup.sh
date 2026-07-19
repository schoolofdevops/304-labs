#!/usr/bin/env bash
# M8 lab setup — install DRA example driver + Kueue on core-internals
# Prerequisite: core-internals cluster already running (labs/clusters/core-internals/create.sh)
set -euo pipefail

CONTEXT="kind-kubeadv-core"
KUBECTL="/opt/homebrew/bin/kubectl --context ${CONTEXT}"

echo "=== M8 Lab Setup: DRA Example Driver + Kueue ==="

# ---- Part 1: DRA example driver v0.4.0 (simulated GPUs) ----
echo ""
echo "--- Installing DRA example driver v0.4.0 ---"
echo "    (first pull ~2 min for registry.k8s.io image)"

helm upgrade -i dra-example-driver \
  oci://registry.k8s.io/dra-example-driver/charts/dra-example-driver \
  --version 0.4.0 \
  --namespace dra-example-driver --create-namespace \
  --kube-context "${CONTEXT}" \
  --wait --timeout 300s

echo "DRA driver installed. Checking ResourceSlices ..."
${KUBECTL} get resourceslices -o wide

# ---- Part 2: Kueue v0.17.2 ----
echo ""
echo "--- Installing Kueue v0.17.2 ---"
echo "    (first pull ~2 min for registry.k8s.io image)"
${KUBECTL} apply --server-side -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.17.2/manifests.yaml

echo "Waiting for Kueue controller ..."
${KUBECTL} -n kueue-system wait --for=condition=ready pod -l control-plane=controller-manager --timeout=180s

echo "Kueue installed."
${KUBECTL} -n kueue-system get pods

# ---- Part 3: Create lab namespace ----
echo ""
echo "--- Creating m8-lab namespace ---"
${KUBECTL} create namespace m8-lab --dry-run=client -o yaml | ${KUBECTL} apply -f -

echo ""
echo "=== Setup complete ==="
echo "DRA example driver: 8 simulated GPUs per worker node (v0.4.0)"
echo "Kueue: batch admission controller (v0.17.2)"
echo "Lab namespace: m8-lab"
echo ""
echo "Verify:"
echo "  kubectl --context ${CONTEXT} get resourceslices"
echo "  kubectl --context ${CONTEXT} get deviceclasses"
echo "  kubectl --context ${CONTEXT} -n kueue-system get pods"
