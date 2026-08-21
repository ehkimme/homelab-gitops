#!/usr/bin/env bash
# Idempotent repository bootstrap. Runs after the source is checked out and, when
# environment builds are enabled, produces the baseline snapshot.
#
# Responsibilities (all safe to run repeatedly):
#   * ensure the docker daemon is running,
#   * pre-pull the container images the dev loop needs (baked into the snapshot),
#   * validate the Kubernetes manifests with kubeconform.
#
# The kind cluster itself is NOT created here: cluster containers are per-boot
# runtime state and are (re)created by start.sh so they survive snapshot restores.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ensure_docker

VW_IMAGE="$(vaultwarden_image)"
log "vaultwarden image from deployment.yaml: ${VW_IMAGE}"

# Pre-pull images so cluster bring-up in start.sh needs no registry egress.
for img in "${KIND_NODE_IMAGE}" "${REGISTRY_IMAGE}" "${VW_IMAGE}"; do
  log "pulling ${img}"
  dk pull "${img}"
done

log "validating manifests with kubeconform"
kubeconform -summary -strict \
  "${REPO_ROOT}/namespace.yaml" \
  "${REPO_ROOT}/pvc.yaml" \
  "${REPO_ROOT}/service.yaml" \
  "${REPO_ROOT}/deployment.yaml"

log "install complete"
