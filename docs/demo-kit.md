# Demo runbook — enrolling a WAF kit against the v2 rig

Everything here assumes the v2 rig is up and `task verify` is green
(GUI at http://gui-1.rig.internal:8080). Host prereqs: `task prep-host` (README).

## TL;DR

```bash
cd demo-rig
task verify                 # rig green?
task demo:reset             # (re)stage rig-demo, prints a fresh TOKEN
task kit:console NAME=demo  # login alpine / alpine  (Ctrl-] detaches)
```
inside the VM:
```bash
NO_UP=1 TOKEN=<TOKEN> bash <(curl -fsSL https://raw.githubusercontent.com/ext-corero/corewaf-starter-kit/main/bootstrap.sh)
corewaf-demo-up
```
then GUI → WAF instances → new row in *Pending* with a Live heartbeat →
provision it (Role / Placement / WAF units / Lifecycle).

## Before the demo (once)

```bash
task demo:prep              # == v2/kit-prep.sh demo
```
Boots `rig-demo` (libvirt, swtpm TPM, default NAT), points its resolver at
the dns VMs, stages the starter-kit tree, offline-loads the private GHCR
kit images, installs git, sets the console password, and drops the two
rig-specific bits into `/opt/kit-demo/` plus the `corewaf-demo-up` helper.
Ends with a readiness check (DNS, edge over TLS with the rig CA, TPM,
images). The VM is left running and **not enrolled**; it survives
`virsh shutdown`/`start`, and `task demo:prep` is re-runnable to re-stage.

## During the demo

1. **Token** — GUI: tenant page → *Mint token* → package `tunnel-default`;
   or `task demo:token`. Use the **value only**: starts with `eyJ`, three
   dot-separated segments. (Pasting the `provisioning_token=` prefix along
   with it yields `decode token: header base64: illegal base64 data`.)
2. **Enrol from inside the VM** (the customer experience):
   ```bash
   task kit:console NAME=demo                # alpine / alpine
   NO_UP=1 TOKEN=<TOKEN> bash <(curl -fsSL https://raw.githubusercontent.com/ext-corero/corewaf-starter-kit/main/bootstrap.sh)
   corewaf-demo-up
   ```
   `bootstrap.sh` clones the public kit and writes `config.ini` (`NO_UP=1`
   stops it there). `corewaf-demo-up` then adds what the public kit lacks for
   this rig and runs `docker compose up -d`, waiting for the tunnel to go
   healthy (~1 min; prints the `/redeem` and `foundation tier ready` lines).
   Host-side alternative, same result: `task demo:enrol TOKEN=<TOKEN>`.
3. **Show it** — GUI → WAF instances → Pending; `task demo:instances` shows
   phase + heartbeat age; `task exec ROLE=gw N=1 CMD='doas wg show'` shows
   the peer.

### Why `corewaf-demo-up` exists
The public kit can't enrol against the rig as-is (tested):
- `runtime/operator-ca.crt` is meant to be baked in at release-prep; the
  GitHub clone has none, so first contact with `https://gw-1.rig.internal`
  fails TLS. The helper copies the rig root CA in.
- `compose.yml` doesn't set `NL_PKCS11_PIN` / `TPM2_PKCS11_STORE`, so
  network-loader dies with `pkcs11: PIN required for GenerateKeypair`. The
  helper adds a `docker-compose.override.yml` with `NL_PKCS11_PIN=0000` and
  the store path (what the rig's `install-v2.sh` shim always did). **This
  one is an upstream kit gap** — a real customer on a TPM host hits it too.

## Reset between runs

```bash
task demo:reset             # destroy + re-stage + fresh token (new hwId)
```
Then delete the previous run's row in the GUI (it goes Heartbeat slow →
Stale once its VM is gone). Destroy the VM *before* deleting the record,
otherwise the next heartbeat re-registers it.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `dependency failed to start: corewaf-tunnel is unhealthy`, log says `decode token … illegal base64` | Token pasted with the `provisioning_token=` prefix. `sed -i 's/^provisioning_token=provisioning_token=/provisioning_token=/' config.ini && sudo docker compose down && corewaf-demo-up` |
| tunnel log `pkcs11: PIN required` | `corewaf-demo-up` not run (override missing) |
| tunnel log `x509`/TLS error on `/redeem` | `runtime/operator-ca.crt` missing/wrong — run `corewaf-demo-up` |
| `/reconnect … remote error: tls: expired certificate` | kit's client cert expired (VM was off for weeks) → re-enrol |
| `task verify`: edge `https://gw-N.rig.internal/health` red | edge server cert expired → `task exec ROLE=gw N=<n> CMD='doas docker restart rig2-tunnel-caddy-edge'` |
| `task verify`: coredns unhealthy / "VM egress" red | the rig network must be libvirt NAT: `virsh net-dumpxml corewaf-rig` → `forward mode='nat'`; if not, `task down` then `task prep-host` (redefines it) |
| kit can't resolve `gw-1.rig.internal` | VM `/etc/resolv.conf` not pointing at 192.168.150.21/22 → `task demo:prep` re-stages it |
| GUI badge "Heartbeat slow" | lastSeen 90 s–5 min old: a kit whose VM is gone (delete the row), or the browser tab was backgrounded (the list only polls while visible) |
| `tunnel-mint: no tenants in corero-core` (fresh rig) | `task seed` should create the demo carriers/tenants; the current waf-api demo loader fails on carrier resolution (upstream bug in `waf/api/demo/load.py`). Workaround: `task demo:token TENANT=corero-system-owner-tunnel-gateway` |
| `bootstrap.sh`: `git is required` | VM not staged by the current `kit-prep.sh` → `task demo:prep` |

Useful inside the VM: `cd ~/corewaf-starter-kit && sudo docker compose ps`,
`sudo docker logs -f corewaf-tunnel`, `sudo cat /var/lib/docker/volumes/*tunnel_state*/_data/package.json`.
