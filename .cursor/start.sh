#!/usr/bin/env bash
# Per-boot reconciliation. Brings up a local kind cluster and deploys the
# repository's manifests so the environment is usable end to end on every start.
#
# It is idempotent: an existing cluster is reused, and applying the manifests
# again is a no-op. Cluster/registry containers do not survive a snapshot
# restore, so they are (re)created here rather than in install.sh.
#
# Notes on the nested Cloud Agent VM (discovered during setup):
#   * Docker uses the fuse-overlayfs storage driver (native overlay2 cannot mount).
#   * bridge-nf-call-iptables must be 0 so same-bridge (node<->registry) traffic
#     is L2-switched instead of dropped by the host's broken nftables forward path.
#   * The kind node has no external registry egress, so images are served from a
#     local registry on the kind network via a containerd registry mirror.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ensure_docker

# Allow intra-bridge (node <-> local registry) traffic to be switched at L2.
sudo sysctl -w net.bridge.bridge-nf-call-iptables=0 >/dev/null 2>&1 || true
sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=0 >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 1. kind cluster
# ---------------------------------------------------------------------------
if sudo kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  log "kind cluster '${CLUSTER_NAME}' already exists"
else
  log "creating kind cluster '${CLUSTER_NAME}'"
  sudo -E kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_NODE_IMAGE}" --wait 120s
fi

log "exporting kubeconfig to ${KUBECONFIG_PATH}"
mkdir -p "$(dirname "${KUBECONFIG_PATH}")"
sudo -E kind export kubeconfig --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG_PATH}"
sudo chown -R "$(id -u):$(id -g)" "$(dirname "${KUBECONFIG_PATH}")"
export KUBECONFIG="${KUBECONFIG_PATH}"

NODE="${CLUSTER_NAME}-control-plane"

# ---------------------------------------------------------------------------
# 2. Local registry on the kind network (image source for the cluster)
# ---------------------------------------------------------------------------
if [ -z "$(dk ps -q -f name="^${REGISTRY_NAME}$")" ]; then
  dk rm -f "${REGISTRY_NAME}" >/dev/null 2>&1 || true
  log "starting local registry '${REGISTRY_NAME}'"
  dk run -d --restart=always --name "${REGISTRY_NAME}" \
    --network "${KIND_NETWORK}" -p 127.0.0.1:5001:5000 "${REGISTRY_IMAGE}" >/dev/null
else
  log "local registry '${REGISTRY_NAME}' already running"
fi

REG_IP="$(dk inspect -f "{{(index .NetworkSettings.Networks \"${KIND_NETWORK}\").IPAddress}}" "${REGISTRY_NAME}")"
log "registry IP on '${KIND_NETWORK}' network: ${REG_IP}"

VW_IMAGE="$(vaultwarden_image)"
log "publishing ${VW_IMAGE} to the local registry"
dk pull "${VW_IMAGE}" >/dev/null 2>&1 || true   # cached from install.sh / snapshot
dk tag "${VW_IMAGE}" "localhost:5001/${VW_IMAGE}"
dk push "localhost:5001/${VW_IMAGE}" >/dev/null

# ---------------------------------------------------------------------------
# 3. Point the node's containerd at the local registry (mirror for docker.io)
# ---------------------------------------------------------------------------
log "configuring containerd registry mirror in ${NODE}"
dk exec "${NODE}" sh -c 'grep -q "config_path = \"/etc/containerd/certs.d\"" /etc/containerd/config.toml \
  || printf "\n[plugins.\"io.containerd.grpc.v1.cri\".registry]\n  config_path = \"/etc/containerd/certs.d\"\n" >> /etc/containerd/config.toml'
dk exec "${NODE}" sh -c "mkdir -p /etc/containerd/certs.d/docker.io && cat > /etc/containerd/certs.d/docker.io/hosts.toml <<EOF
server = \"https://registry-1.docker.io\"
[host.\"http://${REG_IP}:5000\"]
  capabilities = [\"pull\", \"resolve\"]
EOF"
dk exec "${NODE}" systemctl restart containerd

# Wait for the node to be Ready again after the containerd restart.
for _ in $(seq 1 30); do
  if kubectl get node "${NODE}" >/dev/null 2>&1 \
     && [ "$(kubectl get node "${NODE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = "True" ]; then
    break
  fi
  sleep 2
done

log "pre-pulling ${VW_IMAGE} into the cluster via the mirror"
dk exec "${NODE}" crictl pull "docker.io/${VW_IMAGE}" >/dev/null

# ---------------------------------------------------------------------------
# 4. Deploy the manifests
# ---------------------------------------------------------------------------
log "applying manifests"
kubectl apply \
  -f "${REPO_ROOT}/namespace.yaml" \
  -f "${REPO_ROOT}/pvc.yaml" \
  -f "${REPO_ROOT}/service.yaml" \
  -f "${REPO_ROOT}/deployment.yaml"

log "waiting for vaultwarden rollout"
kubectl -n vaultwarden rollout status deploy/vaultwarden --timeout=180s

log "start complete — cluster '${CLUSTER_NAME}' is ready"
kubectl -n vaultwarden get pods
