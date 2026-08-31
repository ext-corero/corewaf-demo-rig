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

## Requirements

The rig boots **six virtual machines** (plus one per kit) under QEMU/KVM, each inside a
Docker container, and each VM runs its own Docker stack. Sizing defaults: app/obs 4 GB,
dns/gw 2 GB, kits 1 GB → **~16 GB of guest RAM**, 12 vCPUs; the VM base image (≈800 MB)
and the container images (≈2 GB) are downloaded once.

| | Minimum | Notes |
|---|---|---|
| CPU | x86-64 with VT-x/AMD-V, 8+ cores | nested virtualization on Windows (below) |
| RAM | 24 GB host (32 GB comfortable) | guests use ~16 GB; override `RIG_*_RAM_MB` in `.env` |
| Disk | 40 GB free | base image + VM overlays + container images |
| Docker | Engine 24+ / Docker Desktop 4.30+, Compose v2.20+ | `docker compose version` |
| KVM | `/dev/kvm` usable **from a container** | the bootstrap probes it: `docker run --rm --device /dev/kvm alpine test -w /dev/kvm` |
| Credential | an AWS access key for the CoreWAF registry | IAM user in group `corewaf-ecr-pull`, issued by the CoreWAF operators |
| Network | outbound HTTPS to `*.amazonaws.com`, `github.com`, Docker Hub, `dl-cdn.alpinelinux.org` | VMs egress through Docker's NAT |
| Tools on the host | `git`, `curl`, `docker` | nothing else — no sudo, no packages, `task` optional |

Host ports published by default: **8080** (GUI/API), **3000** (Grafana), **9000** (step-ca).
The bootstrap picks the next free port when one is taken and records it in `.env`
(`RIG_HTTP_PORT`, `RIG_GRAFANA_PORT`, `RIG_STEPCA_PORT`); `scripts/hosts-block.sh` prints
the matching hosts-file lines.

### Linux (Docker Engine)

- Your user in the `docker` group; `/dev/kvm` present (`ls -l /dev/kvm`; load `kvm_intel`/`kvm_amd` if missing).
- The rig creates the Docker network `corewaf-rig` = `192.168.150.0/24`; it must not overlap
  an existing network/route on the host (a leftover libvirt bridge on that subnet must be removed first).
- The Docker bridge is local, so `192.168.150.x` is reachable directly — `scripts/hosts-block.sh`
  prints `/etc/hosts` lines with the real VM IPs.

### Windows (Docker Desktop, WSL2 backend)

Validated on Windows 11 + Docker Desktop with the WSL2 backend (Ubuntu distro).

1. **Nested virtualization** — `%UserProfile%\.wslconfig`:
   ```ini
   [wsl2]
   nestedVirtualization=true
   memory=24GB          # cap for ALL of WSL2 incl. Docker; ≥ 24 GB recommended
   processors=8
   ```
   then `wsl --shutdown` and start Docker Desktop again. Check from a WSL shell:
   `ls -l /dev/kvm` and `docker run --rm --device /dev/kvm alpine test -w /dev/kvm && echo OK`.
2. **Docker Desktop settings** — *General → Use the WSL 2 based engine*; *Resources → WSL
   integration* enabled for the distro you will use; *Resources → File sharing* includes
   the directory you clone into (default paths under your profile are shared). Keep the
   checkout on the WSL filesystem (e.g. `~/rig`), not under `/mnt/c`, for speed.
3. **Run from a WSL shell** (Ubuntu): the bootstrap and `kit.sh` are bash scripts:
   ```bash
   aws configure --profile corewaf-ecr            # or export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY
   AWS_PROFILE=corewaf-ecr bash <(curl -fsSL https://raw.githubusercontent.com/ext-corero/corewaf-demo-rig/main/bootstrap.sh)
   ```
4. **Reaching the rig from Windows** — container IPs are not routable from Windows; use the
   published ports. `C:\Windows\System32\drivers\etc\hosts`:
   `127.0.0.1 gui-1.rig.internal app-1.rig.internal grafana.rig.internal` → GUI at
   `http://gui-1.rig.internal:<RIG_HTTP_PORT>`, Grafana at `http://grafana.rig.internal:<RIG_GRAFANA_PORT>`.
   Everything that must reach the VMs runs inside the rig network (`task verify`, `task ssh`,
   `kit.sh`), so no route is needed.
