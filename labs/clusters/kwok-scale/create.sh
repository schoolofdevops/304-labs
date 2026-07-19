#!/usr/bin/env bash
# M6 — the kwok-scale profile: a DEDICATED kwokctl cluster for the scaling experiment.
#
# kwokctl brings up a REAL control plane (etcd + kube-apiserver + scheduler +
# controller-manager) and lets you attach THOUSANDS of FAKE nodes/pods that cost
# almost nothing — so the apiserver and etcd take honest load while the "hardware"
# is free. This is how you find the control-plane knee on a laptop.
#
# Only ONE course cluster profile runs at a time. This profile is SEPARATE from the
# persistent core-internals cluster — teardown.sh recreates core-internals afterwards.
#
# Usage:
#   bash create.sh              # create the kwok-scale cluster (idempotent)
# Env (match 00-environment.md):
#   export PATH="/opt/homebrew/bin:$PATH" DOCKER_HOST=unix://$HOME/.rd/docker.sock
#   export KUBECONFIG=/tmp/m6.kubeconfig
# Pinned kwokctl v0.8.0 (control plane images k8s v1.36.x / etcd 3.6.x).
set -euo pipefail

CLUSTER="${CLUSTER:-kwok-scale}"

if kwokctl get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "==> kwok-scale already exists — reusing."
else
  echo "==> Creating kwokctl cluster '${CLUSTER}' (docker runtime) ..."
  kwokctl create cluster --name "${CLUSTER}" --runtime docker
fi

# Point kubectl at it (kwokctl writes the context kwok-${CLUSTER}).
kwokctl --name "${CLUSTER}" get kubeconfig > "${KUBECONFIG:-/tmp/m6.kubeconfig}"

echo "==> Waiting for the API server to answer /healthz ..."
for i in $(seq 1 30); do
  if kubectl --context "kwok-${CLUSTER}" get --raw /healthz >/dev/null 2>&1; then
    echo "==> API server healthy."
    break
  fi
  sleep 2
done

echo
echo "kwok-scale ready — a full control plane with ZERO nodes yet."
echo "Grow it:   bash grow.sh <nodes> [pods]      e.g. bash grow.sh 1000 10000"
echo "Context:   kwok-${CLUSTER}   (KUBECONFIG=${KUBECONFIG:-/tmp/m6.kubeconfig})"
