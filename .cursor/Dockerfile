FROM ubuntu:24.04

# Stable system packages and toolchains for a local Kubernetes (kind) dev loop.
# Repository-dependent work (image pre-pull, manifest validation, cluster bring-up)
# happens later in install.sh / start.sh, once the source is checked out.
ENV DEBIAN_FRONTEND=noninteractive

# Versions pinned for deterministic builds.
ARG KUBECTL_VERSION=v1.34.0
ARG KIND_VERSION=v0.30.0
ARG KUBECONFORM_VERSION=v0.7.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        sudo \
        jq \
        docker.io \
        fuse-overlayfs \
        iptables \
        uidmap \
        iproute2 \
    && rm -rf /var/lib/apt/lists/*

# kubectl (matched to the kind node Kubernetes version)
RUN curl -fsSLo /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && chmod 0755 /usr/local/bin/kubectl

# kind (pins the kindest/node image version)
RUN curl -fsSLo /usr/local/bin/kind \
        "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64" \
    && chmod 0755 /usr/local/bin/kind

# kubeconform (manifest schema validation)
RUN curl -fsSLo /tmp/kubeconform.tar.gz \
        "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" \
    && tar -xzf /tmp/kubeconform.tar.gz -C /usr/local/bin kubeconform \
    && chmod 0755 /usr/local/bin/kubeconform \
    && rm -f /tmp/kubeconform.tar.gz

# Docker uses the fuse-overlayfs storage driver, which is required inside the
# nested (unprivileged) Cloud Agent VM where native overlay2 cannot mount.
RUN mkdir -p /etc/docker \
    && printf '{\n  "storage-driver": "fuse-overlayfs",\n  "iptables": true\n}\n' > /etc/docker/daemon.json

# The ubuntu user (uid 1000) runs the agent; give it passwordless sudo and docker access.
RUN groupadd -f docker \
    && usermod -aG docker ubuntu \
    && echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-ubuntu \
    && chmod 0440 /etc/sudoers.d/90-ubuntu

USER ubuntu
WORKDIR /home/ubuntu
