#!/usr/bin/env bash
# check-template-sync — the vendored production Butane template must stay byte-identical
# to the authoritative copies. Checksum-enforced (RIG_PROD_TEMPLATE_SHA256 in images.env);
# also diffs against sibling checkouts when they are visible on this machine.
#   exit 0 = in sync; exit 1 = drift. CI fails on drift; ignite.sh warns.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VENDORED="$HERE/node/flatcar/upstream/flatcar-corewaf.yaml.tftpl"
PIN="$(sed -n 's/^RIG_PROD_TEMPLATE_SHA256=//p' "$HERE/images.env")"

rc=0
have="$(sha256sum "$VENDORED" | cut -d' ' -f1)"
if [[ -n "$PIN" && "$have" != "$PIN" ]]; then
    echo "DRIFT: vendored template sha256 $have != pinned $PIN" >&2; rc=1
fi
for sib in "$HERE/../../corewaf-tp-demo/flatcar-corewaf.yaml.tftpl" \
           "$HERE/../init/env-template/flatcar-corewaf.yaml.tftpl"; do
    [[ -f "$sib" ]] || continue
    cmp -s "$VENDORED" "$sib" || { echo "DRIFT: vendored template differs from $sib" >&2; rc=1; }
done
[[ $rc -eq 0 ]] && echo "template in sync ($have)"
exit $rc
