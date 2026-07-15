#!/usr/bin/env bash
# M2 — seed a bounded set of small ConfigMaps for the LIST-storm exercise.
#
#   COUNT       how many ConfigMaps to create (default 300 — the 8 GB profile;
#               use COUNT=600 on a 16 GB machine)
#   PAYLOAD_KB  size of each ConfigMap's data blob in KiB (default 4)
#   CONTEXT     kubectl context (default kind-kubeadv-core)
#
# Pure bash + kubectl, multi-arch safe, idempotent (kubectl apply).
# Objects land in the 'apiload' namespace with label module=m2 so they can be
# counted and torn down precisely.
set -euo pipefail

COUNT="${COUNT:-300}"
PAYLOAD_KB="${PAYLOAD_KB:-4}"
CONTEXT="${CONTEXT:-kind-kubeadv-core}"
NAMESPACE="apiload"

payload="$(head -c $((PAYLOAD_KB * 1024)) /dev/zero | tr '\0' 'x')"

echo "Seeding ${COUNT} ConfigMaps (~${PAYLOAD_KB} KiB each) into namespace '${NAMESPACE}' ..."

{
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n' "${NAMESPACE}"
  i=1
  while [ "${i}" -le "${COUNT}" ]; do
    printf -- '---\n'
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n'
    printf '  name: apiload-%04d\n  namespace: %s\n' "${i}" "${NAMESPACE}"
    printf '  labels:\n    course: 304-kubeadv\n    module: m2\n'
    printf 'data:\n  blob: %s\n' "${payload}"
    i=$((i + 1))
  done
} | kubectl --context "${CONTEXT}" apply -f - > /dev/null

actual="$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get configmaps -l module=m2 --no-headers | wc -l | tr -d ' ')"
echo "Done: namespace '${NAMESPACE}' now holds ${actual} module=m2 ConfigMaps (target ${COUNT})."
