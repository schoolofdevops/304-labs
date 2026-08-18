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
CILIUM_VERSION="${CILIUM_VERSION:-1.19.5}"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABS_DIR="$(cd "${PROFILE_DIR}/../../" && pwd)"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "kind cluster '${CLUSTER_NAME}' already exists — reusing it."
  kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null
  if [ "${COURSE_IMAGE_CACHE:-0}" = "1" ]; then
    echo "Loading the pre-pulled Cilium and M7 images into every cluster node ..."
    bash "${LABS_DIR}/tools/preload-course-images.sh" \
      --load-only --cluster "${CLUSTER_NAME}" --scope cilium
  fi
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

CILIUM_ARGS=(
  --version "${CILIUM_VERSION}"
  --set kubeProxyReplacement=true
  --set hubble.enabled=true
  --set hubble.relay.enabled=true
)

if [ "${COURSE_IMAGE_CACHE:-0}" = "1" ]; then
  echo "Loading the pre-pulled Cilium and M7 images into every cluster node ..."
  bash "${LABS_DIR}/tools/preload-course-images.sh" \
    --load-only --cluster "${CLUSTER_NAME}" --scope cilium

  # The normal chart uses tag@digest references. Cache mode uses the same
  # pinned tags so containerd does not need to resolve digests through quay.io.
  CILIUM_ARGS+=(
    --set image.useDigest=false
    --set envoy.image.useDigest=false
    --set operator.image.useDigest=false
    --set hubble.relay.image.useDigest=false
  )
fi

echo "Installing Cilium ${CILIUM_VERSION} (kube-proxy replacement + Hubble) ..."
cilium install "${CILIUM_ARGS[@]}"

echo "Waiting for Cilium to become ready ..."
cilium status --wait --wait-duration 6m

echo "Enabling Hubble ..."
cilium hubble enable

echo ""
echo "cilium-networking profile ready: 1 control-plane + 2 workers (${KIND_IMAGE})"
echo "  CNI: Cilium (eBPF datapath, kube-proxy replacement)"
echo "  Observability: Hubble Relay + CLI"
echo ""
echo "Verify:"
echo "  cilium status"
echo "  hubble observe --follow"
