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
KUEUE_VERSION="v0.17.2"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "kind cluster '${CLUSTER_NAME}' already exists — reusing it."
  kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null
  if [ "${COURSE_IMAGE_CACHE:-0}" = "1" ]; then
    echo "Loading the pre-pulled capstone images into every cluster node ..."
    bash "${LABS_DIR}/tools/preload-course-images.sh" \
      --load-only --cluster "${CLUSTER_NAME}" --scope capstone
  fi
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

if [ "${COURSE_IMAGE_CACHE:-0}" = "1" ]; then
  echo "Loading the pre-pulled capstone images into every cluster node ..."
  bash "${LABS_DIR}/tools/preload-course-images.sh" \
    --load-only --cluster "${CLUSTER_NAME}" --scope capstone
fi

# ---- Install Kueue ----
echo ""
echo "Installing Kueue ${KUEUE_VERSION} ..."
KUEUE_RAW="$(mktemp "${TMPDIR:-/tmp}/kueue-raw.XXXXXX")"
KUEUE_LOCAL="$(mktemp "${TMPDIR:-/tmp}/kueue-local.XXXXXX")"
trap 'rm -f "${KUEUE_RAW}" "${KUEUE_LOCAL}"' EXIT
curl -fsSL \
  "https://github.com/kubernetes-sigs/kueue/releases/download/${KUEUE_VERSION}/manifests.yaml" \
  -o "${KUEUE_RAW}"
sed 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/' \
  "${KUEUE_RAW}" > "${KUEUE_LOCAL}"
kubectl apply --server-side \
  -f "${KUEUE_LOCAL}" \
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

# Kueue's own admission webhook intercepts every apps/v1 Deployment cluster-wide
# (not just Kueue-managed ones). Its pod can report Ready a moment before the
# kueue-webhook-service Endpoints finish propagating, so the very next apply
# below can hit "dial tcp ...: connect: connection refused" even though Kueue
# just passed its readiness wait. Retry past that startup race instead of
# failing the whole cluster create on it.
for attempt in $(seq 1 6); do
  if kubectl apply -f "${LABS_DIR}/m5/operator.yaml" --context "kind-${CLUSTER_NAME}"; then
    break
  fi
  if [ "${attempt}" -eq 6 ]; then
    echo "operator.yaml apply failed after ${attempt} attempts (Kueue webhook not reachable) — aborting." >&2
    exit 1
  fi
  echo "  operator.yaml apply failed (Kueue webhook likely still propagating) — retrying in 5s ..."
  sleep 5
done
kubectl -n m5-system rollout status deploy/website-operator --timeout=240s \
  --context "kind-${CLUSTER_NAME}"

echo ""
echo "=== capstone profile ready ==="
echo "Cluster: ${CLUSTER_NAME} (${KIND_IMAGE})"
echo "Nodes: 1 control-plane + 2 workers"
echo "Audit: enabled (stdout)"
echo "etcd: 256MB quota, metrics on :2381"
echo "Kueue: ${KUEUE_VERSION}"
echo "Website operator: running in m5-system"
echo ""
echo "Next: bash ${LABS_DIR}/m11/inject.sh   # inject the 6 capstone faults"
