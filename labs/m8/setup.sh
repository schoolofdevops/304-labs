#!/usr/bin/env bash
# M8 lab setup — install DRA example driver + Kueue on core-internals
# Prerequisite: core-internals cluster already running (labs/clusters/core-internals/create.sh)
set -euo pipefail

CONTEXT="kind-kubeadv-core"
KUBECTL="kubectl --context ${CONTEXT}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KUEUE_VERSION="v0.17.2"

echo "=== M8 Lab Setup: DRA Example Driver + Kueue ==="

if [ "${COURSE_IMAGE_CACHE:-0}" = "1" ]; then
  echo "Loading the pre-pulled M8 images into every core-internals node ..."
  bash "${LABS_DIR}/tools/preload-course-images.sh" \
    --load-only --cluster kubeadv-core --scope core
fi

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

# ---- Part 2: Kueue ----
echo ""
echo "--- Installing Kueue ${KUEUE_VERSION} ---"
echo "    (first pull ~2 min for registry.k8s.io image)"
KUEUE_RAW="$(mktemp "${TMPDIR:-/tmp}/kueue-raw.XXXXXX")"
KUEUE_LOCAL="$(mktemp "${TMPDIR:-/tmp}/kueue-local.XXXXXX")"
trap 'rm -f "${KUEUE_RAW}" "${KUEUE_LOCAL}"' EXIT
curl -fsSL \
  "https://github.com/kubernetes-sigs/kueue/releases/download/${KUEUE_VERSION}/manifests.yaml" \
  -o "${KUEUE_RAW}"
sed 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/' \
  "${KUEUE_RAW}" > "${KUEUE_LOCAL}"
${KUBECTL} apply --server-side -f "${KUEUE_LOCAL}"

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
echo "Kueue: batch admission controller (${KUEUE_VERSION})"
echo "Lab namespace: m8-lab"
echo ""
echo "Verify:"
echo "  kubectl --context ${CONTEXT} get resourceslices"
echo "  kubectl --context ${CONTEXT} get deviceclasses"
echo "  kubectl --context ${CONTEXT} -n kueue-system get pods"
