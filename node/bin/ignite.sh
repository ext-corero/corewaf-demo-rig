#!/usr/bin/env bash
# ignite.sh — render the Ignition config for a Flatcar infra node (RIG_OS=flatcar).
# The PRODUCTION Butane template is rendered verbatim with the production toolchain
# (terraform templatefile + poseidon/ct), then Ignition-merged with a rig-only overlay
# (9p shares, router-mode /32 networking, node identity, registry auth, docker disk).
# Usage: ignite.sh <out-dir>   (env contract identical to seed.sh)
# Output: $OUT/config.json (fw_cfg payload); prints its path. Re-provisioning:
# Ignition is first-boot-only — when the rendered config changes on an existing disk,
# run `vm-ssh 'sudo /reprovision'` and reboot (the prod template ships /reprovision).
set -euo pipefail
source "${RIG_LIB:-/usr/local/bin/rig-lib.sh}"
OUT="${1:?out dir}"; mkdir -p "$OUT"
[[ "$ROLE" == kit ]] && { echo "kits stay on the Alpine seed path" >&2; exit 1; }
FLATCAR_DIR="${FLATCAR_DIR:-$V2_DIR/node/flatcar}"
TEMPLATE="$FLATCAR_DIR/upstream/flatcar-corewaf.yaml.tftpl"
[[ -s "$TEMPLATE" ]] || { echo "missing prod template at $TEMPLATE" >&2; exit 1; }
"$V2_DIR/scripts/check-template-sync.sh" >/dev/null 2>&1 || echo "WARN: vendored template out of sync (scripts/check-template-sync.sh)" >&2

pubkey="$(<"$SSH_DIR/id_lab.pub")"
short="${NODE_FQDN%.$RIG_DOMAIN}"
NET_MODE="${RIG_NET_MODE:-router}"
if [[ "${RIG_BOOTSTRAP_RESOLVER:-}" == node ]]; then
    if [[ "$NET_MODE" == bridge ]]; then RIG_BOOTSTRAP_RESOLVER="${RIG_BOOTSTRAP_RESOLVER_BRIDGE:-1.1.1.1}"
    else RIG_BOOTSTRAP_RESOLVER="$AUX_IP"; fi
fi

# ---- vars.json for the PRODUCTION template (bridge-style ip/gw in both modes: they
# land only in the inert ens192 network file; the overlay owns the real network) ----
hosts_entries=""
for key in RIG_APP RIG_DNS_1 RIG_DNS_2 RIG_GW_1 RIG_GW_2 RIG_OBS_1; do
    ip_v="$(eval "echo \${${key}_IP:-}")"; fq_v="$(eval "echo \${${key}_FQDN:-}")"
    [[ -n "$ip_v" && -n "$fq_v" ]] || continue
    line="$ip_v $fq_v ${fq_v%.$RIG_DOMAIN}"
    # platform service aliases (the rig's static_hosts): CA/GUI live on app, obs UIs on obs
    case "$key" in
        RIG_APP)   line+="\n          $ip_v gui-1.$RIG_DOMAIN gui-1 stepca.$RIG_DOMAIN stepca" ;;
        RIG_OBS_1) line+="\n          $ip_v grafana.$RIG_DOMAIN grafana mimir.$RIG_DOMAIN mimir loki.$RIG_DOMAIN loki alertmanager.$RIG_DOMAIN alertmanager" ;;
    esac
    hosts_entries+="${hosts_entries:+\n          }$line"
done
jq -n \
  --arg hostname "$NODE_FQDN" \
  --arg ssh_public_key "$pubkey" \
  --arg hosts_entries "$(printf '%b' "$hosts_entries")" \
  --arg ip "$NODE_IP" \
  --arg gateway "${RIG_NET_HOST_GW:-192.168.150.1}" \
  --arg root_ca_cert "$(cat "$CA_DIR/root_ca.crt")" \
  --arg system_name "rig" --arg system_site "demo" \
  --arg domain_root "${RIG_DOMAIN#*.}" \
  --arg oci_registry "$(reg_host)" \
  '{hostname:$hostname, ssh_public_key:$ssh_public_key, hosts_entries:$hosts_entries,
    ip:$ip, prefix_length:24, gateway:$gateway, root_ca_cert:$root_ca_cert,
    data_disks:[], system_name:$system_name, system_site:$system_site,
    domain_root:$domain_root, oci_registry:$oci_registry}' > "$OUT/vars.json"

# ---- rig overlay Butane -----------------------------------------------------------
# DNS=/Domains= MUST live in [Network]; [Route] sections come after (networkd
# silently ignores DNS keys placed inside [Route] — cost us a debugging session).
DNSLINES=""; for ns in $RIG_RESOLVERS ${RIG_BOOTSTRAP_RESOLVER:-}; do DNSLINES+="          DNS=$ns"$'\n'; done
if [[ "$NET_MODE" == bridge ]]; then
    NETBLOCK="          [Network]
          Address=$NODE_IP/24
          Gateway=${RIG_NET_HOST_GW:-192.168.150.1}
$DNSLINES          Domains=$RIG_DOMAIN"
else
    NETBLOCK="          [Network]
          Address=$NODE_IP/32
