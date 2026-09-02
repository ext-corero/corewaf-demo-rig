# rig-node — the hypervisor container: boots ONE rig VM (QEMU/KVM) from the
# shared Alpine base image, bridges it onto the rig docker network with its own
# IP/MAC, feeds it a NoCloud seed, exposes its serial console as container logs,
# and starts the role's docker stack inside the guest over ssh. Also runs the
# one-shot `rig-init` (base image pull, CA, secrets, keys) and the `cli` tools.
FROM alpine:3.23
RUN apk add --no-cache \
      qemu-system-x86_64 qemu-img swtpm xorriso \
      iproute2 iptables socat openssh-client bash curl jq openssl bind-tools \
      ca-certificates coreutils unzip \
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
# Render toolchain for RIG_OS=flatcar: terraform + poseidon/ct provider in an OFFLINE
# filesystem mirror — the production Butane template is rendered with the production
# semantics (templatefile + ct), no network at render time.
ARG TF_VER=1.9.8
ARG TF_SHA=186e0145f5e5f2eb97cbd785bc78f21bae4ef15119349f6ad4fa535b83b10df8
ARG CT_VER=0.13.0
ARG CT_SHA=24d86adcba92ad0f13870d5e0d217c395aa90ff1e9234fe0c9b7c6eb65abb3a8
RUN set -e; t=$(mktemp -d); \
    curl -fsSL -o "$t/tf.zip" "https://releases.hashicorp.com/terraform/${TF_VER}/terraform_${TF_VER}_linux_amd64.zip"; \
    echo "${TF_SHA}  $t/tf.zip" | sha256sum -c -; \
    unzip -q "$t/tf.zip" -d /usr/local/bin terraform; \
    m=/usr/local/share/terraform/mirror/registry.terraform.io/poseidon/ct; mkdir -p "$m"; \
    curl -fsSL -o "$m/terraform-provider-ct_${CT_VER}_linux_amd64.zip" \
      "https://github.com/poseidon/terraform-provider-ct/releases/download/v${CT_VER}/terraform-provider-ct_${CT_VER}_linux_amd64.zip"; \
    echo "${CT_SHA}  $m/terraform-provider-ct_${CT_VER}_linux_amd64.zip" | sha256sum -c -; \
    printf 'provider_installation {\n  filesystem_mirror {\n    path = "/usr/local/share/terraform/mirror"\n  }\n}\n' > /etc/terraform.tfrc; \
    rm -rf "$t"; terraform version >/dev/null
ENV TF_CLI_CONFIG_FILE=/etc/terraform.tfrc
COPY bin/ /usr/local/bin/
COPY flatcar/ /usr/local/share/rig-flatcar/
# Greeting for interactive shells (Docker Desktop Exec tab): busybox ash reads $ENV.
COPY shrc /etc/rig-shrc
ENV ENV=/etc/rig-shrc
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/*
WORKDIR /rig
ENTRYPOINT ["/entrypoint.sh"]
