# CoreWAF demo rig

A self-contained, multi-VM CoreWAF environment for demos and testing: six libvirt
VMs (`app-1`, `dns-1/2`, `gw-1/2`, `obs-1`) on a routed lab network, each running
its own docker stack, plus kit VMs enrolled over the gateway TLS edge + WireGuard.

This repository is **public and deliberately thin**: it only knows how to stand
the environment up. Every container image and the VM base image are pulled from
the CoreWAF registry (AWS ECR), so **nothing here runs without a CoreWAF registry
credential** — an IAM access key for a user in the `corewaf-ecr-pull` group,
issued by the CoreWAF operators.

```
 app-1   .10   etcd · redis · waf-api · waf-gui · caddy :8080 · step-ca :9000
 dns-1/2 .21/.22  redis · coredns :53 · dns-bridge · vmsecd (secrets)
 gw-1/2  .31/.32  tunnel-gateway (WG :51820) · caddy edge :443 (ACME from step-ca)
 obs-1   .40   loki :3100 · mimir :9009 · alertmanager :9093 · grafana :3000
 rig-<kit>     starter-kit VM: netns · tunnel · caddy
```

## Quick start

```bash
git clone https://github.com/ext-corero/corewaf-demo-rig.git && cd corewaf-demo-rig
aws configure --profile corewaf-ecr        # the key your CoreWAF operator issued (IAM group corewaf-ecr-pull)
export AWS_PROFILE=corewaf-ecr
task prep-host   # once: packages, libvirt, groups/ACLs, rig NAT network, /etc/hosts names (one sudo prompt)
task up          # fetch the VM base image + pull all images from the registry, boot 6 VMs
task verify      # health checklist
task demo:reset  # stage a kit VM + mint a token — see docs/demo-kit.md
```

Host: any Linux with KVM (libvirt/qemu are installed by `prep-host`), incl. WSL2 with
nested virtualization. Nothing is built locally: the VM base image and every container
image are pulled from the CoreWAF registry; `RIG_MODE=source` (developer path) builds
from a sibling `corewaf-workspace` instead.

- GUI: <http://gui-1.rig.internal:8080> · API: <http://app-1.rig.internal:8080> ·
  Grafana: <http://obs-1.rig.internal:3000>

## Layout

`up.sh` / `down.sh` / `vmlab.sh` — infra VMs · `compose/` — per-role stacks ·
`config/`, `net/`, `seed/` — rig config · `kit-prep.sh` / `kit-enrol.sh` / `kit-up.sh`,
`kit-shim/`, `vm/vmlab.sh` — kit VMs · `packer/` — VM base image · `verify.sh` — health ·
`docs/demo-kit.md` — demo runbook.

License: Apache-2.0.
