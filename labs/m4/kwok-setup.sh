#!/usr/bin/env bash
# M4 — KWOK as an IN-CLUSTER controller on the persistent core-internals cluster.
#
# Installs the upstream kwok controller (kubectl apply of kwok.yaml + stage-fast.yaml)
# so it manages FAKE Node objects ON the real kind cluster. This is NOT `kwokctl`
# (which spins up a separate fake cluster). Real kind nodes and fake kwok nodes
# coexist: real pods schedule onto the real worker; pods that tolerate the kwok
# taint schedule onto fake nodes where kwok fakes the kubelet (they go Running).
#
# Usage:
#   bash kwok-setup.sh              # deploy controller + FAKE_NODES fake nodes (default 3)
#   FAKE_NODES=5 bash kwok-setup.sh # custom fake-node count
#   bash kwok-setup.sh teardown     # remove fake nodes + controller (real 2 nodes remain)
#
# Idempotent: re-running deploy re-applies (apply is declarative); re-running
# teardown is safe. bash-3.2 compatible (macOS default shell).
#
# Env (match 00-environment.md on the build host):
#   export PATH="/opt/homebrew/bin:$PATH" DOCKER_HOST=unix://$HOME/.rd/docker.sock
#   export KUBECONFIG=/tmp/m4.kubeconfig   # isolated; never touch other clusters
#   kubectl config use-context kind-kubeadv-core
#
# Pinned kwok version: v0.8.0 (image registry.k8s.io/kwok/kwok:v0.8.0).
set -euo pipefail

KWOK_VERSION="${KWOK_VERSION:-v0.8.0}"
FAKE_NODES="${FAKE_NODES:-3}"
CONTEXT="${CONTEXT:-kind-kubeadv-core}"
KWOK_REPO="kubernetes-sigs/kwok"
BASE="https://github.com/${KWOK_REPO}/releases/download/${KWOK_VERSION}"

kc() { kubectl --context "${CONTEXT}" "$@"; }

deploy_controller() {
  echo "==> Installing kwok ${KWOK_VERSION} in-cluster controller + CRDs + RBAC ..."
  kc apply -f "${BASE}/kwok.yaml"
  echo "==> Installing kwok lifecycle stages (stage-fast: node-initialize,"
  echo "    node-heartbeat-with-lease, pod-ready/complete/delete) ..."
  kc apply -f "${BASE}/stage-fast.yaml"
  echo "==> Waiting for kwok-controller to be Ready ..."
  kc -n kube-system rollout status deploy/kwok-controller --timeout=120s
}

# create_fake_node <index> — canonical KWOK fake-node shape.
# The taint kwok.x-k8s.io/node=fake:NoSchedule keeps REAL pods off fake nodes
# unless they tolerate it. The kwok.x-k8s.io/node=fake annotation is what makes
# the controller adopt the node (fake the kubelet, run heartbeats, run pods).
create_fake_node() {
  local i="$1"
  cat <<EOF | kc apply -f -
apiVersion: v1
kind: Node
metadata:
  name: kwok-node-${i}
  annotations:
    node.alpha.kubernetes.io/ttl: "0"
    kwok.x-k8s.io/node: fake
  labels:
    beta.kubernetes.io/arch: arm64
    beta.kubernetes.io/os: linux
    kubernetes.io/arch: arm64
    kubernetes.io/hostname: kwok-node-${i}
    kubernetes.io/os: linux
    kubernetes.io/role: agent
    node-role.kubernetes.io/agent: ""
    type: kwok
spec:
  taints:
    - key: kwok.x-k8s.io/node
      value: fake
      effect: NoSchedule
status:
  allocatable:
    cpu: "32"
    memory: 256Gi
    pods: "110"
  capacity:
    cpu: "32"
    memory: 256Gi
    pods: "110"
  nodeInfo:
    architecture: arm64
    kubeletVersion: fake
    operatingSystem: linux
EOF
}

deploy_nodes() {
  echo "==> Creating ${FAKE_NODES} fake node(s) ..."
  local i=0
  while [ "$i" -lt "${FAKE_NODES}" ]; do
    create_fake_node "$i"
    i=$((i + 1))
  done
  echo "==> Waiting for fake nodes to report Ready (kwok node-initialize stage) ..."
  local n=0
  while [ "$n" -lt "${FAKE_NODES}" ]; do
    kc wait --for=condition=Ready "node/kwok-node-${n}" --timeout=60s >/dev/null 2>&1 || true
    n=$((n + 1))
  done
  kc get nodes
}

teardown() {
  echo "==> Removing fake nodes (kwok-node-*) ..."
  # Delete any pods that landed on fake nodes first (kwok pod-delete stage completes them).
  local fake
  fake="$(kc get nodes -l type=kwok -o name 2>/dev/null || true)"
  if [ -n "${fake}" ]; then
    for node in ${fake}; do
      nm="${node#node/}"
      kc get pods -A --field-selector "spec.nodeName=${nm}" \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | while read -r ns pod; do
            [ -n "${pod:-}" ] && kc -n "${ns}" delete pod "${pod}" --force --grace-period=0 >/dev/null 2>&1 || true
          done
      kc delete "${node}" --ignore-not-found >/dev/null 2>&1 || true
    done
  fi
  echo "==> Removing kwok stages + controller + CRDs + RBAC ..."
  kc delete -f "${BASE}/stage-fast.yaml" --ignore-not-found >/dev/null 2>&1 || true
  kc delete -f "${BASE}/kwok.yaml" --ignore-not-found >/dev/null 2>&1 || true
  echo "==> Remaining nodes (expect the real 2):"
  kc get nodes
}

case "${1:-deploy}" in
  deploy)
    deploy_controller
    deploy_nodes
    echo
    echo "kwok ${KWOK_VERSION} in-cluster: controller Running, ${FAKE_NODES} fake node(s) Ready."
    echo "Fake nodes carry taint kwok.x-k8s.io/node=fake:NoSchedule — real pods stay off"
    echo "them unless they tolerate it. Teardown: bash kwok-setup.sh teardown"
    ;;
  teardown)
    teardown
    ;;
  *)
    echo "usage: bash kwok-setup.sh [deploy|teardown]" >&2
    exit 2
    ;;
esac
