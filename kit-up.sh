#!/usr/bin/env bash
# kit-up.sh [name] — same as kit.sh (kept for the runbook).
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kit.sh" "$@"
