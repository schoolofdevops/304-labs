# Cluster X-Ray

A live visualizer for YOUR real cluster. One evolving tool, one lens per module.

- **Reconciliation Lens (M1):** Deployment spec vs status (generation /
  observedGeneration lag), pod chips grouped by node, cordon state, and a live
  kubectl-style event stream.
- **Storage Lens (M3):** etcd itself, live — the database file (physical vs logically
  in-use) as paired bars against the 256 MB quota line, a loud NOSPACE alarm banner,
  the MVCC revision counter ticking on every cluster write, apiserver→etcd request
  latency (p50/p99 from `etcd_request_duration_seconds`, delta per poll), and the
  probe trap: `/readyz/etcd` stays `ok` during a NOSPACE alarm (it proves reads),
  while etcd's own `/health` goes 503. Sources: the etcd pod's `:2381/metrics` +
  `/health` through the API server's pod proxy (needs the M3 profile knobs) and the
  apiserver `/metrics`. The M3 lab's fill → alarm → compact/defrag/disarm cycle plays
  out on this lens in real time.
- **Control-Plane Lens (M2):** the control plane itself, live — three signal layers:
  - **L1 · attribution** (works on any cluster): every change on the watch streams is
    attributed via its most-recent `managedFields` manager and `event.source`, then
    pulsed across the diagram — component → api-server → etcd — labeled verb+resource.
  - **L2 · audit stream** (needs the audit-enabled profile): the kube-apiserver's audit
    log is streamed through the proxy into a request ticker — user → verb resource →
    HTTP code + latency. Lease renewals are filtered; `system:` users are hidden by
    default (toggle to show); the page's own `/metrics` polls are excluded.
  - **L3 · APF meters**: `/metrics` polled every 2.5s — seats in use / queued /
    rejected per API Priority & Fairness priority level. This is the M2 lab's
    centerpiece: run a bounded LIST storm and watch the bars move.

## Run it

```bash
bash labs/tools/xray/serve.sh        # then open http://127.0.0.1:8001/xray/
```

For the L2 audit stream, the cluster must be created with the audit-enabled profile:

```bash
bash labs/clusters/core-internals/teardown.sh
AUDIT=1 bash labs/clusters/core-internals/create.sh
```

Without it the lens tells you so and L1 + L3 keep working.

## How it works (this is a teaching point)

There is no backend and no token. `kubectl proxy` serves this static page *and*
forwards `/api/...`, `/metrics`, and pod-log requests to your API server using your
kubeconfig credentials — same origin, so the browser can open raw **watch** streams
(`?watch=1`), follow the apiserver's own audit log (`/log?follow=true`), and scrape
`/metrics` directly. Everything you see move is real API-server traffic.

One constraint shapes the design: browsers allow only **6 concurrent HTTP/1.1
connections per host**. The long-lived streams (nodes/deployments/pods/events watches
+ the audit follow) use 5; namespaces are therefore polled, keeping the last slot free
for `/metrics` and probes.

## Troubleshooting

- **Port busy** → `PORT=8002 bash labs/tools/xray/serve.sh`
- **Wrong cluster / empty view** → `kubectl config use-context kind-kubeadv-core`, restart serve.sh
- **"namespace not found yet"** → apply the M1 manifest; the page lights up on its own.
- **"audit mode off" in the Control-Plane lens** → recreate the profile with `AUDIT=1` (above), restart serve.sh.
- **APF meters frozen** → serve.sh must run with a kubeconfig allowed to GET `/metrics` (kind's default admin is).
- **"Storage lens needs the etcd metrics knob"** → the cluster predates the M3 profile
  (`--listen-metrics-urls`). Recreate once: `bash labs/clusters/core-internals/teardown.sh
  && bash labs/clusters/core-internals/create.sh`, restart serve.sh.
