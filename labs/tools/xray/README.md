# Cluster X-Ray

A live visualizer for YOUR real cluster. One evolving tool, one lens per module —
this is the M1 **Reconciliation Lens**: Deployment spec vs status (generation /
observedGeneration lag), pod chips grouped by node, cordon state, and a live
kubectl-style event stream.

## Run it

```bash
bash labs/tools/xray/serve.sh        # then open http://127.0.0.1:8001/xray/
```

## How it works (this is a teaching point)

There is no backend and no token. `kubectl proxy` serves this static page *and*
forwards `/api/...` to your API server using your kubeconfig credentials — same
origin, so the browser can open raw **watch** streams (`?watch=1`) directly.
Everything you see move is the same event firehose every controller drinks from.

## Troubleshooting

- **Port busy** → `PORT=8002 bash labs/tools/xray/serve.sh`
- **Wrong cluster / empty view** → `kubectl config use-context kind-kubeadv-core`, restart serve.sh
- **"namespace not found yet"** → apply the M1 manifest; the page lights up on its own.