5. Non-interactive shells (ssh into WSL, CI): Docker Desktop's credential helper
   (`docker-credential-desktop.exe`) is not on PATH, so pulls fail with
   `error getting credentials`. Use a plain config for the rig: `export DOCKER_CONFIG=$HOME/.docker-rig; echo '{}' > $DOCKER_CONFIG/config.json`
   (the bootstrap's ECR login then lands there). Interactive Docker Desktop shells are unaffected.

See [docs/windows.md](docs/windows.md) for the longer version.

### What the bootstrap does

`bootstrap.sh` checks Docker/Compose, probes KVM inside a container, logs Docker into the
CoreWAF registry with your AWS credential (via a throw-away `aws-cli` container — no aws CLI
needed on the host), clones this repo, picks free host ports, and runs `docker compose up -d`:
`rig-init` pulls the VM base image and generates the rig CA/secrets/ssh key into volumes,
then the six node containers boot their VMs and each VM starts its stack. First run ≈ 7–11 min
depending on bandwidth; later starts ≈ 1–2 min. It is safe to re-run.

## Quick start

Three equivalent entry points — pick one:

**A. curl bootstrap** (Linux console or a WSL shell):
```bash
aws configure --profile corewaf-ecr        # the key your CoreWAF operator issued (IAM group corewaf-ecr-pull)
AWS_PROFILE=corewaf-ecr bash <(curl -fsSL https://raw.githubusercontent.com/ext-corero/corewaf-demo-rig/main/bootstrap.sh)
```

**B. launcher container** — nothing on the host but Docker (works from PowerShell on Docker Desktop too):
```bash
# host docker login (ECR tokens last 12 h — needed only to pull the launcher image itself):
docker run --rm -v ~/.aws:/root/.aws:ro -e AWS_PROFILE=corewaf-ecr public.ecr.aws/aws-cli/aws-cli ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin 123517950721.dkr.ecr.us-east-1.amazonaws.com
docker run --rm -it -v /var/run/docker.sock:/var/run/docker.sock -v ~/.aws:/root/.aws:ro -e AWS_PROFILE=corewaf-ecr \
  123517950721.dkr.ecr.us-east-1.amazonaws.com/io.corewaf.ghcr/rig/launcher:latest up
```
The launcher keeps the rig checkout in a Docker volume (`corewaf-demo-rig_repo`) and drives the same
compose project as the curl path, so the two are interchangeable. Other verbs: `status`, `verify`,
`kit demo|a|b`, `stop`, `down`, `reset`, `logs <node>`, `url`. On Windows/PowerShell use
`-v //var/run/docker.sock:/var/run/docker.sock -v $env:USERPROFILE\.aws:/root/.aws:ro`, or pass
`-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY` instead of mounting `~/.aws`. Inside the rig the guests
authenticate with the credential helper + your key (no expiry); only the host-side pull of the launcher
image needs that 12 h login.

**C. Docker Desktop extension** — buttons instead of a terminal (Windows / macOS / Linux Docker Desktop):
```bash
aws configure --profile corewaf-ecr        # once, on the host (the extension mounts ~/.aws for you)
docker extension install ghcr.io/ext-corero/corewaf-demo-rig/extension:latest
```
Docker Desktop only installs Marketplace extensions by default — the install above fails with
*"only extensions distributed through the Docker Marketplace are allowed"* until you allow it once:
**Docker Desktop → Settings → Extensions → untick "Allow only extensions distributed through the Docker
Marketplace" → Apply & restart**. (Two-line PowerShell/terminal alternative to clicking the checkbox isn't
available; the setting is per machine.) On Windows, run the install from PowerShell, not from a WSL shell —
the extension manager socket is only visible to the Windows CLI.
Then open **Extensions → CoreWAF Demo Rig**: *Up*, *Verify*, *Enrol kit*, *Stop/Down/Reset*, node health chips,
live output, and *Open GUI / Grafana* links. The extension is a thin front end over the launcher (B): its bundled
host helper runs the very same `docker run … rig/launcher <verb>` with `~/.aws` and the docker socket attached
(including the 12 h ECR re-login on *Up*), against the same compose project — so A, B and C are interchangeable
on one host. The image itself is public (no login to install); the rig images still need your pull profile.
Source: `extension/` (React/MUI UI, Go host helper, no backend service).

