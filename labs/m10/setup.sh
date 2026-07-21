#!/usr/bin/env bash
# M10 — Agentic Kubernetes lab setup
# Deploys MCP tool server with read-only RBAC on core-internals.
set -euo pipefail

CONTEXT="kind-kubeadv-core"
NAMESPACE="m10-lab"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECTL="kubectl --context ${CONTEXT}"

echo "=== M10 Lab Setup: MCP Tool Server + Read-Only RBAC ==="

# Pre-pull image
echo "Pre-pulling python:3.12-slim..."
docker pull --quiet python:3.12-slim
kind load docker-image python:3.12-slim --name kubeadv-core 2>/dev/null || true

# Create namespace
echo "Creating namespace ${NAMESPACE}..."
${KUBECTL} create namespace ${NAMESPACE} --dry-run=client -o yaml | ${KUBECTL} apply -f -

# ServiceAccount
echo "Creating ServiceAccount ai-agent..."
${KUBECTL} -n ${NAMESPACE} apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ai-agent
  namespace: m10-lab
  labels:
    app: mcp-server
    role: ai-agent
EOF

# ClusterRole — read-only access to core resources
echo "Creating ClusterRole ai-agent-readonly..."
${KUBECTL} apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ai-agent-readonly
  labels:
    app: mcp-server
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "events", "namespaces", "nodes", "configmaps"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "daemonsets", "statefulsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch"]
EOF

# ClusterRoleBinding
echo "Creating ClusterRoleBinding..."
${KUBECTL} apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ai-agent-readonly-binding
  labels:
    app: mcp-server
subjects:
  - kind: ServiceAccount
    name: ai-agent
    namespace: m10-lab
roleRef:
  kind: ClusterRole
  name: ai-agent-readonly
  apiGroup: rbac.authorization.k8s.io
EOF

# ConfigMap with MCP server code
echo "Creating ConfigMap with MCP server code..."
${KUBECTL} -n ${NAMESPACE} create configmap mcp-server-code \
  --from-file=server.py="${SCRIPT_DIR}/mcp-server.py" \
  --dry-run=client -o yaml | ${KUBECTL} apply -f -

# Deployment
echo "Deploying MCP server (1 replica)..."
${KUBECTL} -n ${NAMESPACE} apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-server
  namespace: m10-lab
  labels:
    app: mcp-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mcp-server
  template:
    metadata:
      labels:
        app: mcp-server
    spec:
      serviceAccountName: ai-agent
      containers:
        - name: mcp
          image: python:3.12-slim
          command: ["python3", "/app/server.py"]
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 5
          env:
            - name: PORT
              value: "8080"
            - name: SERVER_NAME
              value: "k8s-mcp-readonly"
          volumeMounts:
            - name: server-code
              mountPath: /app
              readOnly: true
      volumes:
        - name: server-code
          configMap:
            name: mcp-server-code
EOF

# Service
echo "Creating Service..."
${KUBECTL} -n ${NAMESPACE} apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: mcp-server
  namespace: m10-lab
  labels:
    app: mcp-server
spec:
  selector:
    app: mcp-server
  ports:
    - port: 80
      targetPort: 8080
      protocol: TCP
EOF

# Wait for rollout
echo "Waiting for MCP server to be ready..."
${KUBECTL} -n ${NAMESPACE} rollout status deployment/mcp-server --timeout=60s

echo ""
echo "✅ M10 lab environment ready"
echo "   Namespace:       ${NAMESPACE}"
echo "   ServiceAccount:  ai-agent (read-only ClusterRole)"
echo "   MCP server:      mcp-server.m10-lab.svc (port 80 → 8080)"
echo "   Audit log:       kubectl logs -n kube-system kube-apiserver-kubeadv-core-control-plane"
echo ""
echo "   Port-forward:    kubectl --context ${CONTEXT} -n ${NAMESPACE} port-forward svc/mcp-server 8080:80"
echo "   Health check:    curl http://localhost:8080/healthz"
