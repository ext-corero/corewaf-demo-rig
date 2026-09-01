# Corero WAAP — Demo Rig

A self-contained, locally runnable demonstration environment for **Corero WAAP**
(Web Application & API Protection), built for **sales engineers**: spin up the full
product on your own laptop, demo it to customers, and use it to build your own
understanding of how the pieces fit — control plane, DNS layer, tunnel gateways,
observability, and enrollable WAAP kits (the customer edge).

Everything runs as containers that each host a real virtual machine (QEMU/KVM), so
what you demonstrate behaves like the shipped product — same images, same enrolment
flow, same GUI — while needing nothing but Docker and one credential.

> Naming note: the product is **Corero WAAP**; you will see the internal codename
> `corewaf` in repository, image and container names.

---

## The three deployment models

| # | Model | Host | Best for |
|---|-------|------|----------|
| 1 | **Docker Desktop extension** | Windows 10/11 (or macOS) with Docker Desktop | SEs on a corporate laptop — buttons, no terminal required |
| 2 | **Docker on Linux** | Any Linux with Docker Engine + KVM | Linux laptops/workstations, headless demo boxes |
| 3 | **Inside a virtual machine** | A QEMU/KVM, vSphere or cloud VM running Linux | Shared demo servers, cloud sandboxes, keeping the laptop clean |