```bash
cd corewaf-demo-rig
task verify          # health checklist (runs inside the rig network — Windows-friendly)
bash <(curl -fsSL https://raw.githubusercontent.com/ext-corero/corewaf-demo-rig/main/kit.sh) a   # enrol a WAF kit, fully automatic (kits: demo|a|b)
task demo:reset      # stage the demo kit VM + mint a token for the manual, in-VM enrol — see docs/demo-kit.md
task stop / task up  # graceful VM shutdown / boot;   task reset wipes everything
```

- GUI: **<http://gui-1.localhost:8080>** (any OS, no hosts file — the port is `RIG_HTTP_PORT` from `.env`) ·
  Grafana: `http://grafana.localhost:<RIG_GRAFANA_PORT>` · `scripts/hosts-block.sh` prints the optional `rig.internal` hosts lines.
- Developer path: `RIG_MODE=source` builds the images from a sibling `corewaf-workspace` (see `compose/build/`).

## Troubleshooting

### Looking inside the VMs

Everything nests: node containers run QEMU guests, the guests run the actual CoreWAF
containers. Four verbs make that transparent (same verbs from every entry point):

| what | task | launcher / extension |
|---|---|---|
| containers in every guest | `task ps` | `ps` / **Containers** button |
| guest uptime/load/mem/disk | `task stat` | `stat` / **Stat** button |
| logs of an in-guest container | `task logs NODE=gw-1 C=rig2-tunnel-gateway` | `logs gw-1 rig2-tunnel-gateway` |
| run a command in an in-guest container | `docker compose --profile tools run --rm cli rig exec dns-1 rig2-coredns ls /etc/coredns` | `exec …` |

Plus: `rig ssh <node>` for a shell in a guest, `rig-launcher console <node>` (or
`docker logs rig-<node>`) for the VM serial console.


| Symptom | Cause / fix |
|---|---|
| bootstrap: `/dev/kvm is not available to containers` | Linux: enable VT-x/AMD-V, `modprobe kvm_intel`; Windows: `.wslconfig nestedVirtualization=true` + `wsl --shutdown` |
| node container exits with `KVM is required` | same as above (the node refuses to run under emulation) |
| `Bind for 0.0.0.0:3000 failed: port is already allocated` | set `RIG_GRAFANA_PORT` (or `RIG_HTTP_PORT`/`RIG_STEPCA_PORT`) in `.env`; the bootstrap does this automatically |
| `error getting credentials … docker-credential-desktop.exe` | non-interactive WSL shell → `DOCKER_CONFIG` workaround above |
| `rig-init` fails: cannot mint a registry token | AWS credential missing/not in `corewaf-ecr-pull`; `AWS_PROFILE` needs `~/.aws` (mounted into rig-init) |
| network `corewaf-rig`: pool overlaps / has active endpoints | another network on 192.168.150.0/24 (old libvirt bridge), or a stale kit endpoint: `docker network disconnect -f corewaf-rig rig-kit-a` |
| VMs boot but stacks stay unhealthy for minutes | first boot pulls ~2 GB of images inside the guests; `task logs NODE=app-1` shows the VM console |
| `task verify`: "guest egress" red | Docker NAT blocked by a host firewall (WSL: check Windows firewall / VPN clients) |

## Layout

`docker-compose.yml` — the rig (one node container per VM, `kit` and `tools` profiles) ·
`node/` — the rig-node image (QEMU/KVM hypervisor, `rig-init`, `rig` CLI, kit staging) ·
`compose/` — per-role stacks that run *inside* the guests · `config/`, `seed/` — rig config ·
`kit-shim/` — kit install shim · `packer/` — VM base image (built + published by CI) · `launcher/` — the `docker run` entry point ·
`extension/` — Docker Desktop extension (UI over the launcher) ·
`images.env` — every pinned image · `inventory.env` — names/IPs/MACs/sizing ·
`docs/demo-kit.md` — demo runbook · `docs/windows.md` — Docker Desktop notes.

License: Apache-2.0.
