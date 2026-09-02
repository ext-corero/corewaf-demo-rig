# DEV-LOOP — using the local rig (model 3) to test branches under development

Audience: a development agent (or human) iterating on CoreWAF services
(waf/api, waf/gui, dns-bridge, tunnel-gateway, …) who wants their branch
running inside the local rig within a minute or two. Scope: **model 3 only**
(the pure-QEMU R&D rig on this Linux host). Models 1/2 are the packaged demo
for other machines — they run pinned releases and are NOT part of this loop.

All commands run from the demo-rig checkout root. The rig is assumed up
(`pgrep -c qemu-system` → 7-ish; if not: `RIG_LAUNCH=orchestrator
qemu/rig-qemu up`). The orchestrator launch path is the default dev flow:
export `RIG_LAUNCH=orchestrator` in your shell.

## The loop (per service, ~1-2 min)

1. **Build** the image from your branch/worktree (host-side):
   ```sh
   docker buildx build --load -t corewaf/waf-api:dev-<tag> ../waf/api-service-delivery
   docker buildx build --load -t corewaf/waf-gui:dev-<tag> ../waf/gui
   ```
   (Some repos need a named build context — check the repo's
   .github/workflows for `build-contexts:`; e.g. secrets-manager needs
   `--build-context commons=../waf/component-commons`.)

2. **Load** it into the guest that runs the service (host→guest, no registry):
   ```sh
   source qemu/env.sh
   docker save corewaf/waf-api:dev-<tag> | env NODE_KEY=RIG_APP vm-ssh "sudo docker load"
   ```
   Node map: app-1 (`RIG_APP`) = waf-api, gui, etcd, redis, step-ca,
   caddy-edge · dns-1/dns-2 (`RIG_DNS_1/2`) = dns, vmsecd · gw-1/gw-2
   (`RIG_GW_1/2`) = gw · obs-1 (`RIG_OBS_1`) = obs. Multi-node services
   need the load on each node.

3. **Pin** it with a git-ignored override next to the service manifest:
   ```sh
   cat > services/waf-api/compose.override.yml <<'OVR'
   services:
     waf-api: { image: corewaf/waf-api:dev-<tag>, pull_policy: never }
   OVR
   ```
   (`pull_policy: never` is what lets the orchestrator's unconditional
   `docker compose pull` skip your local-only tag. The compose *service*
   key is the in-file service name — waf-api, waf-gui, dns-bridge,
   tunnel-gateway, … — see the service's compose.yml.)

4. **Restack** the node (fresh staging + re-render + force-recreate):
   ```sh
   RIG_LAUNCH=orchestrator qemu/rig-qemu stack app-1
   ```

5. **Check**:
   ```sh
   RIG_JUICE=0 qemu/rig-qemu verify        # full 32-check health sweep
   qemu/rig-qemu ssh app-1 "sudo docker logs rig2-waf-api --tail 50"
   curl http://app-1.rig.internal:8080/tenants/health
   ```
   GUI: http://gui-1.rig.internal:8080 (hosts entries via
   `scripts/hosts-block.sh` if your browser can't resolve rig.internal).

**Iterate** = repeat 1→4 with a new tag (or reuse the tag; `docker load`
overwrites and force-recreate picks it up). **Revert** = `rm
services/<svc>/compose.override.yml` + restack — the manifest pins
(`services/<svc>/service.json`) restore the released images.

## Data / platform notes

- etcd (platform data) survives restacks. An API branch's loader-zero
  migrations run automatically at container start.
- Reseed demo data anytime: `source qemu/env.sh && rig seed`
  (`NO_CRS=1 rig seed` skips the CRS import).
- **Full platform reset** (schema conflicts, poisoned data): wipe etcd and
  restart everything —
  `qemu/rig-qemu ssh app-1 "sudo docker exec rig2-etcd etcdctl del --prefix ''"`,
  then restack ALL nodes (app-1 dns-1 dns-2 gw-1 gw-2 obs-1), then `rig seed`,
  then re-enrol the kit (`qemu/rig-qemu kit demo`; a rejoin lands in ZTK
  quarantine — clear it: PATCH
  `/provisioning/api/v1/namespaces/corero-core/zero-trust-keys/<id>/status`
  `{"clearanceRequired": false}` with `X-Scope-OrgID: corero-system-owner`
  and the record's `If-Match` ETag). Wipe order matters: all nodes restart,
  not just the API.

## Rules

- **Never commit** a `compose.override.yml` (gitignored) or edit the pins in
  `services/*/service.json` / `images.env` for a dev test — pins are release
  knobs, overrides are the dev mechanism.
- Don't run models 1/2 on this host while model 3 is up (shared
  192.168.150.0/24).
- Don't touch `main`/`stable` of this repo from a dev loop.
- The rig is open by design (plain HTTP, published creds) — never point it
  at real data, and don't "fix" its security.
- If a restack fails, rerun it (the command is idempotent); first boot after
  a host reboot needs `qemu/rig-qemu prep` once (taps + NAT), then `up`.
