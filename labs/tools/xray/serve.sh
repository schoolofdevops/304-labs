#!/usr/bin/env bash
# Cluster X-Ray — serve the live visualizer through kubectl proxy.
# The proxy does two jobs at once: serves this static page AND forwards
# /api/... to your cluster with your kubeconfig credentials. Same origin,
# so the page needs no tokens and no CORS.
set -euo pipefail

PORT="${PORT:-8001}"
XRAY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTX="$(kubectl config current-context 2>/dev/null || echo '<none>')"

echo "┌─────────────────────────────────────────────────────────────"
echo "│  Cluster X-Ray · Reconciliation · Control-Plane · Storage · Scheduling · Extensions lenses"
echo "│"
echo "│  context : ${CTX}"
echo "│           (expected: kind-kubeadv-core — switch with"
echo "│            'kubectl config use-context kind-kubeadv-core')"
echo "│"
echo "│  open    : http://127.0.0.1:${PORT}/xray/"
echo "│"
echo "│  Ctrl-C stops the proxy. Port busy? PORT=8002 bash serve.sh"
echo "└─────────────────────────────────────────────────────────────"

exec kubectl proxy --www="${XRAY_DIR}" --www-prefix=/xray/ --port="${PORT}"
