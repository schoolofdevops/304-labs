#!/usr/bin/env bash
# M9 lab setup — deploy inference simulator on core-internals
# Prerequisite: core-internals cluster already running (labs/clusters/core-internals/create.sh)
set -euo pipefail

CONTEXT="kind-kubeadv-core"
KUBECTL="/opt/homebrew/bin/kubectl --context ${CONTEXT}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== M9 Lab Setup: Inference Simulator ==="

# ---- Create namespace ----
${KUBECTL} create namespace m9-lab --dry-run=client -o yaml | ${KUBECTL} apply -f -

# ---- Pre-pull python:3.12-slim on worker ----
echo ""
echo "--- Pre-pulling python:3.12-slim (first pull ~1 min) ---"
${KUBECTL} -n m9-lab apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: prepull
spec:
  containers:
  - name: pull
    image: python:3.12-slim
    command: ["echo", "pulled"]
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/os: linux
EOF
${KUBECTL} -n m9-lab wait --for=condition=ready pod prepull --timeout=180s 2>/dev/null || \
  ${KUBECTL} -n m9-lab wait --for=jsonpath='{.status.phase}'=Succeeded pod prepull --timeout=180s
${KUBECTL} -n m9-lab delete pod prepull

# ---- Deploy simulator via ConfigMap + Deployment ----
echo ""
echo "--- Deploying inference simulator ---"

${KUBECTL} -n m9-lab create configmap inference-sim \
  --from-file=server.py="${SCRIPT_DIR}/simulator.py" \
  --dry-run=client -o yaml | ${KUBECTL} apply -f -

${KUBECTL} -n m9-lab apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inference-sim
  labels:
    app: inference-sim
spec:
  replicas: 2
  selector:
    matchLabels:
      app: inference-sim
  template:
    metadata:
      labels:
        app: inference-sim
    spec:
      containers:
      - name: sim
        image: python:3.12-slim
        command: ["python3", "/app/server.py"]
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: MODEL_NAME
          value: "sim-llm-7b"
        - name: CONCURRENCY_LIMIT
          value: "4"
        - name: KV_CACHE_SLOTS
          value: "32"
        - name: BASE_TTFT_MS
          value: "80"
        - name: ITL_MS
          value: "25"
        volumeMounts:
        - name: app
          mountPath: /app
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 2
          periodSeconds: 5
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
          limits:
            cpu: 500m
            memory: 128Mi
      volumes:
      - name: app
        configMap:
          name: inference-sim
          items:
          - key: server.py
            path: server.py
---
apiVersion: v1
kind: Service
metadata:
  name: inference-sim
spec:
  selector:
    app: inference-sim
  ports:
  - port: 80
    targetPort: 8080
    name: http
EOF

echo "Waiting for simulator pods ..."
${KUBECTL} -n m9-lab rollout status deployment/inference-sim --timeout=120s

echo ""
echo "=== Setup complete ==="
echo "Inference simulator: 2 replicas, model=${MODEL_NAME:-sim-llm-7b}"
echo "Namespace: m9-lab"
echo ""
echo "Verify:"
echo "  kubectl --context ${CONTEXT} -n m9-lab get pods"
echo "  kubectl --context ${CONTEXT} -n m9-lab port-forward svc/inference-sim 8080:80 &"
echo "  curl -s http://localhost:8080/healthz"
