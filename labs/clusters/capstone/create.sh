#!/usr/bin/env bash
# capstone profile — create
# Kind cluster "kubeadv-capstone": 1 control-plane + 2 workers.
# Same audit + etcd knobs as core-internals, plus Kueue + M5 Website operator.
# Two workers so the scheduling fault (tainted node) leaves one healthy node
# for system workloads.
#
# Idempotent: safe to re-run; exits 0 if the cluster already exists.
set -euo pipefail

CLUSTER_NAME="kubeadv-capstone"
KIND_IMAGE="${KIND_IMAGE:-kindest/node:v1.35.0}"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABS_DIR="$(cd "${PROFILE_DIR}/../../" && pwd)"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "kind cluster '${CLUSTER_NAME}' already exists — reusing it."
  kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null
  exit 0
fi

echo "Creating kind cluster '${CLUSTER_NAME}' (image: ${KIND_IMAGE}, 1 CP + 2 workers) ..."
kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_IMAGE}" --wait 120s --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: ${PROFILE_DIR}/audit-policy.yaml
        containerPath: /etc/kubernetes/policies/audit-policy.yaml
        readOnly: true
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            audit-policy-file: /etc/kubernetes/policies/audit-policy.yaml
            audit-log-path: "-"
          extraVolumes:
            - name: audit-policy
              hostPath: /etc/kubernetes/policies/audit-policy.yaml
              mountPath: /etc/kubernetes/policies/audit-policy.yaml
              readOnly: true
              pathType: File
        etcd:
          local:
            extraArgs:
              quota-backend-bytes: "268435456"
              listen-metrics-urls: "http://0.0.0.0:2381"
  - role: worker
  - role: worker
EOF

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

# ---- Install Kueue ----
echo ""
echo "Installing Kueue v0.17.2 ..."
kubectl apply --server-side \
  -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.17.2/manifests.yaml \
  --context "kind-${CLUSTER_NAME}"
echo "Waiting for Kueue controller ..."
kubectl -n kueue-system wait --for=condition=ready pod \
  -l control-plane=controller-manager --timeout=180s \
  --context "kind-${CLUSTER_NAME}"

# ---- Install M5 Website CRD + operator ----
echo ""
echo "Installing Website CRD + operator ..."
kubectl apply -f "${LABS_DIR}/m5/website-crd.yaml" --context "kind-${CLUSTER_NAME}"
kubectl wait --for condition=established --timeout=30s \
  crd/websites.kubeadv.io --context "kind-${CLUSTER_NAME}"
kubectl apply -f "${LABS_DIR}/m5/operator.yaml" --context "kind-${CLUSTER_NAME}"
kubectl -n m5-system rollout status deploy/website-operator --timeout=240s \
  --context "kind-${CLUSTER_NAME}"

echo ""
echo "=== capstone profile ready ==="
echo "Cluster: ${CLUSTER_NAME} (${KIND_IMAGE})"
echo "Nodes: 1 control-plane + 2 workers"
echo "Audit: enabled (stdout)"
echo "etcd: 256MB quota, metrics on :2381"
echo "Kueue: v0.17.2"
echo "Website operator: running in m5-system"
echo ""
echo "Next: bash ${LABS_DIR}/m11/inject.sh   # inject the 6 capstone faults"
