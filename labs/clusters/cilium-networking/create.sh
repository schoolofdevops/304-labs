#!/usr/bin/env bash
# cilium-networking profile — create
# kind cluster with Cilium CNI (no default CNI, no kube-proxy).
# Hubble enabled (Relay + CLI). Used by M7 lab.
#
# Cilium owns: CNI (pod networking) + service routing (replaces kube-proxy) +
# network policy enforcement + observability (Hubble).
#
# Idempotent: safe to re-run; exits 0 if the cluster already exists and is healthy.
set -euo pipefail

CLUSTER_NAME="cilium-networking"
KIND_IMAGE="${KIND_IMAGE:-kindest/node:v1.35.0}"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "kind cluster '${CLUSTER_NAME}' already exists — reusing it."
  kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null
  exit 0
fi

echo "Creating kind cluster '${CLUSTER_NAME}' (image: ${KIND_IMAGE}, NO default CNI, NO kube-proxy) ..."
kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_IMAGE}" --wait 120s --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  kubeProxyMode: "none"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

echo "Installing Cilium (kube-proxy replacement + Hubble) ..."
cilium install \
  --set kubeProxyReplacement=true \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true

echo "Waiting for Cilium to become ready ..."
cilium status --wait --wait-duration 3m

echo "Enabling Hubble ..."
cilium hubble enable --wait

echo ""
echo "cilium-networking profile ready: 1 control-plane + 2 workers (${KIND_IMAGE})"
echo "  CNI: Cilium (eBPF datapath, kube-proxy replacement)"
echo "  Observability: Hubble Relay + CLI"
echo ""
echo "Verify:"
echo "  cilium status"
echo "  hubble observe --follow"
