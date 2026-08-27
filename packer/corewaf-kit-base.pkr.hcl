# corewaf-kit-base — golden image for the launch.sh kit VMs.
#
# Bakes the full kit-side dependency set (docker, git, github-cli, the
# wireguard + TPM kernel modules via linux-lts) into one qcow2 so that
# `launch.sh` can clone a thin copy-on-write overlay and boot a usable
# kit VM in ~15s with zero apk traffic — disposable, even one-shot.
#
# This is the plain-qemu sibling of the libvirt fixture's
# prepare-base.sh / alpine-prepared.qcow2. It bakes a DIFFERENT package
# set (that one targets the 9p/libvirt flow and lacks docker + gh),
# which is why we keep a separate image.
#
# Build via the wrapper (handles the Alpine download + artifact promote):
#   scripts/build-kit-base.sh            # build if missing
#   scripts/build-kit-base.sh --force    # rebuild
#
# packer must be on PATH — it is provided by the workspace devbox, so
# run from inside the corewaf-workspace tree (direnv/devbox active).

packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1.1"
    }
  }
}

variable "base_image" {
  type        = string
  description = "Path to the cached Alpine generic cloud qcow2 to bake from."
}

variable "output_dir" {
  type        = string
  description = "Directory Packer writes the built image into (must not pre-exist)."
}

source "qemu" "kit_base" {
  # Treat the cloud image as a disk to boot, not an installer ISO. Packer
  # copies it into the output dir, so the cached download is never mutated.
  iso_url      = var.base_image
  iso_checksum = "none"
  disk_image   = true
  format       = "qcow2"
  disk_size    = "10G"

  accelerator    = "kvm"
  cpus           = 2
  memory         = 2048
  headless       = true
  net_device     = "virtio-net"
  disk_interface = "virtio"

  # cloud-init seed: enable a root password login so Packer can SSH in and
  # run the provisioner as root (Alpine ships no sudo). PermitRootLogin is
  # flipped on in runcmd because Alpine's sshd defaults to prohibit-password.
  cd_label = "cidata"
  cd_content = {
    "meta-data" = "instance-id: corewaf-kit-base\nlocal-hostname: corewaf-kit-base\n"
    "user-data" = <<-EOF
      #cloud-config
      output:
        all: '| tee -a /var/log/cloud-init-output.log /dev/console'
      ssh_pwauth: true
      disable_root: false
      chpasswd:
        expire: false
        list: |
          root:packer
      bootcmd:
        - sed -i 's|/sbin/agetty -[^ ]* [^ ]* |/sbin/getty |g; s|/sbin/agetty|/sbin/getty|g' /etc/inittab
        - kill -HUP 1
      runcmd:
        - sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        - rc-service sshd restart
    EOF
  }

  ssh_username = "root"
  ssh_password = "packer"
  ssh_timeout  = "5m"

  shutdown_command = "poweroff"

  output_directory = var.output_dir
  vm_name          = "corewaf-kit-base.qcow2"
}

build {
  sources = ["source.qemu.kit_base"]

  provisioner "shell" {
    # Runs as root (ssh_username=root); no privilege escalation needed.
    script = "${path.root}/provision.sh"
  }
}
