#!/usr/bin/env bash
# M6 — grow the kwok-scale cluster and print a control-plane snapshot.
#
# Adds fake nodes (and optionally pods), then reads the apiserver's own numbers so
# you can watch the knee move: object counts, inflight, and a full-list wall-clock.
#
# Usage:
#   bash grow.sh <nodes> [pods]
#     bash grow.sh 100            # 100 fake nodes, no pods
#     bash grow.sh 1000 10000     # 1000 fake nodes + 10000 fake pods
#
# Env: PATH + DOCKER_HOST + KUBECONFIG=/tmp/m6.kubeconfig (see create.sh).
# NOTE: `scale pod` is slow at large N (each pod is created + bound) — 10k is a
# sensible ceiling for a live demo; 20k+ takes minutes.
set -euo pipefail

CLUSTER="${CLUSTER:-kwok-scale}"
NODES="${1:?usage: bash grow.sh <nodes> [pods]}"
PODS="${2:-0}"
CTX="kwok-${CLUSTER}"
K="kubectl --context ${CTX}"

echo "==> Scaling to ${NODES} fake node(s) ..."
kwokctl scale node --name "${CLUSTER}" --replicas "${NODES}" >/dev/null 2>&1 || \
  kwokctl scale node --name "${CLUSTER}" --replicas "${NODES}"

if [ "${PODS}" -gt 0 ]; then
  echo "==> Scaling to ${PODS} fake pod(s) — this can take a while at large N ..."
  kwokctl scale pod --name "${CLUSTER}" --replicas "${PODS}" >/dev/null 2>&1 || \
    kwokctl scale pod --name "${CLUSTER}" --replicas "${PODS}"
fi

sleep 2
echo
echo "===================== control-plane snapshot ====================="
printf 'nodes (Ready):   %s\n' "$(${K} get nodes --no-headers 2>/dev/null | grep -c ' Ready')"
printf 'pods (all ns):   %s\n' "$(${K} get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo '--- objects in etcd (apiserver_storage_objects, top 5) ---'
${K} get --raw /metrics 2>/dev/null | grep '^apiserver_storage_objects{' \
  | sort -t' ' -k2 -rn | head -5 | sed 's/^apiserver_storage_objects//'
echo '--- inflight requests ---'
${K} get --raw /metrics 2>/dev/null | grep '^apiserver_current_inflight_requests'
echo '--- full unpaginated `get pods -A` wall-clock (what a controller feels) ---'
t0=$(python3 -c 'import time;print(time.time())')
BYTES=$(${K} get pods -A -o json 2>/dev/null | wc -c | tr -d ' ')
t1=$(python3 -c 'import time;print(time.time())')
python3 -c "print(f'  wall-clock: {$t1-$t0:.2f}s   payload: {$BYTES/1024/1024:.1f} MB')"
echo "=================================================================="
