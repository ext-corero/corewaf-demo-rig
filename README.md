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

## Status

Migrating out of `corewaf-workspace/local-rig` (deprecated there). This first cut
still builds images from a sibling `corewaf-workspace` checkout (`RIG_MODE=source`);
registry pulls, host prep and the curl bootstrap land in the following commits.
Inventory (names/IPs/MACs) is `inventory.env` — nothing else hardcodes an address.

## Quick start (today)

```bash
task up          # network + VMs + stacks
task verify      # health checklist
task demo:reset  # stage a kit VM and mint a token — see docs/demo-kit.md
```

Host prerequisites for now: libvirt/KVM, `virt-install`, `swtpm`, `xorriso`, Docker,
Taskfile, `dig`, `curl`, `python3`; `~/vm-lab/` prepared base + SSH key; golden image
`.cache/corewaf-kit-base.qcow2` (`scripts/build-kit-base.sh`); `/etc/hosts` entries for
`app-1`/`gui-1`/`dns-1`/`dns-2`/`obs-1.rig.internal`; the egress NAT rule for
`192.168.150.0/24` (`up.sh` prints it). All of this is being folded into `task prep-host`.

- GUI: <http://gui-1.rig.internal:8080> · API: <http://app-1.rig.internal:8080> ·
  Grafana: <http://obs-1.rig.internal:3000>

## Layout

`up.sh` / `down.sh` / `vmlab.sh` — infra VMs · `compose/` — per-role stacks ·
`config/`, `net/`, `seed/` — rig config · `kit-prep.sh` / `kit-enrol.sh` / `kit-up.sh`,
`kit-shim/`, `vm/vmlab.sh` — kit VMs · `packer/` — VM base image · `verify.sh` — health ·
`docs/demo-kit.md` — demo runbook.

License: Apache-2.0.
