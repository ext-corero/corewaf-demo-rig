# CoreWAF demo rig

A self-contained, multi-VM CoreWAF environment for demos and testing: six
VMs (each hosted by a Docker container running QEMU/KVM) (`app-1`, `dns-1/2`, `gw-1/2`, `obs-1`) on a routed lab network, each running
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
aws configure --profile corewaf-ecr        # the key your CoreWAF operator issued (IAM group corewaf-ecr-pull)
AWS_PROFILE=corewaf-ecr bash <(curl -fsSL https://raw.githubusercontent.com/ext-corero/corewaf-demo-rig/main/bootstrap.sh)
```

The rig is a set of Docker containers, **each running one VM under QEMU/KVM** — inside,
every node is a normal VM (own kernel, its own IP on the rig subnet, virtio disk, a TPM for
kits); outside, it is `docker compose`. The bootstrap checks Docker + KVM + your registry
credential, clones this repo and runs `docker compose up -d`: `rig-init` pulls the VM base
image from the CoreWAF registry once (and generates the rig CA/secrets), then the six nodes
boot and start their stacks. No sudo, no packages, nothing built locally.

```bash
cd corewaf-demo-rig
task verify       # health checklist (runs inside the rig network — Windows-friendly)
task demo:reset   # stage a kit VM + mint a token — see docs/demo-kit.md
task stop / up    # graceful VM shutdown / boot; task reset wipes everything
```

Hosts: Linux with KVM, or Windows 11 + Docker Desktop (WSL2, nested virtualization) —
see [docs/windows.md](docs/windows.md). Developer path: `RIG_MODE=source` builds the
images from a sibling `corewaf-workspace` (see `compose/build/`).

- GUI: <http://gui-1.rig.internal:8080> (Linux: real IP; Windows: hosts → 127.0.0.1) ·
  Grafana: `:3000` (override with `RIG_GRAFANA_PORT`) · `scripts/hosts-block.sh` prints the hosts lines.

## Layout

`docker-compose.yml` — the rig (one node container per VM, `kit` and `tools` profiles) ·
`node/` — the rig-node image (QEMU/KVM hypervisor, `rig-init`, `rig` CLI, kit staging) ·
`compose/` — per-role stacks that run *inside* the guests · `config/`, `seed/` — rig config ·
`kit-shim/` — kit install shim · `packer/` — VM base image (built + published by CI) ·
`images.env` — every pinned image · `inventory.env` — names/IPs/MACs/sizing ·
`docs/demo-kit.md` — demo runbook · `docs/windows.md` — Docker Desktop notes.

License: Apache-2.0.
