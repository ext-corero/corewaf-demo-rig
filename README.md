# Corero WAAP — Demo Rig

A self-contained, locally runnable demonstration environment for **Corero WAAP**
(Web Application & API Protection), built for **sales engineers**: spin up the full
product on your own laptop, demo it to customers, and use it to build your own
understanding of how the pieces fit — control plane, DNS layer, tunnel gateways,
observability, and enrollable WAAP kits (the customer edge).

One design rule shapes everything here: **no drift from the shipped product**. The
rig runs the *same virtual machine images and the same software* used across the
project — there is no demo-only fork of anything. That is why the rig runs real
VMs (in the Docker models, VMs *inside* containers), and it is also why the rig is
resource-heavy: the weight is a deliberate outcome of that anti-drift choice, not
an accident — one codebase, one image set, no second schism to maintain. We may
streamline this in the future; correctness of what you demonstrate comes first.

A second design rule is the deliberate counterpart of the first: **simple and open
by design**. The rig keeps *product parity* — same OS images, same provisioning
templates, same software — while deliberately dropping everything that would make
it hard to launch, demo, develop against, or train on:

> ⚠️ **This rig is intentionally insecure and intentionally flat.** One shared
> network, no segmentation or VLANs, no firewalling between nodes, permissive
> registry credentials, shared secrets over host mounts, as few VMs as possible.
> None of this represents — or is any statement about — the security architecture
> of a production deployment. Production systems use segmented networks
> (public/services/private), VM-identity-based registry authentication, a secrets
> manager for all credential distribution, and hardened trust boundaries the rig
> does not implement **by design**. Never treat the rig's wiring as a reference
> for how to secure a real environment; treat it as the easiest honest way to run
> the real product.

> Naming note: the product is **Corero WAAP**; you will see the internal codename
> `corewaf` in repository, image and container names.

---

## The three deployment models

