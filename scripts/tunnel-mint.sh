#!/usr/bin/env bash
# tunnel-mint — create a tunnel-enabled provisioning package + token.
#
# Idempotent:
#   - the "tunnel-default" package is created on first run, reused after
#   - each invocation mints a new token (uuid-fresh)
#
# Output: the envelope to stuff into a kit's config.ini.

set -euo pipefail

NS="${NS:-corero-core}"
# v3 ownership-model: elevated tenants (kind=system-owner / kind=carrier)
# are barred from minting provisioning tokens directly — production
# routes reject with 403. The canonical minter is the per-elevated
# kit-manager service identity, bearing kit_manager_role. CARRIER name
# kept for shell-script back-compat; what it really points at now is
# the kit-manager that does the minting.
CARRIER="${CARRIER:-corero-system-owner-kit-manager}"
# Identity used only for the cross-tenant tenant-listing fallback below
# (kit_manager_role doesn't have ``tenant/*`` read; the system terminus
# does). Not used for the mint itself.
LISTER="${LISTER:-corero-system-owner}"
PKG_NAME="${PKG_NAME:-tunnel-default}"
RIG_HTTP_PORT="${RIG_HTTP_PORT:-28080}"
LABEL="${1:-rig-demo-$(date +%s)}"

# Platform-API ingress base. Single-host rig: corewaf.localhost. v2 multi-VM
# rig: override RIG_API_BASE=http://app-1.rig.internal:8080 (resolvable via
# the dns VMs / a hosts entry). /provisioning + /tenants are path-prefix
# routed to the waf-api service modules behind it.
BASE_URL="${RIG_API_BASE:-http://corewaf.localhost:${RIG_HTTP_PORT}}"
API="${BASE_URL}/provisioning/api/v1"
# The apiEndpoint baked into the package — where the enrolled kit reaches the
# platform API (post-tunnel). SLIRP default for the single-host rig; v2 sets
# PKG_API_ENDPOINT=http://app-1.rig.internal:8080.
PKG_API_ENDPOINT="${PKG_API_ENDPOINT:-http://10.0.2.2:8080}"

log() { printf '%s tunnel-mint %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# ── 0. Resolve a tenant ──────────────────────────────────────────────
# Per tenant-v2 §3.2 ProvisioningPackage + Token both require tenantRef.
# Default to whatever's first in the namespace (`task seed` populates
# this with att-com-fabrikam etc.); override via TENANT=<name>.
if [ -z "${TENANT:-}" ]; then
    # Pick the first kind=tenant record (not a service identity, not a
    # carrier). The listing response wraps each record under .tenant,
    # so we filter by spec.kind in jq.
    TENANT="$(curl -sS -H "X-Scope-OrgID: ${LISTER}" \
        "${BASE_URL}/tenants/api/v1/namespaces/${NS}/tenants" \
        | jq -r '[.[] | .tenant | select(.spec.kind == "tenant")][0].metadata.name // empty' \
            2>/dev/null || true)"
fi
if [ -z "${TENANT:-}" ]; then
    echo "tunnel-mint: no tenants in ${NS} — run 'task seed' first or set TENANT=<name>" >&2
    exit 1
fi
log "using tenantRef=${TENANT}"

# ── 1. Ensure the package exists ─────────────────────────────────────
log "ensuring ProvisioningPackage '${PKG_NAME}' in namespace ${NS}"

# The package describes what a redeemed token produces. For a tunnel
# enrollment it sets BOTH issuesZeroTrustKey AND issuesTunnelConfig.
# The POST body is just the spec; package name is in the URL.
PKG_SPEC=$(jq -nc --arg tenant "$TENANT" --arg apiep "$PKG_API_ENDPOINT" \
    '{
        tenantRef:          $tenant,
        apiEndpoint:        $apiep,
        lokiEndpoint:       "http://loki.tunnel.corewaf.local:3100",
        mimirEndpoint:      "http://mimir.tunnel.corewaf.local:9009",
        serviceEndpoints:   {},
        issuesZeroTrustKey: true,
        issuesTunnelConfig: true,
        extras:             {}
    }')

# Create-if-not-exists: 201 on first run, 409 on rerun (already exists).
# kit_manager_role only has read+list on provisioning_package — packages
# are admin-curated templates. Use the system-owner identity (bears
# system_admin) for the create step; the actual mint below uses CARRIER
# (kit-manager) as v3 requires.
status=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "${API}/namespaces/${NS}/provisioning-packages/${PKG_NAME}" \
    -H 'Content-Type: application/json' \
    -H "X-Scope-OrgID: ${LISTER}" \
    -d "$PKG_SPEC")

case "$status" in
    201) log "package created" ;;
    409) log "package already exists" ;;
    *)   log "WARNING: package create returned HTTP $status (continuing)" ;;
esac

# ── 2. Mint a token referencing the package ──────────────────────────
log "minting token (label=${LABEL})"
TOKEN_BODY=$(jq -nc --arg pkg "$PKG_NAME" --arg label "$LABEL" --arg tenant "$TENANT" \
    '{packageName: $pkg, label: $label, tenantRef: $tenant, criteria: {}}')

mint_resp=$(curl -sS \
    -X POST "${API}/namespaces/${NS}/provisioning-tokens" \
    -H 'Content-Type: application/json' \
    -H "X-Scope-OrgID: ${CARRIER}" \
    -d "$TOKEN_BODY")

token_id=$(echo "$mint_resp" | jq -r .tokenId)
envelope=$(echo "$mint_resp" | jq -r .token)
expires=$(echo "$mint_resp" | jq -r .expiresAt)

if [ -z "$envelope" ] || [ "$envelope" = "null" ]; then
    echo "FAIL: mint did not return an envelope. Response was:" >&2
    echo "$mint_resp" >&2
    exit 1
fi

log "minted token ${token_id}, expires ${expires}"

# ── 3. Print kit-ready snippet ───────────────────────────────────────
cat <<EOF

────────────────────────── kit config.ini snippet ──────────────────────────

provisioning_token=${envelope}
instance_comment=${LABEL}

────────────────────────────────────────────────────────────────────────────

(Token is single-use. Hand to a kit operator out-of-band.)
EOF