All three run the *same rig* with the same scripts underneath — they are
interchangeable on one host, and every instruction below uses the **stable** release
channel (see [Channels](#channels--versions)).

<a name="registry-credential"></a>
**Common prerequisite — registry credential** (needed once per machine, by every
model; the per-model steps below refer back here):

1. **Install the AWS CLI** — <https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html>
   (Windows: the MSI from the same page; Linux: the zip or your package manager).
2. **Ask your Corero WAAP administrator for an ECR pull user** (they run
   `registry.sh add-user <you>` and send you an access key id + secret).
3. **Configure the profile** with the values from your administrator — example with
   mock data:

   ```console
   $ aws configure --profile corewaf-ecr
   AWS Access Key ID [None]:     AKIAIOSFODNN7EXAMPLE
   AWS Secret Access Key [None]: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
   Default region name [None]:   us-east-1
   Default output format [None]: json
   ```

   The profile name (`corewaf-ecr` here) is yours to choose — just use the same
   name later in the extension's field / the `AWS_PROFILE=` variable.

Hardware for any model: 8+ CPU threads, 24 GB RAM available to the rig, ~40 GB disk,
and hardware virtualization (Intel VT-x / AMD-V) enabled in firmware.

---

## Model 1 — Windows with the Docker Desktop extension

1. **Install Docker Desktop** (WSL2 backend): <https://docs.docker.com/desktop/setup/install/windows-install/>
2. **Enable nested virtualization** — edit `%UserProfile%\.wslconfig`:
   ```ini
   [wsl2]
   nestedVirtualization=true
   memory=24GB
   processors=8
   ```
   then run `wsl --shutdown` in PowerShell and start Docker Desktop again.
3. **Allow non-Marketplace extensions**: Docker Desktop → *Settings → Extensions* →
   untick *"Allow only extensions distributed through the Docker Marketplace"* →
   Apply & restart. (<https://docs.docker.com/extensions/settings-feedback/>)
4. **Install the extension** — PowerShell or `cmd`, both work, **no administrator
   rights needed** (installing Docker Desktop in step 1 is the only admin step; your
   user just needs to be able to run Docker Desktop, i.e. be in the `docker-users`
   group, which the Docker Desktop installer sets up):
   ```powershell
   docker extension install ghcr.io/ext-corero/corewaf-demo-rig/extension:stable
   ```
5. **Registry credential**: complete the [common prerequisite](#registry-credential)
   above (AWS CLI + `aws configure --profile …` in PowerShell) — it is the **same
   credential step**, not an additional one; skip if already done on this machine.
6. **Configure the extension**: open *Extensions → CoreWAF Demo Rig*; set the
   **AWS profile** field to the profile name you created; adjust the GUI/Grafana
   ports only if the defaults (28080/23000) collide on your machine.
7. **Run**: press **Up** and wait (first boot ≈ 10 minutes — the VMs pull their
   images). Chips turn green as nodes come up; then **Open GUI**.
8. **Demo**: **+ Add kit** → *Automated* enrols a WAAP kit end-to-end; *Manual demo*
   stages a kit and hands you the token + the exact in-VM commands a customer would
   run (terminal = click any node chip → Docker Desktop's Exec tab). The **?** button
   holds the full in-app guide; **Refresh kits** revives kits that show stale.

## Model 2 — Docker on Linux

1. **Prerequisites**: Docker Engine 24+ with compose v2, and `/dev/kvm` usable
   (`docker run --rm --device /dev/kvm alpine test -w /dev/kvm && echo OK`).
2. **Registry credential**: the [common prerequisite](#registry-credential) above
   (AWS CLI installed + profile configured); skip if already done on this machine.
3. **Bring it up** (stable channel):
   ```bash
   AWS_PROFILE=corewaf-ecr bash <(curl -fsSL https://raw.githubusercontent.com/ext-corero/corewaf-demo-rig/stable/bootstrap.sh)
   ```
   The bootstrap checks KVM, logs into the registry, clones the rig, picks free
   host ports (recorded in `.env`) and boots the six VMs.
4. **Open it**: the bootstrap prints the URLs — GUI `http://gui-1.localhost:28080`,
   Grafana `http://grafana.localhost:23000` (`*.localhost` needs no hosts file).
   *Optional*: `scripts/hosts-block.sh` prints an `/etc/hosts` block if you also want
   the internal `*.rig.internal` names resolvable from your browser.
5. **Enrol a kit**:
   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/ext-corero/corewaf-demo-rig/stable/kit.sh) a   # kits: demo | a | b
   ```
6. **Day-2** (from the checkout): `task verify | ps | stat | stop | up`, and
   `task demo:*` for the manual, in-VM demo runbook (`docs/demo-kit.md`).

The launcher container is the same thing without a checkout — handy on any machine
with Docker (Windows PowerShell included):
```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v ~/.aws:/root/.aws:ro \
  -e AWS_PROFILE=corewaf-ecr 123517950721.dkr.ecr.us-east-1.amazonaws.com/io.corewaf.ghcr/rig/launcher:stable up
```
Verbs: `up status verify ps stat logs exec kit stage refresh-kits stop down reset url`.

## Model 3 — Inside a virtual machine

Run the whole rig inside one Linux VM — a shared demo server, a cloud sandbox, or a
local QEMU machine — and keep your laptop untouched.

1. **Create the VM** with nested virtualization exposed:
   - QEMU/KVM: `-cpu host` (host must have `kvm_intel nested=1` / `kvm_amd nested=1`);
   - vSphere: VM → CPU → *Expose hardware assisted virtualization to the guest OS*;
   - cloud: pick an instance family that supports nested virt (e.g. bare-metal or
     Azure Dv3+/GCP with nested enabled).
   Size it per the hardware line above (8 vCPU / 24 GB / 40 GB).
2. **Inside the VM**: install Ubuntu 22.04/24.04 (or similar), Docker Engine, and
   verify `/dev/kvm` exists in the guest.
3. **Continue exactly as Model 2** inside the VM — including the
   [common prerequisite](#registry-credential) (AWS CLI + profile) there.
4. **Reaching the GUI from outside the VM**: forward or open the two host ports the
   bootstrap printed (defaults 28080 GUI, 23000 Grafana), then browse
   `http://gui-1.localhost:28080` through an SSH tunnel
   (`ssh -L 28080:localhost:28080 …`) or use the VM's address with a hosts entry
   from `scripts/hosts-block.sh`.

---

## Channels & versions

| | **stable** (use this) | development |
|---|---|---|
| rig code | branch `stable`, tags `vX.Y.Z` | `main` |
| curl | `…/stable/bootstrap.sh` (as above) | same URL with `/main/` |
| launcher | `…/rig/launcher:stable` | `:latest` |
| extension | `…/extension:stable` | `:latest` |

`stable` only moves when a release is cut; every release is a fully pinned runtime
(all images, the VM base, the starter-kit ref). Releases: `scripts/release.sh vX.Y.0`
(from main) or `--patch vX.Y.Z` (hotfix on stable — e.g. a single image pin bump).

## What's in the rig

`app-1` control plane (GUI + APIs + CA) · `dns-1/2` DNS bridges · `gw-1/2` tunnel
gateways (WireGuard) · `obs-1` observability (Grafana/Loki/Mimir) · up to three
**kits** — customer-edge WAAP VMs with TPM-backed identity you enrol live.
Each is a VM inside a container; `rig ps` / `rig stat` (or the extension) show what
runs inside every VM, and any VM's hypervisor shell greets you with a status motd.

## Troubleshooting

| symptom | fix |
|---|---|
| `KVM not available to containers` | firmware VT-x/AMD-V; Windows: `.wslconfig` `nestedVirtualization=true` + `wsl --shutdown` |
| extension install: *"only extensions distributed through the Docker Marketplace"* | Model 1 step 3 |
| registry errors / pull denied | profile name in the extension/env must match `aws configure --profile …`; ask your admin to confirm the ECR user |
| `Bind … failed: port is already allocated` | change the port fields (extension) or `RIG_HTTP_PORT`/`RIG_GRAFANA_PORT` in `.env` |
| kits show **stale** heartbeats in the GUI | press **Refresh kits** (extension) or `… launcher:stable refresh-kits` — enrolments persist |
| kit enrol prints "failed" but the kit looks fine a minute later | slow first boot lost a health-wait race — check the GUI before re-running |
| one node chip red/orange for long | `docker restart rig-<node>`; the boot hook restarts its stack |
| first extension press after an update shows old output | the launcher refreshes in the background — press again |

## Repository layout

`docker-compose.yml` node containers (one VM each) · `node/` hypervisor image +
`rig` CLI · `compose/` in-VM stacks · `launcher/` the `docker run` entry point ·
`extension/` Docker Desktop extension · `packer/` VM base image (CI-built) ·
`images.env` every pin · `inventory.env` addresses/sizing · `scripts/release.sh`
release/hotfix tooling · `docs/` runbooks (demo-kit, windows). Developer mode
(`RIG_MODE=source`, building from a sibling workspace): `compose/build/`.

License: Apache-2.0.