| # | Model | Host | Best for |
|---|-------|------|----------|
| 1 | **Docker Desktop extension** | Windows 10/11 (or macOS) with Docker Desktop | SEs on a corporate laptop — buttons, no terminal required |
| 2 | **Docker on Linux** | Any Linux with Docker Engine + KVM | Linux laptops/workstations, headless demo boxes |
| 3 | **Pure QEMU (no Docker)** | Linux with KVM + libvirt | Developers; validating routing/proxies/TLS natively; LAN-reachable, cloud-like deployments |

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

   ![Corero WAAP Demo Rig extension — main window](images/plugin-main.png)

   What each button does:

   | button | action |
   |---|---|
   | **Up** | pull/refresh the launcher, log into the registry, boot (or update) all six VMs; safe to re-run anytime |
   | **Verify** | the full health checklist (30+ checks: guests, stacks, endpoints, DNS plane, tunnels, instances) |
   | **+ Add kit** | add a WAAP kit — *Automated* (one-click enrolment) or *Manual demo* (staged + token; you enrol inside the VM like a customer) |
   | **Refresh kits** | recreate the kit containers with fresh network endpoints — see below |
   | **Stop** | graceful shutdown of all VMs; disks kept, next Up boots the same VMs |
   | **Down** | remove the containers; volumes (disks, CA, secrets) kept |
   | **Reset** | wipe **everything** including kit identities — asks "Are you sure?"; next Up is a cold start |
   | **Open GUI / Grafana** | open the console / dashboards in your browser (uses the port fields) |
   | **?** | the in-app guide |
   | *node chips* | click any VM to open its terminal (Docker Desktop's Exec tab; `vm-ssh` enters the VM) |

   **Why "Refresh kits" exists**: pressing **Up** deliberately never touches the
   kits (so a staged or enrolled kit survives every rig update) — but on long-running
   Docker Desktop hosts a kit's network endpoint can go stale over time: the GUI
   shows its heartbeat aging ("last seen" hours ago) and the tunnel stops passing
   traffic. **Refresh kits** recreates the kit containers with fresh endpoints;
   the VM disks, TPM identities and enrolments all persist, and the tunnels
   reconnect on their own within about a minute. Any time you lose the connection
   to a kit, this button is the way to reconnect it.
8. **Demo**: **+ Add kit** → *Automated* enrols a WAAP kit end-to-end; *Manual demo*
   stages a kit and hands you the token + the exact in-VM commands a customer would
   run (terminal = click any node chip → Docker Desktop's Exec tab, shown below —
   the shell greets you with the node's status and the `vm-ssh`/`console` hints).
   The **?** button holds the full in-app guide; **Refresh kits** revives kits that
   show stale.

   ![Node terminal — Docker Desktop Exec tab with the rig motd](images/exec-terminal.png)

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

## Model 3 — Pure QEMU on Linux (no Docker on the host)

The rig's VMs run directly under QEMU/KVM on your Linux machine — no Docker layer,
and the VMs sit on a routed libvirt bridge as **first-class network citizens**:
every service is reachable at its real IP and internal URL (`gui-1.rig.internal`,
`gw-1.rig.internal`, …), edge TLS presents real SNI, and — in route mode — other
machines on your LAN reach the rig like any cloud environment. Same images, same
pins, same scripts as the Docker models; only the hypervisor layer differs.
Preferred for development and for validating proxies/gateways end-to-end.

1. **One-time host prep** (root, once): `qemu/prep-host.sh` — installs
   qemu/libvirt/swtpm/oras tooling, defines the `corewaf-rig-qemu` NAT network
   (bridge `virbr-cwrig`, 192.168.150.1/24), and creates per-node user-owned taps.
2. **Registry credential**: the [common prerequisite](#registry-credential).
3. **Up**:
   ```bash
   AWS_PROFILE=corewaf-ecr qemu/rig-qemu up      # rig-init + six VMs; ~10 min first boot
   ```
   State lives under `.qemu/` in the checkout (disks, CA, secrets, logs).
4. **Browse natively**: add the hosts block (`scripts/hosts-block.sh`, paste with
   sudo) and open `http://gui-1.rig.internal:8080` / `http://grafana.rig.internal:3000`
   — real IPs, no port mapping.
5. **Kits**: `AWS_PROFILE=… qemu/rig-qemu kit a` (or `demo`/`b`) — same enrolment
   flow as everywhere else. `verify`, `ssh NODE`, `console NODE`, `status`,
   `stack NODE`, `stop`, `destroy` round out the verbs.
6. **LAN / cloud-like access from other machines** (optional): switch the network
   to routed mode — `qemu/rig-qemu net route` prints the two root commands
   (network redefine + ip_forward/masquerade), then `qemu/rig-qemu route-info`
   prints what the *other* machine needs: one static route
   (`ip route add 192.168.150.0/24 via <this-host>` / Windows `route add`) plus
   the hosts block. After that, a desktop box browses `gui-1.rig.internal`,
   negotiates the gateways' TLS and exercises every proxy exactly as a customer
   network would.

---

## Guest OS: Flatcar (feature)

On `feature/flatcar-v0` the infra guests boot **Flatcar Container Linux**, provisioned by
**Ignition rendered from the production Butane template** — byte-identical to the template the
production estates deploy (checksum-pinned, `scripts/check-template-sync.sh`). Rig-only
concerns (9p shares, router-mode /32 networking, node identity, registry auth) live in a
separate Ignition overlay merged after the template. Kits stay on Alpine — they emulate
customer edge hardware.

- **Default.** Infra guests boot Flatcar; `RIG_OS=alpine` selects the legacy path (kits are always Alpine).
- **Artifacts, not baked images:** the OS image is stock upstream Flatcar republished to the
  registry (`os-images/flatcar-qemu`, A/B-update path preserved); boot payloads (the
  docker-compose sysext + ECR credential helper) ship as a scratch container image
  (`os-images/bootstrap-artifacts`) that the guest **docker-fetches at boot** — the same
  chain a registry-backed cloud deployment uses. `RIG_BOOTSTRAP_CARRIER=iso` exercises the
  vSphere-style CD-ROM bridge instead.
- **Auth chain:** first boot pulls with a provision-time registry token; the template's
  install-bootstrap installs the credential helper from the payload and switches docker to
  the durable helper form.
- **Browser URLs are model-driven:** `/etc/corewaf-bootstrap` carries `PUBLIC_API_HOST` —
  `app-1.localhost:<port>` on the Docker models, `app-1.<zone>:8080` on bridge/cloud models.
- **Reprovision:** config changes re-apply via `sudo /reprovision` + a VM restart (fw_cfg is
  read at QEMU start). The docker volume (2nd disk, label `docker`) survives the ROOT wipe.
- **Caveat:** models 1/2 and model 3 share subnet `192.168.150.0/24` — do not run both on
  one host at the same time.

## Orchestrator launch path (Step 1, `RIG_LAUNCH=orchestrator`)

Branch `feature/orchestrator-v0` adds the first step of the orchestrator
migration: the same ssh-driven `vm-stack`, but instead of the proprietary
launch data (`compose/<role>.yml` + `inventory.env`/`images.env`), each guest
runs the production shape — per-service `service.json` (schema 0.0.6) +
`compose.yml` under `services/`, consumed by `orchestrator compose up`
(the local, unattested verb). Opt-in: `RIG_LAUNCH=orchestrator` (default stays
the legacy compose path until the flip).

- **Data model**: bootstrap (`/etc/corewaf-bootstrap`, mounted at
  `/etc/bootstrap` inside the orchestrator container) = system-wide keys +
  per-VM identity, written by `ignite.sh` (incl. `system_ns`, `root_ca_cert`).
  Manifests = service/artifact data: `sources` (CoreWAF image pins — THE
  release knob; edit `sources.<h>.version` to select a release), `variables`
  (upstream pins, service config; a variable named like a bootstrap key
  overrides it — e.g. `root_ca_cert`). Production secrets appear as plain
  variables (`_comment: prod: secrets provider`) — the rig runs no security
  by design.
- **Layout**: `services/<svc>/{service.json,compose.yml}`;
  `services/roles/<role>` = the ordered per-role service list (retires with
  discovery in Step 3). App node splits by artifact boundary: step-ca, etcd,
  redis, waf-api, gui, caddy-edge on a shared external `app-rig` network
  (created idempotently by each manifest; cross-service DNS = compose aliases).
- **Quick-dev**: build an image locally, then drop a git-ignored
  `services/<svc>/compose.override.yml`:
  `services: { waf-api: { image: corewaf/waf-api:dev, pull_policy: never } }`
  — compose auto-discovers it and `docker compose pull` skips the local-only
  tag (verified with the shipped compose v2.27.0). Remove the file to return
  to the manifest pin. `RIG_MODE=source` stays a legacy-path feature.
- **Flip caveats (warm rig)**: fresh compose projects mean fresh volumes —
  etcd state (and the demo data) resets: run `rig seed` after the first
  orchestrator bring-up. Flip ALL nodes before seeding (a still-running
  legacy gateway re-registers into the fresh etcd and the new gateway then
  refuses the name; the same happens to dns-bridges and secrets-managers —
  recovery: `etcdctl del --prefix /corero-core/system/<kind>/` (tunnel-gateways,
  dns-bridges/<stale-id>, secrets-managers) on the app node's etcd; each
  service re-registers within its retry loop, ~15-45s).
  Re-enrol kits afterwards with a FULL purge first (`docker ps -aq --filter
  name=corewaf- | xargs docker rm -f` + `rm -rf /var/lib/tunnel/*` — the
  netns container holds old wg routes); the rejoin lands in the designed
  ZTK-quarantine flow (operator clearance in the GUI).
- **Demo data is NOT the rig's**: it lives in `waf/api/demo/` and is owned +
  versioned by the API (ships inside the waf-api image at `/app/demo` — see
  `waf/api/demo/README.md`). `rig seed` only invokes it in the running
  container, always through the platform HTTP API; the rig carries no demo
  data and nothing writes etcd directly.
- Orchestrator omissions found during this work are logged in
  `corewaf-workspace/orchestrator/docs/rig-homologation-findings.md`.
- Step 2: CI publishes per-service OCI bundles; `run --artifact-ref` replaces
  `compose up` (attestation turns on). Step 3: discovery/loader; the roles
  files and the ssh loop retire.

## Roadmap — the three demo tracks

Now that the rig runs the production OS/provisioning stack on all three models, the
functional goals ahead are organized as three tracks (this section is the living plan):

1. **Modularity (redundancy on demand).** The demo should let the user choose whether
   they want redundancy for the main features. Skipping the second DNS and second
   gateway saves two VMs (~4 GB and minutes of boot) when the demo doesn't need the
   failover story. First concrete step: a **system-size selector in the Docker Desktop
   extension** — *Minimal* (no dns-2/gw-2, Backstage not started by default) vs *Full*
   (everything, as today). **Shipped**: three checkboxes in the extension — *Redundant
   GW+DNS* (default on), *OBS* (default on), *Backstage* (default off) — drive
   `RIG_REDUNDANCY`/`RIG_OBS`/`RIG_BACKSTAGE` on every Up; `verify`/`ps`/`stat` scope
   themselves accordingly. Model 3 users compose their own set and don't need this.

2. **Curated demo data.** The demo data set we have used in past demos becomes a
   **persistent, maintained artifact of the corewaf workspace** — versioned, fixed and
   extended over time like any other component, and loaded into the rig so a freshly
   launched system is populated and demo-ready instead of empty. (First task: locate
   the existing set and promote it into the workspace.)

3. **Data path (later).** A **protected entity** behind the WAAP: real traffic
   forwarded through an enrolled WAAP kit to a demo origin, preferably exercising the
   curated demo data from track 2 — dashboards moving, attacks blocked, the full
   story. *Deliberately deferred*: it needs focused attention and a newer release of
   the API before the rig can wire it. **The origin is already in place**: OWASP
   Juice Shop runs as a plain container on the rig network
   (`juice.rig.internal:3000`, its own *Juice Shop* checkbox, green health in
   Docker Desktop), reachable from the kit VMs only — no host exposure.
   Model 3: run it on the host (`docker run -d --name rig-juice -p 3000:3000
   bkimminich/juice-shop:v20.2.0`); kits reach it via the bridge gateway IP.

Beyond the demo tracks, the rig's second job is **development**: the first feature to
be homologated and integrated on the rig is the **orchestrator** — which is also when
the launch path (today's ssh-driven `vm-stack`) converges on the production
`compose-stacks` flow, in one migration.

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
