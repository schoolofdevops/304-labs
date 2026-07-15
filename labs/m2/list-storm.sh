#!/usr/bin/env bash
# M2 — bounded, laptop-safe LIST storm against the API server.
#
#   CONCURRENCY  parallel workers (default 10; try 20 on a 16 GB machine)
#   DURATION     seconds to run (default 30)
#   AS           optional identity to impersonate, e.g.
#                AS=system:serviceaccount:apiload:rogue-operator
#   CONTEXT      kubectl context (default kind-kubeadv-core)
#
# Each worker loops full, deliberately UNPAGINATED cluster-wide ConfigMap LISTs
# (--chunk-size=0 disables kubectl's default pagination). The storm is bounded
# on purpose — fixed concurrency, fixed duration, per-request timeout — so it
# demonstrates APF queuing without destabilizing the lab control plane.
set -euo pipefail

CONCURRENCY="${CONCURRENCY:-10}"
DURATION="${DURATION:-30}"
CONTEXT="${CONTEXT:-kind-kubeadv-core}"
AS="${AS:-}"

AS_FLAG=""
if [ -n "${AS}" ]; then
  AS_FLAG="--as=${AS}"
fi

END=$(( $(date +%s) + DURATION ))
TMPDIR_STORM="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_STORM}"' EXIT

worker() {
  local id="$1" ok=0 err=0
  while [ "$(date +%s)" -lt "${END}" ]; do
    # shellcheck disable=SC2086
    if kubectl --context "${CONTEXT}" ${AS_FLAG:+${AS_FLAG}} \
         get configmaps -A -o json --chunk-size=0 --request-timeout=20s \
         > /dev/null 2>> "${TMPDIR_STORM}/errors.log"; then
      ok=$((ok + 1))
    else
      err=$((err + 1))
    fi
  done
  echo "${ok} ${err}" > "${TMPDIR_STORM}/worker-${id}"
}

echo "LIST storm: ${CONCURRENCY} workers x unpaginated 'kubectl get configmaps -A -o json --chunk-size=0' for ${DURATION}s${AS:+ as ${AS}}"

i=1
while [ "${i}" -le "${CONCURRENCY}" ]; do
  worker "${i}" &
  i=$((i + 1))
done
wait

TOTAL_OK=0
TOTAL_ERR=0
for f in "${TMPDIR_STORM}"/worker-*; do
  read -r ok err < "${f}"
  TOTAL_OK=$((TOTAL_OK + ok))
  TOTAL_ERR=$((TOTAL_ERR + err))
done

echo "Storm complete: ${TOTAL_OK} LISTs succeeded, ${TOTAL_ERR} failed or rejected, across ${CONCURRENCY} workers in ${DURATION}s."
if [ -s "${TMPDIR_STORM}/errors.log" ]; then
  echo "Sample errors (429s here are APF doing its job):"
  sort "${TMPDIR_STORM}/errors.log" | uniq -c | sort -rn | head -3
fi
