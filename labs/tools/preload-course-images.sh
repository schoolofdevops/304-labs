#!/usr/bin/env bash
set -euo pipefail

# Pull course images through the host Docker daemon, then import them into the
# containerd image store inside each kind node. This is useful when host pulls
# work but Pods fail with x509 errors behind a corporate firewall.

MODE="pull-and-load"
SCOPE="all"
CLUSTERS=()
IMAGES=()
HOST_ONLY_IMAGES=()

usage() {
  cat <<'EOF'
Usage: bash labs/tools/preload-course-images.sh [options]

Options:
  --pull-only           Pull every selected image into host Docker; do not load a cluster
  --load-only           Load images already present in host Docker; do not contact registries
  --cluster NAME        Load only this kind cluster (repeatable)
  --scope NAME          all (default), core, cilium, or capstone
  --list                Print the pinned image inventory and exit
  -h, --help            Show this help

Examples:
  bash labs/tools/preload-course-images.sh --pull-only
  bash labs/tools/preload-course-images.sh --load-only --cluster kubeadv-core --scope core
EOF
}

append_unique() {
  local candidate="$1" existing
  for existing in "${IMAGES[@]:-}"; do
    [ "${existing}" = "${candidate}" ] && return
  done
  IMAGES+=("${candidate}")
}

add_core_images() {
  append_unique "nginx:alpine"
  append_unique "nginx:1.27-alpine"
  append_unique "registry.k8s.io/pause:3.9"
  append_unique "registry.k8s.io/kwok/kwok:v0.8.0"
  append_unique "alpine/k8s:1.31.3"
  append_unique "registry.k8s.io/dra-example-driver/dra-example-driver:v0.4.0"
  append_unique "registry.k8s.io/kueue/kueue:v0.17.2"
  append_unique "busybox:1.36"
  append_unique "python:3.12-slim"
}

add_cilium_images() {
  append_unique "quay.io/cilium/cilium:v1.19.5"
  append_unique "quay.io/cilium/cilium-envoy:v1.36.8-1781157951-a7f42a3390781539911b5b9107881b35ecc4e752"
  append_unique "quay.io/cilium/operator-generic:v1.19.5"
  append_unique "quay.io/cilium/hubble-relay:v1.19.5"
  append_unique "nginx:1.27-alpine"
  append_unique "curlimages/curl:8.11.0"
}

add_capstone_images() {
  append_unique "registry.k8s.io/kueue/kueue:v0.17.2"
  append_unique "alpine/k8s:1.31.3"
  append_unique "nginx:1.27-alpine"
  append_unique "busybox:1.36"
}