$DNSLINES          Domains=$RIG_DOMAIN

          [Route]
          Destination=$AUX_IP/32
          Scope=link

          [Route]
          Gateway=$AUX_IP
          GatewayOnLink=yes"
fi
# ALWAYS the token form at provision time: the first docker-fetch happens before the
# credential helper exists (it is inside the fetched artifact). install-bootstrap.sh
# switches to the durable credHelpers form after installing the helper.
auth_json="$(cat "$AUTH_DIR/docker-config.json")"
aws_creds=""; [[ -s "$AUTH_DIR/aws-credentials" ]] && aws_creds="$(cat "$AUTH_DIR/aws-credentials")"
bootstrap="NODE_NAME=$short
FQDN=$NODE_FQDN
ZONE=$RIG_DOMAIN
NODE_IP=$NODE_IP"
# prod-shape system keys (orchestrator env root; mirrors the template-written
# NOTE acme_url: the rig writes the full ACME *directory* URL (step-ca on the app
# node); prod's template writes a base https://acme.<system>.<domain> — reconcile
# when a real acme. front exists. dns_upstream: public-DNS upstream for coredns.
# /etc/bootstrap + adds system_ns, which the template does not carry yet). The
# orchestrator wrapper mounts THIS file at /etc/bootstrap in its container, so
# bootstrap = system-wide data + per-VM identity, exactly the production model.
bootstrap+="
# --- prod-shape system keys (orchestrator env root) ---
system_name=rig
system_site=demo
system_ns=io.corewaf.ghcr/ext-corero/waf
domain=${RIG_DOMAIN#*.}
oci_registry=$(reg_host)
acme_url=https://$RIG_APP_FQDN:9000/acme/acme/directory
platform_api_url=http://$RIG_APP_FQDN:8080
stepca_url=https://$RIG_APP_FQDN:9000
dns_resolvers=$(echo $RIG_RESOLVERS | tr ' ' ',')
operator_cidrs=$RIG_NET_CIDR
# root CA cert PATH (guest-visible); a service manifest variable root_ca_cert overrides
root_ca_cert=/opt/rig-ca/root_ca.crt
dns_upstream=${RIG_DNS_UPSTREAM:-8.8.8.8}
# deployment plane: artifacts assembled BY/FOR this deployment (env assets;
# service bundles at Step 2) home here — sibling of system_ns (code images)
deployment_ns=io.corewaf.ghcr/deployments/rig-demo
release=0.0.1
# caps convenience keys, written VERBATIM by this generator (the orchestrator
# defines/renames nothing in code — the bootstrap file is the truth)
CS_DOMAIN=$RIG_DOMAIN
# platform data namespaces (tenant/etcd scoping)
namespace=corero-core
namespaces=[\"corero-core\",\"corero-system\"]"
if [[ -n "${RIG_HTTP_PORT:-}" ]]; then
    bootstrap+=$'\n'"RIG_HTTP_PORT=$RIG_HTTP_PORT"
    bootstrap+=$'\n'"PUBLIC_API_HOST=app-1.localhost:$RIG_HTTP_PORT"
else
    bootstrap+=$'\n'"PUBLIC_API_HOST=app-1.$RIG_DOMAIN:8080"
fi
if [[ "$ROLE" == gw ]]; then
    cidr="$(node_var IPAM_CIDR)"; addr="$(node_var WG_ADDR)"
    [[ -n "$cidr" ]] && bootstrap+=$'\n'"IPAM_CIDR=$cidr"
    [[ -n "$addr" ]] && bootstrap+=$'\n'"WG_ADDR=$addr"
fi
P9="trans=virtio,version=9p2000.L,cache=none,msize=512000"
ind() { sed "s/^/$(printf '%*s' "$1" '')/"; }

{
cat <<EOF
variant: flatcar
version: 1.0.0
storage:
  filesystems:
    # rig-provisioned docker volume (2nd virtio disk, serial=docker); the prod
    # template's var-lib-docker.mount + fix-docker-perms consume it unmodified
    - device: /dev/disk/by-id/virtio-docker
      format: ext4
      label: docker
      wipe_filesystem: false
  files:
    - path: /etc/systemd/network/05-rig.network
      mode: 0644
      contents:
        inline: |
          [Match]
          MACAddress=$NODE_MAC

          [Link]
          MTUBytes=${MTU:-1500}

$NETBLOCK
    - path: /etc/corewaf-bootstrap
      mode: 0644
      contents:
        inline: |
$(printf '%s\n' "$bootstrap" | ind 10)
    - path: /etc/modules-load.d/rig-9p.conf
      mode: 0644
      contents:
        inline: |
          9p
          9pnet_virtio
    - path: /root/.docker/config.json
      mode: 0600
      contents:
        inline: |
$(printf '%s\n' "$auth_json" | ind 10)
EOF
if [[ -n "$aws_creds" ]]; then
cat <<EOF
    - path: /root/.aws/credentials
      mode: 0600
      contents:
        inline: |
$(printf '%s\n' "$aws_creds" | ind 10)
EOF
fi
cat <<EOF
systemd:
  units:
    - name: opt-v2.mount
      enabled: true
      contents: |
        [Unit]
        Before=docker.service
        [Mount]
        What=v2cfg
        Where=/opt/v2
        Type=9p
        Options=$P9,ro
        [Install]
        WantedBy=multi-user.target
    - name: opt-shared\\x2dsecrets.mount
      enabled: true
      contents: |
        [Mount]
        What=secrets
        Where=/opt/shared-secrets
        Type=9p
        Options=$P9
        [Install]
        WantedBy=multi-user.target
    - name: opt-rig\\x2dca.mount
      enabled: true
      contents: |
        [Mount]
        What=rigca
        Where=/opt/rig-ca
        Type=9p
        Options=$P9,ro
        [Install]
        WantedBy=multi-user.target
    - name: opt-rig\\x2dstate.mount
      enabled: true
      contents: |
        [Mount]
        What=nodestate
        Where=/opt/rig-state
        Type=9p
        Options=$P9
        [Install]
        WantedBy=multi-user.target
EOF
if [[ "${RIG_MODE:-pull}" == source ]]; then
    WSMOUNT="${RIG_WORKSPACE_MOUNT:-/opt/corewaf-workspace}"
    WSUNIT="$(systemd-escape --path "$WSMOUNT" 2>/dev/null || echo "${WSMOUNT#/}" | sed 's|/|-|g')"
cat <<EOF
    - name: $WSUNIT.mount
      enabled: true
      contents: |
        [Mount]
        What=workspace
        Where=$WSMOUNT
        Type=9p
        Options=$P9,ro
        [Install]
        WantedBy=multi-user.target
EOF
fi
cat <<EOF
    # rig runs vm-stack over ssh; the prod compose-stacks flow arrives with the orchestrator
    - name: compose-stacks.service
      mask: true
    # demo determinism: OS generation is pinned by the OCI image (A/B stays possible per env)
    - name: update-engine.service
      mask: true
    - name: locksmithd.service
      mask: true
    # rig disk is provisioned by Ignition above; the vSphere SCSI walk finds nothing on q35
    - name: provision-volumes.service
      dropins:
        - name: 10-rig-noop.conf
          contents: |
            [Service]
            ExecStart=
            ExecStart=/usr/bin/true
    # bootstrap artifacts ref for the shared install-bootstrap.sh docker-fetch branch
    - name: install-bootstrap.service
      dropins:
        - name: 10-rig-ref.conf
          contents: |
            [Service]
            Environment=BOOTSTRAP_ARTIFACTS_REF=${RIG_BOOTSTRAP_ARTIFACTS_REF:-}
    # ECR pull trust: the prod template pins certs.d to the corewaf CA; the rig registry
    # is ECR with public TLS — point certs.d at the full system bundle instead
    - name: rig-registry-ca-fix.service
      enabled: true
      contents: |
        [Unit]
        Description=Use system CA bundle for the rig registry
        After=update-ca-certificates.service
        Before=docker.service
        [Service]
        Type=oneshot
        RemainAfterExit=true
        ExecStart=/bin/sh -c 'cp /etc/ssl/certs/ca-certificates.crt "/etc/docker/certs.d/$(reg_host)/ca.crt"'
        [Install]
        WantedBy=multi-user.target
    - name: serial-getty@ttyS1.service
      enabled: true
      dropins:
        - name: 10-autologin.conf
          contents: |
            [Service]
            ExecStart=
            ExecStart=-/sbin/agetty --autologin core --keep-baud 115200,57600,38400,9600 %I \$TERM
EOF
} > "$OUT/overlay.bu"

# ---- render (production toolchain, offline provider mirror) -----------------------
RD="$OUT/render"; rm -rf "$RD"; mkdir -p "$RD"
cp "$FLATCAR_DIR/render/main.tf" "$FLATCAR_DIR/render/versions.tf" "$RD/"
( cd "$RD"
  terraform init -input=false -no-color >/dev/null
  TF_VAR_template_path="$TEMPLATE" \
  TF_VAR_vars_json="$(cat "$OUT/vars.json")" \
  TF_VAR_overlay_butane="$(cat "$OUT/overlay.bu")" \
  terraform apply -input=false -auto-approve -no-color >/dev/null
  terraform output -raw prod_ignition    > "$OUT/prod.ign"
  terraform output -raw overlay_ignition > "$OUT/overlay.ign"
)
A="$(base64 -w0 "$OUT/prod.ign")"; B="$(base64 -w0 "$OUT/overlay.ign")"
NEW="$OUT/config.json"
jq -n --arg a "$A" --arg b "$B" \
  '{ignition:{version:"3.3.0",config:{merge:[{source:("data:;base64,"+$a)},{source:("data:;base64,"+$b)}]}}}' > "$NEW.tmp"
if [[ -s "$NEW" ]] && ! cmp -s "$NEW" "$NEW.tmp"; then
    echo "NOTE: Ignition config changed — existing guests need: vm-ssh 'sudo /reprovision' + reboot" >&2
fi
mv "$NEW.tmp" "$NEW"
echo "$NEW"
