#!/usr/bin/env bash
# capstone profile — verify
# Checks that the cluster, Kueue, and Website operator are healthy.
# Run BEFORE fault injection to confirm baseline, or AFTER fixes to confirm recovery.
set -euo pipefail

CLUSTER_NAME="kubeadv-capstone"
CTX="kind-${CLUSTER_NAME}"
PASS=0; FAIL=0

check() {
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✅ ${label}"
    PASS=$((PASS + 1))
  else
    echo "  ❌ ${label}"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== capstone profile verification ==="

echo ""
echo "Cluster:"
check "cluster reachable" kubectl cluster-info --context "${CTX}"
check "control-plane node Ready" kubectl get node -l node-role.kubernetes.io/control-plane \
  --context "${CTX}" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' \
  | grep -q True

echo ""
echo "System pods:"
check "kube-apiserver running" kubectl -n kube-system get pod \
  -l component=kube-apiserver --context "${CTX}" -o jsonpath='{.items[0].status.phase}' \
  | grep -q Running
check "etcd running" kubectl -n kube-system get pod \
  -l component=etcd --context "${CTX}" -o jsonpath='{.items[0].status.phase}' \
  | grep -q Running
check "coredns running" kubectl -n kube-system get pods \
  -l k8s-app=kube-dns --context "${CTX}" -o jsonpath='{.items[0].status.phase}' \
  | grep -q Running

echo ""
echo "Kueue:"
check "kueue controller running" kubectl -n kueue-system get pods \
  -l control-plane=controller-manager --context "${CTX}" \
  -o jsonpath='{.items[0].status.phase}' | grep -q Running

echo ""
echo "Website operator:"
check "CRD established" kubectl get crd websites.kubeadv.io --context "${CTX}"
check "operator deployment exists" kubectl -n m5-system get deploy website-operator --context "${CTX}"

echo ""
echo "Audit:"
check "audit-policy-file flag present" kubectl -n kube-system get pod \
  "kube-apiserver-${CLUSTER_NAME}-control-plane" --context "${CTX}" \
  -o jsonpath='{.spec.containers[0].command}' | grep -q audit-policy-file

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[ "${FAIL}" -eq 0 ]