containerd_ref_for() {
  local image="$1" first
  if [[ "${image}" != */* ]]; then
    printf 'docker.io/library/%s\n' "${image}"
    return
  fi

  first="${image%%/*}"
  case "${first}" in
    *.*|*:*|localhost)
      printf '%s\n' "${image}"
      ;;
    *)
      printf 'docker.io/%s\n' "${image}"
      ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pull-only)
      MODE="pull-only"
      ;;
    --load-only)
      MODE="load-only"
      ;;
    --cluster)
      [ "$#" -ge 2 ] || { echo "--cluster requires a name" >&2; exit 2; }
      CLUSTERS+=("$2")
      shift
      ;;
    --scope)
      [ "$#" -ge 2 ] || { echo "--scope requires a name" >&2; exit 2; }
      SCOPE="$2"
      shift
      ;;
    --list)
      MODE="list"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

case "${SCOPE}" in
  core)
    add_core_images
    ;;
  cilium)
    add_cilium_images
    ;;
  capstone)
    add_capstone_images
    ;;
  all)
    add_core_images
    add_cilium_images
    add_capstone_images
    HOST_ONLY_IMAGES=(
      "kindest/node:v1.35.0"
      "registry.k8s.io/etcd:3.6.6-0"
      "registry.k8s.io/kube-apiserver:v1.35.0"
      "registry.k8s.io/kube-controller-manager:v1.35.0"
      "registry.k8s.io/kube-scheduler:v1.35.0"
    )
    ;;
  *)
    echo "Unknown scope '${SCOPE}'. Use all, core, cilium, or capstone." >&2
    exit 2
    ;;
esac

if [ "${MODE}" = "list" ]; then
  echo "Images loaded into kind nodes (scope: ${SCOPE}):"
  printf '  %s\n' "${IMAGES[@]}"
  if [ "${#HOST_ONLY_IMAGES[@]}" -gt 0 ]; then
    echo
    echo "Host-only images used to create kind/KWOK clusters:"
    printf '  %s\n' "${HOST_ONLY_IMAGES[@]}"
  fi
  exit 0
fi

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }

if [ "${MODE}" != "load-only" ]; then
  echo "Pulling ${#IMAGES[@]} course workload images through host Docker ..."
  for image in "${IMAGES[@]}"; do
    echo "  pull ${image}"
    docker pull "${image}"
  done

  for image in "${HOST_ONLY_IMAGES[@]}"; do
    echo "  pull ${image} (host only)"
    docker pull "${image}"
  done
fi

if [ "${MODE}" = "pull-only" ]; then
  echo "Host image cache is ready. Set COURSE_IMAGE_CACHE=1 before creating course clusters."
  exit 0
fi

command -v kind >/dev/null 2>&1 || { echo "kind is required to load cluster nodes" >&2; exit 1; }

if [ "${#CLUSTERS[@]}" -eq 0 ]; then
  while IFS= read -r cluster; do
    [ -n "${cluster}" ] && CLUSTERS+=("${cluster}")
  done < <(kind get clusters 2>/dev/null || true)
fi

if [ "${#CLUSTERS[@]}" -eq 0 ]; then
  echo "No kind cluster exists. Images are ready in host Docker."
  echo "After cluster creation, rerun with --load-only --cluster NAME --scope SCOPE."
  exit 0
fi

for image in "${IMAGES[@]}"; do
  if ! docker image inspect "${image}" >/dev/null 2>&1; then
    echo "Missing host image: ${image}" >&2
    echo "Run this script with --pull-only before using --load-only." >&2
    exit 1
  fi
done

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/304-course-images.XXXXXX")"
trap 'rm -rf "${TEMP_DIR}"' EXIT

for image in "${IMAGES[@]}"; do
  target_nodes=()
  containerd_ref="$(containerd_ref_for "${image}")"

  for cluster in "${CLUSTERS[@]}"; do
    if ! kind get clusters 2>/dev/null | grep -qx "${cluster}"; then
      echo "kind cluster '${cluster}' does not exist" >&2
      exit 1
    fi
    while IFS= read -r node; do
      [ -n "${node}" ] || continue
      if docker exec "${node}" ctr --namespace=k8s.io images list -q | grep -Fxq "${containerd_ref}"; then
        echo "  present ${image} -> ${cluster}/${node}"
      else
        target_nodes+=("${cluster}|${node}")
      fi
    done < <(kind get nodes --name "${cluster}")
  done

  if [ "${#target_nodes[@]}" -eq 0 ]; then
    continue
  fi

  safe_name="$(printf '%s' "${image}" | tr '/:@' '____')"
  archive="${TEMP_DIR}/${safe_name}.tar"
  echo "Saving ${image} once for node import ..."
  docker save -o "${archive}" "${image}"

  for target in "${target_nodes[@]}"; do
    cluster="${target%%|*}"
    node="${target#*|}"
    echo "  load ${image} -> ${cluster}/${node}"
    docker exec -i "${node}" ctr --namespace=k8s.io images import --digests - < "${archive}" >/dev/null
    docker exec "${node}" ctr --namespace=k8s.io images list -q | grep -Fxq "${containerd_ref}" || {
      echo "Image import verification failed: ${image} on ${node}" >&2
      exit 1
    }
  done
done

echo "Course images loaded into: ${CLUSTERS[*]}"
