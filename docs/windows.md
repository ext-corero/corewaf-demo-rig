# Running the demo rig on Windows (Docker Desktop)

1. Windows 11, Docker Desktop with the **WSL2 backend**.
2. Nested virtualization for WSL2 — `%UserProfile%\.wslconfig`:
   ```
   [wsl2]
   nestedVirtualization=true
   memory=24GB
   ```
   then `wsl --shutdown` and restart Docker Desktop. The rig boots six VMs (≈16 GB of guest RAM by default; tune `RIG_*_RAM_MB` in `.env`).
3. From a WSL shell (or Git Bash):
   ```
   AWS_PROFILE=corewaf-ecr bash <(curl -fsSL https://raw.githubusercontent.com/ext-corero/corewaf-demo-rig/main/bootstrap.sh)
   ```
4. Windows cannot reach the container IPs; use the published ports. Hosts file
   (`C:\Windows\System32\drivers\etc\hosts`, run `scripts/hosts-block.sh` for the exact lines):
   `127.0.0.1 gui-1.rig.internal app-1.rig.internal grafana.rig.internal` → GUI at
   http://gui-1.rig.internal:8080, Grafana at http://grafana.rig.internal:3000.
5. Everything that must reach the VMs runs inside the rig network:
   `docker compose --profile tools run --rm cli rig verify`, `task demo:*`, `task ssh NODE=app-1`.

Validated 2026-08-29 on a Windows 11 / Docker Desktop (WSL2, Ubuntu 24.04) host with 24 cores / 32 GB: six VMs healthy in ~11 min on first run, kit enrolment OK.

6. Non-interactive WSL shells (ssh in): `docker-credential-desktop.exe` is not on PATH →
   `export DOCKER_CONFIG=$HOME/.docker-rig; mkdir -p $DOCKER_CONFIG; echo "{}" > $DOCKER_CONFIG/config.json` before the bootstrap.
7. Ports 3000 (and sometimes 3030) are often taken on Windows hosts; the bootstrap picks the next free port and writes `RIG_GRAFANA_PORT` to `.env`.

Known: Docker Desktop file sharing must include the checkout; keep the repo on the WSL
filesystem for speed; `.gitattributes` forces LF so scripts served to the guests stay valid.
