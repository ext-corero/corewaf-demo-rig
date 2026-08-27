#!/bin/sh
# provision.sh — bake the kit-side dependency set into the golden image.
# Runs as root inside the Packer build VM. Keep this list as the single
# source of truth for "what a launch.sh kit VM needs preinstalled".
set -eux

apk update

# Kit runtime + the github curl-one-liner flow. linux-lts replaces the
# cloud image's stripped linux-virt kernel, which carries neither the
# tpm_crb nor the wireguard modules the kit relies on.
#
# linux-firmware-none satisfies linux-lts's firmware dependency with an
# empty package, so we skip the ~1.3 GB of wifi/gpu blobs a qemu VM never
# touches. Install it first so apk doesn't pull the full linux-firmware.
apk add --no-cache linux-firmware-none
apk add --no-cache \
  docker \
  docker-cli-compose \
  git \
  github-cli \
  curl \
  wireguard-tools \
  tpm2-tools \
  tpm2-tss-tcti-device \
  linux-lts

# Docker starts on every boot of an overlay.
rc-update add docker default

# Load the emulated-TPM CRB driver + wireguard on boot. /etc/modules is
# read by OpenRC's `modules` service, so this survives into every overlay.
printf 'tpm_crb\nwireguard\n' >> /etc/modules

# Bake the rig host mapping: 10.0.2.2 is the qemu SLIRP view of the host,
# where the rig ingress + TLS edge live. Constant for the launch.sh flow,
# so it belongs in the image rather than per-VM cloud-init.
printf '10.0.2.2\tcorewaf.localhost web-ui.localhost\n' >> /etc/hosts

# Swap kernels last: removing linux-virt triggers the bootloader hooks to
# point at linux-lts, which the next boot (the overlay) lands on.
apk del linux-virt

sync
