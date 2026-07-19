#!/usr/bin/env bash
# M5 — install the Website CRD + the shell operator on the persistent core-internals cluster.
#
# A CRD (website-crd.yaml) extends the API server with a new kind; the operator
# (operator.yaml) is an in-cluster reconcile loop that gives that kind meaning —
# one Deployment + Service per Website, ownerReferences, a finalizer, status.
#
# Usage:
#   bash setup.sh            # install CRD + operator (idempotent)
#   bash setup.sh teardown   # remove operator + CRD + lab namespace (cluster kept)
#
# Env (match 00-environment.md on the build host):
#   export PATH="/opt/homebrew/bin:$PATH" DOCKER_HOST=unix://$HOME/.rd/docker.sock
#   export KUBECONFIG=/tmp/m5.kubeconfig   # isolated; never touch other clusters
#   kubectl config use-context kind-kubeadv-core
#
# The operator image (alpine/k8s, has bash+kubectl, multi-arch) is ~200MB; the first
# rollout pulls it and can take a couple of minutes. bash-3.2 compatible (macOS default).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT="${CONTEXT:-kind-kubeadv-core}"
KCTL="kubectl --context ${CONTEXT}"

if [ "${1:-}" = "teardown" ]; then
  echo "== M5 teardown =="
  # Drain Websites FIRST, while the operator is still up, so its finalizer cleanup
  # runs. Then force-clear any finalizer that remains (belt-and-suspenders) so no
  # object — or namespace — can hang in Terminating if the operator already died.
  if $KCTL get crd websites.kubeadv.io >/dev/null 2>&1; then
    $KCTL delete websites --all --all-namespaces --ignore-not-found --wait=false >/dev/null 2>&1 || true
    for w in $($KCTL get websites --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}' 2>/dev/null); do
      ns="${w%/*}"; nm="${w#*/}"
      $KCTL -n "$ns" patch website "$nm" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    done
  fi
  $KCTL delete -f "${HERE}/operator.yaml" --ignore-not-found || true
  $KCTL delete -f "${HERE}/website-crd.yaml" --ignore-not-found || true
  $KCTL delete ns m5-lab --ignore-not-found --wait=false || true
  echo "== done (persistent cluster kept) =="
  exit 0
fi

echo "== 1/3 install Website CRD =="
$KCTL apply -f "${HERE}/website-crd.yaml"
$KCTL wait --for condition=established --timeout=30s crd/websites.kubeadv.io

echo "== 2/3 deploy the operator (first pull of alpine/k8s can take ~2min) =="
$KCTL apply -f "${HERE}/operator.yaml"
$KCTL -n m5-system rollout status deploy/website-operator --timeout=240s

echo "== 3/3 lab namespace =="
$KCTL create namespace m5-lab --dry-run=client -o yaml | $KCTL apply -f -

echo
echo "== ready =="
$KCTL get crd websites.kubeadv.io -o custom-columns=NAME:.metadata.name,ESTABLISHED:'.status.conditions[?(@.type=="Established")].status'
$KCTL -n m5-system get deploy website-operator
echo "Create a Website:  kubectl -n m5-lab apply -f - <<EOF ... (see lab)"
