# Advanced Kubernetes (304) — Lab Files

Hands-on lab assets for **Advanced Kubernetes: Production-Scale Internals & the
AI-Native Platform** by [School of DevOps & AI](https://schoolofdevops.com).

Course content lives at **https://schoolofdevops.github.io/304-kubeadv/** — start
with the Setup section there. This repo is the only thing you clone:

```bash
git clone https://github.com/schoolofdevops/304-labs.git
cd 304-labs
```

All lab commands in the course run from this directory.

## Layout

```
labs/
├── clusters/<profile>/   # cluster profiles — create.sh / verify.sh / teardown.sh
│   └── core-internals/   # M1–M2: kind, 1 control-plane + 1 worker, k8s v1.35
└── m<N>/                 # per-module manifests + checks.json (automated lab checks)
```

## Rules

- **One cluster profile at a time.** Every profile ships create/verify/teardown.
- Requirements: 8 GB RAM min (16 GB recommended), Rancher Desktop (Moby/dockerd
  engine), kind ≥ 0.32, kubectl ≥ 1.35, helm, kwok, cilium-cli, hubble, git —
  full install guide in the course Setup section.
- All images are multi-arch (Apple Silicon + x86-64). No GPU, no cloud account.
