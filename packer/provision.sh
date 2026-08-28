#!/bin/sh
# provision.sh — bake the demo rig's VM base image (ONE image for the infra VMs
# app/dns/gw/obs AND the kit VMs). Runs as root inside the Packer build VM.
# Built by CI (.github/workflows/base-image.yml) and published to the CoreWAF
# registry as an OCI artifact; hosts only ever PULL it (scripts/fetch-base.sh).
set -eux

apk update

# linux-lts replaces the cloud image's stripped linux-virt kernel (no tpm_crb,
# no wireguard). linux-firmware-none satisfies its firmware dep with an empty
# package so we skip ~1.3 GB of wifi/gpu blobs a qemu VM never touches.
apk add --no-cache linux-firmware-none
apk add --no-cache \
  docker docker-cli-compose \
  git github-cli curl openssl \
  sudo iproute2 iptables bind-tools \
  wireguard-tools \
  tpm2-tools tpm2-tss-tcti-device \
  linux-lts

# Docker starts on every boot of an overlay.
rc-update add docker default

# Kernel modules on boot (OpenRC `modules` service reads /etc/modules):
#   tpm_crb      — emulated TPM (swtpm) for the kit's PKCS#11-bound mTLS key
#   wireguard    — kit <-> gateway tunnel
#   virtiofs     — infra VMs: /opt/v2, shared secrets, rig CA shares
#   9pnet_virtio — kit VMs: /opt/kit-shim share
printf 'tpm_crb\nwireguard\nvirtiofs\n9pnet_virtio\n' >> /etc/modules

# ECR credential helper: docker mints registry tokens on demand from the AWS
# credentials cloud-init drops into the VM, so long-running VMs can re-pull
# without a 12h token. Pinned release, checksum-verified.
ECR_HELPER_VER="${ECR_HELPER_VER:-0.9.1}"
ECR_HELPER_SHA256="${ECR_HELPER_SHA256:-}"
curl -fsSL -o /usr/local/bin/docker-credential-ecr-login \
  "https://amazon-ecr-credential-helper-releases.s3.us-east-2.amazonaws.com/${ECR_HELPER_VER}/linux-amd64/docker-credential-ecr-login"
if [ -n "$ECR_HELPER_SHA256" ]; then
  echo "${ECR_HELPER_SHA256}  /usr/local/bin/docker-credential-ecr-login" | sha256sum -c -
fi
chmod +x /usr/local/bin/docker-credential-ecr-login

# NO baked /etc/hosts entries: every VM learns its rig addresses from cloud-init
# (resolv.conf -> the dns VMs). The image is topology-agnostic.

# Swap kernels last: removing linux-virt repoints the bootloader at linux-lts.
apk del linux-virt
sync
