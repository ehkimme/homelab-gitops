#!/usr/bin/env bash
# Shared helpers for the homelab-gitops Cloud Agent environment.
# Sourced by install.sh and start.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CLUSTER_NAME="homelab"
KIND_NODE_IMAGE="kindest/node:v1.34.0"
REGISTRY_IMAGE="registry:2"
REGISTRY_NAME="kind-registry"
KIND_NETWORK="kind"
KUBECONFIG_PATH="${HOME}/.kube/config"

export KIND_EXPERIMENTAL_PROVIDER=docker

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Docker must be addressed via sudo because docker-group membership is not active
# in non-login shells inside the VM.
dk() { sudo docker "$@"; }

# The image the manifests deploy, parsed from deployment.yaml so it stays in sync.
vaultwarden_image() {
  grep -Eo 'image:[[:space:]]*[^[:space:]]+' "${REPO_ROOT}/deployment.yaml" \
    | head -1 | awk '{print $2}'
}

# Start dockerd if it is not already responding. Uses the fuse-overlayfs storage
# driver configured in the Dockerfile; safe to call repeatedly.
ensure_docker() {
  if sudo docker info >/dev/null 2>&1; then
    log "docker daemon already running"
    return 0
  fi
  log "starting dockerd (fuse-overlayfs)"
  sudo mkdir -p /var/log
  sudo bash -c 'nohup dockerd >/var/log/dockerd.log 2>&1 &'
  for _ in $(seq 1 30); do
    if sudo docker info >/dev/null 2>&1; then
      log "docker daemon is up"
      return 0
    fi
    sleep 1
  done
  log "ERROR: dockerd did not become ready; last log lines:"
  sudo tail -20 /var/log/dockerd.log || true
  return 1
}
