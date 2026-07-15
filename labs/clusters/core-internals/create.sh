#!/usr/bin/env bash
# core-internals profile — create
# kind cluster "kubeadv-core": 1 control-plane + 1 worker.
# Node image pinned via KIND_IMAGE (defaults to the course-tested v1.35.x tag).
#
# Audit logging is ON by default (used from M2 onward; harmless in M1).
# Set AUDIT=0 to opt out. When enabled, the API server loads
# audit-policy.yaml (this directory) and writes audit events to its stdout,
# readable with:
#   kubectl logs -n kube-system kube-apiserver-kubeadv-core-control-plane
# Without AUDIT=1 behavior is unchanged.
#
# etcd knobs (M3, always on — immutable flags, same pattern as audit):
#   --quota-backend-bytes=268435456  (256 MB backend quota; the M3 lab fills it
#                                     with bounded junk writes to drive NOSPACE)
#   --listen-metrics-urls=http://0.0.0.0:2381
#                                    (etcd /metrics reachable via the pod proxy —
#                                     feeds the X-Ray Storage lens)
# Clusters created before M3 lack them; verify.sh detects and prints the
# one-time recreate note.
#
# Idempotent: safe to re-run; exits 0 if the cluster already exists.
set -euo pipefail

CLUSTER_NAME="kubeadv-core"
KIND_IMAGE="${KIND_IMAGE:-kindest/node:v1.35.0}"
AUDIT="${AUDIT:-1}"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

audit_enabled_on_cluster() {
  kubectl --context "kind-${CLUSTER_NAME}" -n kube-system get pod \
    "kube-apiserver-${CLUSTER_NAME}-control-plane" \
    -o jsonpath='{.spec.containers[0].command}' 2>/dev/null \
    | grep -q 'audit-policy-file'
}

etcd_knobs_on_cluster() {
  kubectl --context "kind-${CLUSTER_NAME}" -n kube-system get pod \
    "etcd-${CLUSTER_NAME}-control-plane" \
    -o jsonpath='{.spec.containers[0].command}' 2>/dev/null \
    | grep -q 'quota-backend-bytes'
}

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "kind cluster '${CLUSTER_NAME}' already exists — reusing it."
  kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null
  if [ "${AUDIT}" = "1" ] && ! audit_enabled_on_cluster; then
    echo "NOTE: this cluster was created WITHOUT audit mode. API server flags are"
    echo "      immutable after create — recreate to enable auditing:"
    echo "        bash ${PROFILE_DIR}/teardown.sh && bash ${PROFILE_DIR}/create.sh"
  fi
  if ! etcd_knobs_on_cluster; then
    echo "NOTE: this cluster predates the M3 etcd profile (quota + metrics knobs)."
    echo "      etcd flags are immutable after create — recreate once before M3:"
    echo "        bash ${PROFILE_DIR}/teardown.sh && bash ${PROFILE_DIR}/create.sh"
  fi
  exit 0
fi

if [ "${AUDIT}" = "1" ]; then
  echo "Creating kind cluster '${CLUSTER_NAME}' (image: ${KIND_IMAGE}, AUDIT enabled) ..."
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
          # kind v0.32 renders kubeadm v1beta3: extraArgs is a map (not the
          # v1beta4 name/value list). audit-log-path "-" = API server stdout,
          # which lands in the static pod's container log (kubectl logs).
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
            # Same v1beta3 map-form extraArgs as apiServer above.
            # 256 MB backend quota (M3 fills it on purpose) + metrics listener
            # on :2381 so the X-Ray Storage lens can scrape via the pod proxy.
            extraArgs:
              quota-backend-bytes: "268435456"
              listen-metrics-urls: "http://0.0.0.0:2381"
  - role: worker
EOF
else
  echo "Creating kind cluster '${CLUSTER_NAME}' (image: ${KIND_IMAGE}) ..."
  kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_IMAGE}" --wait 120s --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        etcd:
          local:
            # kind v0.32 renders kubeadm v1beta3: extraArgs is a map (not the
            # v1beta4 name/value list). 256 MB quota + :2381 metrics listener.
            extraArgs:
              quota-backend-bytes: "268435456"
              listen-metrics-urls: "http://0.0.0.0:2381"
  - role: worker
EOF
fi

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
if [ "${AUDIT}" = "1" ]; then
  echo "core-internals profile ready: 1 control-plane + 1 worker (${KIND_IMAGE}) — AUDIT ENABLED"
  echo "audit stream: kubectl logs -n kube-system kube-apiserver-${CLUSTER_NAME}-control-plane"
else
  echo "core-internals profile ready: 1 control-plane + 1 worker (${KIND_IMAGE})"
fi
echo "etcd profile: 256MB backend quota, metrics on :2381 (M3 knobs baked in)"
