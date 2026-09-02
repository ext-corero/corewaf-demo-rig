# Exploration: the demo rig as a cloud flavor — multi-instance, any-version rigs

> Status: **stashed for later evaluation** (2026-09-02). Analysis only — nothing scheduled.

## Context (idea evaluation — user asked for impact understanding, "nothing to do")
Goal: ad-hoc test/demo environments — several rigs concurrently (different
branches/versions; machine-form vs container-form). Question: model the local
rig as a cloud flavor in the multi-target solution, each rig deployment its own
deployment project? Reuse Terraform with a QEMU target, or script mechanisms?

## Finding 1 — the rig is already a hosts-module in script form
The de-facto provider glue maps ~1:1 onto the multi-cloud contract:
`node/entrypoint.sh` + `qemu/run-node.sh` = the hosts module in two delivery
flavours (container / bare QEMU); `qemu/prep-host.sh` = the foundation layer
(proxmox has the same concept); `node/bin/ignite.sh` = `common/ignition`
(same poseidon/ct 0.13.0, renders the SAME checksum-pinned production Butane
template); `node/bin/rig-init` = assets/keys; `inventory.env` = the
subnets/identity data that `common/identity` derives elsewhere; fw_cfg = the
delivery mechanism (proxmox's hosts module even names fw_cfg as a known
delivery fallback). Divergences without a terraform analogue: 9p shares,
swtpm, ad-hoc reprovision hint. Conceptual distance to "a provider": small.

## Finding 2 — precedent already exists for a NON-terraform provider
`providers/generic` ships NO terraform at all — just the four capability
scripts (`registry/secrets/storage/dns`, INTERFACE.md). The architecture
already admits script-implemented cloud flavors. "Rig as a cloud flavor" does
NOT have to mean "rig via Terraform".

## Finding 3 — what actually blocks concurrency is 14 classes of hardcoded identity
(surveyed with file:line; the recent code/data purification already moved ~80%
of instance identity into inventory.env + generated bootstrap). Remaining:
compose `name: corewaf-demo-rig` + docker net `corewaf-rig` (global names);
pinned `container_name: rig-*` + launcher/extension discovery by `rig-`
prefix; MAC/IP literal DEFAULTS in docker-compose.yml; hardcoded `tap-cw-*`
list + libvirt net/bridge names + masquerade literal in prep-host; the static
`rig.internal` zone file; `system_name/site/deployment_ns/release/namespace`
literals in ignite.sh; CA CN literals; fixed node-name tables in `rig`/
`rig-qemu`; host-wide pgrep on the constant SMBIOS product `demo-rig-node`.
Useful property: DMI UUID/serial and kit hwId derive from the inventory MACs
— re-key the MAC prefix + subnet per instance and all machine identity
follows automatically. Host ports already auto-negotiate (launcher).
Branch-diversity per instance already exists (COREWAF_RIG_REF; per-checkout
`.qemu/`); models 1&3 coexistence fails ONLY on the shared subnet.

## Options
- **A. Full Terraform cloud flavor** (`system.cloud=qemu`, dmacvicar/libvirt
  hosts module, env repo per rig): maximal purity, contract/identity/ignition
  modules reused verbatim — but covers model 3 only (no terraform story for
  the Docker-Desktop container-hypervisor models, which are the demo's reach
  onto Windows/Mac), sacrifices the zero-install launcher/extension UX, large
  build-out, community-provider dependency. Wrong fit for the DEMO; right
  shape someday for a lab cloud.
- **B. Instance profiles (parameterize the scripts)**: `RIG_INSTANCE` +
  per-instance profile (subnet octet, MAC prefix, domain `rig-<i>.internal`,
  project/net/container/tap prefixes, `deployment_ns=…/deployments/<i>`).
  Fixes exactly the 14 sites; concurrency for BOTH model families; keeps the
  demo UX. Moderate, mechanical.
- **C. Hybrid (recommended)**: B's parameterization + the DEPLOYMENT-PROJECT
  DATA SHAPE without the terraform engine — each rig instance is a small
  env-repo-style dataset (instance inventory + version pins + bootstrap
  values), stamped like `init-env.sh` does for real envs; the rig scripts are
  the provider code (workspace), the instance profile is the deployment data.
  This extends the code/data doctrine one level up and matches the
  `providers/generic` precedent (script-implemented flavor). Terraform-libvirt
  can slot in LATER as an alternate model-3 hosts module without changing the
  data shape.

## Direct answers to the questions posed
- Reuse Terraform with a QEMU target? Possible (dmacvicar/libvirt) but only
  for model 3, and it buys nothing the scripts don't already do — defer.
- Script mechanisms different from multi-cloud? They differ in engine, not in
  contract — and `providers/generic` legitimizes exactly that.
- Value: yes — mainly because each rig instance inheriting the
  deployment-project shape makes "deploy another site" and "deploy another
  rig" the SAME mental model, which is what the namespace/label work was for.

## IF pursued (phased outline, not scheduled)
1. Instance-profile mechanics: derive every §3 identity from `RIG_INSTANCE`
   (defaults preserve today's rig verbatim — instance "rig-demo").
2. Zone-file generation from the instance inventory (absorbs follow-up F3;
   also feeds the real `zone-<zone>-seed` artifact build).
3. Instance stamp: `init-env.sh --provider rig <name>`-style creation of the
   per-rig data set; launcher/extension learn the instance prefix.
4. (Optional, later) terraform-libvirt hosts module for model 3 behind the
   same data.
Verification: two instances concurrently on one host (model 1 + model 3, or
two model 3s), both `rig verify` green, no shared docker/libvirt/L2 objects.

## Status: exploration only — recorded; no action requested.
