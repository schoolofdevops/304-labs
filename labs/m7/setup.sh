#!/usr/bin/env bash
# M7 lab setup — deploy two-tier app for networking experiments
# Prerequisite: cilium-networking cluster already running (labs/clusters/cilium-networking/create.sh)
set -euo pipefail

CONTEXT="kind-cilium-networking"

echo "=== M7 Lab Setup: Two-tier app (frontend → backend) ==="

# Create the lab namespace
/opt/homebrew/bin/kubectl --context "${CONTEXT}" create namespace m7-lab --dry-run=client -o yaml | \
  /opt/homebrew/bin/kubectl --context "${CONTEXT}" apply -f -

# Deploy backend (simple nginx returning a page)
/opt/homebrew/bin/kubectl --context "${CONTEXT}" -n m7-lab apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  labels:
    app: backend
    tier: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
        tier: backend
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: backend
spec:
  selector:
    app: backend
  ports:
  - port: 80
    targetPort: 80
EOF

# Deploy frontend (curl container that talks to backend)
/opt/homebrew/bin/kubectl --context "${CONTEXT}" -n m7-lab apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  labels:
    app: frontend
    tier: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
        tier: frontend
    spec:
      containers:
      - name: curl
        image: curlimages/curl:8.11.0
        command: ["sleep", "3600"]
EOF

echo "Waiting for backend pods ..."
/opt/homebrew/bin/kubectl --context "${CONTEXT}" -n m7-lab wait --for=condition=ready pod -l app=backend --timeout=60s

echo "Waiting for frontend pod ..."
/opt/homebrew/bin/kubectl --context "${CONTEXT}" -n m7-lab wait --for=condition=ready pod -l app=frontend --timeout=60s

echo ""
echo "=== Setup complete ==="
echo "Backend: 2 replicas (nginx)"
echo "Frontend: 1 replica (curl)"
echo "Namespace: m7-lab"
