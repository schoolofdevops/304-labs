#!/usr/bin/env bash
# M3 — bounded etcd filler: drive the 256 MB backend quota into NOSPACE.
#
#   COUNT    hard cap on ConfigMap writes (default 300 — enough to cross a
#            256 MB quota; the script stops EARLY at the first NOSPACE error)
#   SIZE_KB  payload size per ConfigMap in KiB (default 950 KiB — CM total cap is 1 MiB)
#   OFFSET   name offset for resuming an interrupted/short fill
#            (e.g. OFFSET=220 COUNT=40 adds fill-0221..fill-0260)
#   CONTEXT  kubectl context (default kind-kubeadv-core)
#
# Bounded by design: fixed count, fixed size, progress every 10 writes,
# stops on the first NOSPACE rejection with a clear message. Never loops
# unbounded. Pure bash 3.2 + kubectl, multi-arch safe.
# Objects land in the 'etcd-lab' namespace with label module=m3.
set -euo pipefail

COUNT="${COUNT:-300}"
SIZE_KB="${SIZE_KB:-950}"  # ConfigMap TOTAL cap is 1 MiB incl. metadata — 950 KiB payload stays under it
OFFSET="${OFFSET:-0}"
CONTEXT="${CONTEXT:-kind-kubeadv-core}"
NAMESPACE="etcd-lab"

payload="$(head -c $((SIZE_KB * 1024)) /dev/zero | tr '\0' 'x')"

kubectl --context "${CONTEXT}" create namespace "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl --context "${CONTEXT}" apply -f - > /dev/null

echo "Filling etcd: up to ${COUNT} ConfigMaps (~${SIZE_KB} KiB each) into '${NAMESPACE}' ..."
echo "Stops at the first NOSPACE rejection — that is the goal, not a failure."

i=1
while [ "${i}" -le "${COUNT}" ]; do
  n=$((OFFSET + i))
  if ! err="$( {
        printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: fill-%04d\n  namespace: %s\n  labels:\n    course: 304-kubeadv\n    module: m3\ndata:\n  blob: %s\n' \
          "${n}" "${NAMESPACE}" "${payload}" \
          | kubectl --context "${CONTEXT}" create -f -
      } 2>&1 >/dev/null )"; then
    if printf '%s' "${err}" | grep -q 'database space exceeded'; then
      echo ""
      echo "NOSPACE: etcd rejected write ${n} after $((i - 1)) successful writes this run:"
      echo "  ${err}"
      echo ""
      echo "The backend quota is full. etcd is now read-only: every write in the"
      echo "cluster fails, reads still work. Continue with the lab:"
      echo "  alarm list -> compaction -> defrag -> alarm disarm -> verify"
      exit 0
    fi
    echo "Write ${n} failed with an unexpected error:" >&2
    printf '%s\n' "${err}" >&2
    exit 1
  fi
  if [ $((i % 10)) -eq 0 ]; then
    echo "  ${i}/${COUNT} written (db is growing — watch the Storage lens)"
  fi
  i=$((i + 1))
done

echo ""
echo "Wrote all ${COUNT} ConfigMaps without hitting NOSPACE — your database had"
echo "more headroom than expected. Add more without name collisions:"
echo "  OFFSET=$((OFFSET + COUNT)) COUNT=60 bash labs/m3/fill-etcd.sh"
