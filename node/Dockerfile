# rig-node — the hypervisor container: boots ONE rig VM (QEMU/KVM) from the
# shared Alpine base image, bridges it onto the rig docker network with its own
# IP/MAC, feeds it a NoCloud seed, exposes its serial console as container logs,
# and starts the role's docker stack inside the guest over ssh. Also runs the
# one-shot `rig-init` (base image pull, CA, secrets, keys) and the `cli` tools.
FROM alpine:3.23
RUN apk add --no-cache \
      qemu-system-x86_64 qemu-img swtpm xorriso \
      iproute2 iptables socat openssh-client bash curl jq openssl bind-tools \
      ca-certificates coreutils \
 && qemu-system-x86_64 -device help | grep -q 'virtio-9p-pci' \
 && qemu-system-x86_64 -tpmdev help 2>&1 | grep -q 'emulator'
ARG ORAS_VER=1.3.0
ARG ECR_HELPER_VER=0.9.1
RUN set -e; t=$(mktemp -d); \
    curl -fsSL -o "$t/oras.tgz" "https://github.com/oras-project/oras/releases/download/v${ORAS_VER}/oras_${ORAS_VER}_linux_amd64.tar.gz"; \
    tar -xzf "$t/oras.tgz" -C /usr/local/bin oras; \
    curl -fsSL -o /usr/local/bin/docker-credential-ecr-login \
      "https://amazon-ecr-credential-helper-releases.s3.us-east-2.amazonaws.com/${ECR_HELPER_VER}/linux-amd64/docker-credential-ecr-login"; \
    chmod +x /usr/local/bin/docker-credential-ecr-login /usr/local/bin/oras; rm -rf "$t"; \
    oras version >/dev/null && docker-credential-ecr-login -v >/dev/null
COPY bin/ /usr/local/bin/
# Greeting for interactive shells (Docker Desktop Exec tab): busybox ash reads $ENV.
COPY shrc /etc/rig-shrc
ENV ENV=/etc/rig-shrc
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/*
WORKDIR /rig
ENTRYPOINT ["/entrypoint.sh"]
