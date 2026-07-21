#!/usr/bin/env bash
# M11 capstone — inject 6 faults into the capstone cluster.
# Prerequisite: labs/clusters/capstone/create.sh already run.
#
# Faults:
#   1. Scheduling — taint worker node, deploy pods with affinity to it
#   2. CoreDNS — corrupt upstream forwarder in Corefile
#   3. Operator — delete Website operator ConfigMap, restart pod
#   4. API throttling — FlowSchema routing SAs to 1-concurrency PriorityLevel
#   5. etcd degradation — flood with 2000 junk ConfigMaps
#   6. Kueue blocked — ClusterQueue with 0 CPU quota
#
# Usage:
#   bash inject.sh          # inject all faults
#   bash inject.sh --check  # show fault status without injecting
set -euo pipefail

CLUSTER_NAME="kubeadv-capstone"
CTX="kind-${CLUSTER_NAME}"
K="kubectl --context ${CTX}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--check" ]; then
  echo "=== Fault status check ==="
  echo ""
  echo "1. Scheduling:"
  $K get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].effect' 2>/dev/null || true
  $K get pods -n capstone-app -o wide 2>/dev/null || echo "   namespace capstone-app not found"
  echo ""
  echo "2. CoreDNS:"
  $K -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' 2>/dev/null | head -5 || true
  echo ""
  echo "3. Operator:"
  $K -n m5-system get pods 2>/dev/null || true
  $K -n m5-system get cm website-operator-src 2>/dev/null && echo "   ConfigMap present" || echo "   ConfigMap MISSING"
  echo ""
  echo "4. API throttling:"
  $K get flowschema throttle-serviceaccounts 2>/dev/null && echo "   throttle FlowSchema present" || echo "   throttle FlowSchema absent"
  echo ""
  echo "5. etcd junk:"
  COUNT=$($K get cm -n capstone-junk --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "   ${COUNT} junk ConfigMaps in capstone-junk"
  echo ""
  echo "6. Kueue:"
  $K get clusterqueue capstone-cq -o jsonpath='{.spec.resourceGroups[0].flavors[0].resources[0].nominalQuota}' 2>/dev/null && echo "" || echo "   ClusterQueue not found"
  exit 0
fi

echo "=== M11 Capstone: Injecting 6 faults ==="
echo ""

# ---- Phase 1: Create baseline resources ----
echo "--- Phase 1: baseline resources ---"

# Namespace for the "application" workloads
$K create namespace capstone-app --dry-run=client -o yaml | $K apply -f -

# Create a Website CR (so the operator has something to reconcile)
$K apply -f - <<'YAML'
apiVersion: kubeadv.io/v1alpha1
kind: Website
metadata:
  name: nimbusai-dashboard
  namespace: capstone-app
spec:
  host: dashboard.nimbusai.internal
  image: nginx:1.27-alpine
  replicas: 2
YAML

# Wait for operator to reconcile (creates Deployment + Service)
echo "Waiting for Website operator to reconcile ..."
for i in $(seq 1 30); do
  if $K -n capstone-app get deploy web-nimbusai-dashboard >/dev/null 2>&1; then
    echo "  Website reconciled."
    break
  fi
  sleep 2
done

# Deploy a simple app that needs DNS (for fault #2 diagnosis)
$K apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dns-checker
  namespace: capstone-app
spec:
  replicas: 1
  selector:
    matchLabels: { app: dns-checker }
  template:
    metadata:
      labels: { app: dns-checker }
    spec:
      containers:
        - name: checker
          image: busybox:1.36
          command: ["sh", "-c", "while true; do nslookup kubernetes.default.svc >/dev/null 2>&1 && echo ok || echo dns-fail; sleep 30; done"]
YAML

# Kueue baseline: ResourceFlavor + ClusterQueue + LocalQueue
$K apply -f - <<'YAML'
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: capstone-flavor
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: capstone-cq
spec:
  namespaceSelector: {}
  resourceGroups:
    - coveredResources: ["cpu", "memory"]
      flavors:
        - name: capstone-flavor
          resources:
            - name: cpu
              nominalQuota: "4"
            - name: memory
              nominalQuota: "4Gi"
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: capstone-queue
  namespace: capstone-app
spec:
  clusterQueue: capstone-cq
YAML

# Submit a training job through Kueue
$K apply -f - <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: training-run-042
  namespace: capstone-app
  labels:
    kueue.x-k8s.io/queue-name: capstone-queue
spec:
  suspend: true
  template:
    spec:
      containers:
        - name: trainer
          image: busybox:1.36
          command: ["sh", "-c", "echo 'Training epoch 1/10 ...'; sleep 60; echo 'Done.'"]
          resources:
            requests:
              cpu: "500m"
              memory: "256Mi"
      restartPolicy: Never
YAML

echo "Waiting for Kueue to admit the job ..."
sleep 10
JOB_STATUS=$($K get workloads -n capstone-app -o jsonpath='{.items[0].status.conditions[?(@.type=="Admitted")].status}' 2>/dev/null || echo "Unknown")
echo "  Job admission status: ${JOB_STATUS}"

# Label worker1 as a GPU node (inference-workers target this label)
WORKER=$($K get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')
$K label node "${WORKER}" accelerator=gpu --overwrite
echo "Labeled ${WORKER} with accelerator=gpu"

# Deploy pods that require the gpu-labeled node (will become Pending after fault #1)
$K apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inference-workers
  namespace: capstone-app
spec:
  replicas: 2
  selector:
    matchLabels: { app: inference-worker }
  template:
    metadata:
      labels: { app: inference-worker }
    spec:
      nodeSelector:
        accelerator: gpu
      containers:
        - name: worker
          image: busybox:1.36
          command: ["sh", "-c", "echo 'Inference worker ready'; sleep 3600"]
          resources:
            requests:
              cpu: "100m"
              memory: "64Mi"
YAML

echo "Waiting for baseline pods to be Running ..."
$K -n capstone-app wait --for=condition=available deploy/inference-workers --timeout=120s 2>/dev/null || true
$K -n capstone-app wait --for=condition=available deploy/dns-checker --timeout=120s 2>/dev/null || true

echo ""
echo "--- Phase 2: injecting faults ---"
echo ""

# ---- Fault 1: Scheduling — taint the GPU worker node ----
echo "Fault 1: Scheduling — tainting GPU worker node ..."
WORKER=$($K get nodes --no-headers -l accelerator=gpu -o jsonpath='{.items[0].metadata.name}')
$K taint nodes "${WORKER}" maintenance=true:NoSchedule --overwrite
# Scale up inference-workers so new pods hit the taint (existing pods keep running)
$K -n capstone-app scale deploy/inference-workers --replicas=4
echo "  Tainted ${WORKER}, scaled inference-workers to 4 replicas (2 running, 2 Pending)"

# ---- Fault 2: CoreDNS — corrupt upstream forwarder ----
echo "Fault 2: CoreDNS — corrupting Corefile ..."
ORIGINAL_COREFILE=$($K -n kube-system get cm coredns -o jsonpath='{.data.Corefile}')
# Save original for the lab (learner can reference it)
echo "${ORIGINAL_COREFILE}" > "${HERE}/corefile-backup.txt"
# Replace the forward directive to point to an unreachable IP
CORRUPTED=$(echo "${ORIGINAL_COREFILE}" | sed 's|forward \. /etc/resolv.conf|forward . 10.0.0.254|')
$K -n kube-system create cm coredns --from-literal="Corefile=${CORRUPTED}" --dry-run=client -o yaml | $K apply -f -
# Restart CoreDNS to pick up the change
$K -n kube-system rollout restart deploy/coredns
echo "  Corefile upstream changed to 10.0.0.254 (unreachable)"

# ---- Fault 3: Operator — delete ConfigMap, restart pod ----
echo "Fault 3: Operator — deleting source ConfigMap ..."
# Save backup for the lab solution
$K -n m5-system get cm website-operator-src -o yaml > "${HERE}/operator-cm-backup.yaml"
$K -n m5-system delete cm website-operator-src
$K -n m5-system delete pod -l app=website-operator --wait=false
echo "  ConfigMap deleted, operator pod restarting (will fail)"

# ---- Fault 4: API throttling — bad FlowSchema ----
echo "Fault 4: API throttling — creating restrictive FlowSchema ..."
$K apply -f - <<'YAML'
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: PriorityLevelConfiguration
metadata:
  name: capstone-throttle
spec:
  type: Limited
  limited:
    nominalConcurrencyShares: 1
    lendablePercent: 0
    limitResponse:
      type: Reject
---
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: FlowSchema
metadata:
  name: throttle-serviceaccounts
spec:
  priorityLevelConfiguration:
    name: capstone-throttle
  matchingPrecedence: 100
  rules:
    - subjects:
        - kind: Group
          group:
            name: "system:serviceaccounts"
      resourceRules:
        - apiGroups: ["*"]
          resources: ["*"]
          namespaces: ["*"]
          verbs: ["list", "watch"]
YAML
echo "  FlowSchema throttle-serviceaccounts → capstone-throttle (1 share)"

# ---- Fault 5: etcd degradation — flood with junk ----
echo "Fault 5: etcd — flooding with junk ConfigMaps (this takes ~60s) ..."
$K create namespace capstone-junk --dry-run=client -o yaml | $K apply -f -
# Create 2000 ConfigMaps with 100-byte values each (~200KB total in etcd)
# Using batched apply for speed
for batch in $(seq 0 19); do
  YAML=""
  for i in $(seq 0 99); do
    NUM=$((batch * 100 + i))
    YAML="${YAML}---
apiVersion: v1
kind: ConfigMap
metadata:
  name: junk-$(printf '%04d' ${NUM})
  namespace: capstone-junk
data:
  padding: \"$(head -c 100 /dev/urandom | base64 | head -c 100)\"
"
  done
  echo "${YAML}" | $K apply -f - >/dev/null 2>&1 || true
  printf "  batch %d/20\r" $((batch + 1))
done
echo "  2000 junk ConfigMaps created in capstone-junk"

# ---- Fault 6: Kueue — set quota to 0 ----
echo "Fault 6: Kueue — setting ClusterQueue quota to 0 ..."
$K patch clusterqueue capstone-cq --type=merge -p '
{
  "spec": {
    "resourceGroups": [{
      "coveredResources": ["cpu", "memory"],
      "flavors": [{
        "name": "capstone-flavor",
        "resources": [
          {"name": "cpu", "nominalQuota": "0"},
          {"name": "memory", "nominalQuota": "0"}
        ]
      }]
    }]
  }
}'
echo "  ClusterQueue capstone-cq: cpu=0, memory=0"

echo ""
echo "=== All 6 faults injected ==="
echo ""
echo "The NimbusAI platform is now experiencing multiple issues."
echo "Hand this cluster to the learner — their mission: triage, diagnose, fix, postmortem."
echo ""
echo "Verify fault status: bash ${HERE}/inject.sh --check"
