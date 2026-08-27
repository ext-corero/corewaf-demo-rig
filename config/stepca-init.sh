#!/bin/sh
# step-ca init for the v2 rig — chain to the PRE-CREATED rig root CA.
#
# Unlike the single-host rig (DOCKER_STEPCA_INIT_* self-signs a fresh root
# each time), here we hand step-ca our stable root (mapped read-only at
# /rigca) so it mints an INTERMEDIATE under it. Every VM already trusts that
# root (baked into the trust store at boot), so leaf certs validate with no
# per-bringup root churn.
#
# Idempotent: if ca.json already exists in the (persistent) step home, skip.
set -e
export STEPPATH=/home/step
PW="${STEPCA_PASSWORD:?STEPCA_PASSWORD not set}"

if [ -f "$STEPPATH/config/ca.json" ]; then
  echo "step-ca already initialized at $STEPPATH"
  exit 0
fi

echo "$PW" > /tmp/pw
chmod 600 /tmp/pw

# --root/--key: use the existing rig root; step generates an intermediate
# signed by it. --remote-management enables the admin API the bootstrap
# (provisioner registration) uses, matching the single-host rig.
step ca init \
  --deployment-type=standalone \
  --name="CoreWAF Rig CA" \
  --dns="stepca,localhost,127.0.0.1,app-1.rig.internal,stepca.rig.internal" \
  --address=":9000" \
  --provisioner="admin" \
  --password-file=/tmp/pw \
  --provisioner-password-file=/tmp/pw \
  --root=/rigca/root_ca.crt \
  --key=/rigca/root_ca_key \
  --remote-management

# The step-ca SERVER reads its key password from $STEPPATH/secrets/password
# (the image entrypoint's default --password-file). step ca init encrypts the
# intermediate key with PW but doesn't persist the password — write it so the
# server can start unattended.
mkdir -p "$STEPPATH/secrets"
printf '%s' "$PW" > "$STEPPATH/secrets/password"
chmod 600 "$STEPPATH/secrets/password"

# init ran as root; the step-ca SERVER runs as the unprivileged `step` user
# (uid/gid 1000 in the smallstep image) and must own the home to read it.
chown -R 1000:1000 "$STEPPATH"

rm -f /tmp/pw
echo "step-ca initialized (intermediate under the rig root)"
