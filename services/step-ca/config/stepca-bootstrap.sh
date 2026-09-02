#!/bin/sh
# stepca-bootstrap.sh — register the tunnel-gateway-service JWK provisioner
# and export its credentials to the shared tunnel-gw-secrets volume.
#
# Run as a one-shot init container with the smallstep/step-cli image.
# Idempotent: re-running on an already-bootstrapped CA is a no-op
# (provisioner is detected and skipped, secrets volume is already
# populated, sentinel file is already in place).
#
# Mounts expected:
#   - tunnel-gw-secrets at /secrets/tunnel-gw      (rw — output)
#
# Env expected:
#   STEPCA_URL                    https://stepca:9000
#   STEPCA_ADMIN_PASSWORD         password for the CA admin provisioner
#   STEPCA_PROVISIONER_PASSWORD   password to encrypt the new JWK
#   STEPPATH                      writable scratch dir for step CLI config

set -eu

: "${STEPCA_URL:?STEPCA_URL not set}"
: "${STEPCA_ADMIN_PASSWORD:?STEPCA_ADMIN_PASSWORD not set}"
: "${STEPCA_PROVISIONER_PASSWORD:?STEPCA_PROVISIONER_PASSWORD not set}"
: "${STEPPATH:=/tmp/step}"
export STEPPATH
mkdir -p "$STEPPATH"

: "${OUT_DIR:?OUT_DIR not set}"
mkdir -p "$OUT_DIR"

# NO sentinel short-circuit. The CA's data is in an ephemeral volume that a
# reset (down -v / fresh VM) wipes, while $OUT_DIR is on the persistent shared
# host dir — a sentinel here would survive a CA wipe and make us SKIP
# re-registering the ACME + tunnel-gateway provisioners against the FRESH CA
# (which silently broke the edge's ACME). Every step below is idempotent:
# it checks the CA's actual provisioner state and creates only what's missing,
# so re-running against an existing OR freshly-wiped CA is always correct.

# 1. Wait for step-ca to be reachable + healthy.
echo "stepca-bootstrap: waiting for $STEPCA_URL ..."
attempt=0
until curl -sfk "$STEPCA_URL/health" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 60 ]; then
        echo "stepca-bootstrap: step-ca did not become healthy in time" >&2
        exit 1
    fi
    sleep 1
done
echo "stepca-bootstrap: step-ca is healthy"

# 2. Pull the root cert and compute its fingerprint (binds the OTT to
#    a specific CA so a leaked provisioner key can't be replayed
#    against a different CA — sha claim).
ROOT_PEM="/tmp/root.crt"
curl -sk "$STEPCA_URL/roots.pem" > "$ROOT_PEM"
ROOT_FP="$(step certificate fingerprint "$ROOT_PEM")"
echo "stepca-bootstrap: root fingerprint $ROOT_FP"

# 3. Bootstrap the step CLI's local trust + CA URL config (~/.step).
step ca bootstrap \
    --ca-url "$STEPCA_URL" \
    --fingerprint "$ROOT_FP" \
    --force

# 4. Idempotent provisioner add — if it already exists, skip create.
if step ca provisioner list 2>/dev/null \
        | grep -F '"name": "tunnel-gateway-service"' >/dev/null
then
    echo "stepca-bootstrap: provisioner already exists; reusing"
else
    echo "stepca-bootstrap: creating tunnel-gateway-service provisioner"
    printf '%s' "$STEPCA_ADMIN_PASSWORD" > /tmp/admin-pwd
    printf '%s' "$STEPCA_PROVISIONER_PASSWORD" > /tmp/jwk-pwd
    chmod 600 /tmp/admin-pwd /tmp/jwk-pwd

    # smallstep/step-ca's docker auto-init (DOCKER_STEPCA_INIT_*) creates
    # a super-admin with subject ``step`` against the admin JWK
    # provisioner — so that's what we use to authenticate this call.
    step ca provisioner add tunnel-gateway-service \
        --type JWK --create \
        --admin-subject step --admin-provisioner admin \
        --admin-password-file /tmp/admin-pwd \
        --password-file /tmp/jwk-pwd

    rm -f /tmp/admin-pwd /tmp/jwk-pwd
fi

# 5. Extract the encrypted private JWK from `step ca provisioner list`.
#    With REMOTE_MANAGEMENT=true step-ca stores provisioners in its admin DB
#    (not ca.json), so the canonical readable source is the listing API.
#    The list response is a JSON array; each entry has ``encryptedKey``.
ENCRYPTED_KEY="$(
    step ca provisioner list 2>/dev/null \
        | awk '
            /"name": "tunnel-gateway-service"/ { found=1 }
            found && /"encryptedKey":/ {
                sub(/.*"encryptedKey":[[:space:]]*"/, "")
                sub(/".*/, "")
                print
                exit
            }
        '
)"

if [ -z "$ENCRYPTED_KEY" ]; then
    echo "stepca-bootstrap: FATAL — could not extract encryptedKey from provisioner list" >&2
    exit 1
fi

# 6. Write artifacts to the shared volume.
printf '%s' "$ENCRYPTED_KEY" > "$OUT_DIR/provisioner.jwk"
printf '%s' "$STEPCA_PROVISIONER_PASSWORD" > "$OUT_DIR/provisioner.password"
printf '%s' "$ROOT_FP" > "$OUT_DIR/root.fingerprint"
cp "$ROOT_PEM" "$OUT_DIR/root.crt"
chmod 600 "$OUT_DIR/provisioner.jwk" "$OUT_DIR/provisioner.password"
chmod 644 "$OUT_DIR/root.fingerprint" "$OUT_DIR/root.crt"

# 7. Idempotent ACME provisioner add. The tunnel-caddy-edge sidecar
#    mints its own server cert via ACME from this stepca, which is the
#    production-realistic shape the rig should exercise. Default
#    challenges (HTTP-01 + TLS-ALPN-01) are fine on the docker-internal
#    tunnel-edge network — stepca dials the challenge over the same
#    network we run on.
if step ca provisioner list 2>/dev/null \
        | grep -F '"name": "acme"' >/dev/null
then
    echo "stepca-bootstrap: ACME provisioner already exists; reusing"
else
    echo "stepca-bootstrap: creating ACME provisioner"
    printf '%s' "$STEPCA_ADMIN_PASSWORD" > /tmp/admin-pwd
    chmod 600 /tmp/admin-pwd

    step ca provisioner add acme --type ACME \
        --admin-subject step --admin-provisioner admin \
        --admin-password-file /tmp/admin-pwd

    rm -f /tmp/admin-pwd
fi

# NOTE: this script does NOT mint the gateway's bridges-internal cert.
# That cert is per-gateway (SAN ``*.<gateway_id>.bridges.internal``) and the
# app VM has no business guessing a gateway's identity — host-as-truth means
# each gateway mints its own from its own NODE_NAME (tracked: gateway-side
# bridge-cert mint, task #90). The app VM only seeds the SHARED provisioner +
# root that every gateway uses to do that minting.

echo "stepca-bootstrap: complete; secrets at $OUT_DIR"
