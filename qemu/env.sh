# qemu/env.sh — shared environment for the pure-QEMU (Model 3) runner.
# Points the shared node/bin scripts at a host-local tree under <repo>/.qemu.
QROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QDIR="$QROOT/.qemu"
export V2_DIR="$QROOT" RIG_LIB="$QROOT/node/bin/rig-lib.sh"
export BASE_DIR="$QDIR/base" CA_DIR="$QDIR/ca" SECRETS_DIR="$QDIR/shared-secrets" \
       AUTH_DIR="$QDIR/auth" SSH_DIR="$QDIR/ssh" RIG_NET_MODE=bridge KITSHIM="$QROOT/kit-shim"
export PATH="$QROOT/node/bin:$HOME/.local/bin:$PATH"
export RIG_OS="${RIG_OS:-flatcar}"
[[ -f "$HOME/.local/share/terraform/rig.tfrc" ]] && export TF_CLI_CONFIG_FILE="$HOME/.local/share/terraform/rig.tfrc"
mkdir -p "$QDIR"/{base,ca,shared-secrets,auth,ssh,state,run,log}
set -a; source "$QROOT/inventory.env"; source "$QROOT/images.env"; set +a
export RAM_MB VCPUS 2>/dev/null || true
