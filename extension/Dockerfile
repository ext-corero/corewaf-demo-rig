# corewaf-demo-rig Docker Desktop extension.
# UI (React/MUI) + per-OS host helper that runs the rig-launcher container.
# No backend service: the launcher IS the backend (same rig as the curl path).

FROM --platform=$BUILDPLATFORM node:22-alpine AS ui
WORKDIR /ui
COPY ui/package.json ui/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY ui/ .
ARG CHANNEL=latest
ENV VITE_LAUNCHER_TAG=$CHANNEL
RUN npm run build

FROM --platform=$BUILDPLATFORM golang:1.23-alpine AS host
WORKDIR /src
COPY host/ .
RUN CGO_ENABLED=0 GOOS=linux   GOARCH=amd64 go build -ldflags="-s -w" -o /out/linux/corewaf-rig . \
 && CGO_ENABLED=0 GOOS=darwin  GOARCH=arm64 go build -ldflags="-s -w" -o /out/darwin/corewaf-rig . \
 && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -ldflags="-s -w" -o /out/windows/corewaf-rig.exe .

FROM alpine:3.23
ARG VERSION=dev
LABEL org.opencontainers.image.title="Corero WAAP Demo Rig" \
      org.opencontainers.image.description="Boot the Corero WAAP demo rig (six KVM VMs in containers + demo kits) from Docker Desktop." \
      org.opencontainers.image.vendor="Corero" \
      org.opencontainers.image.source="https://github.com/ext-corero/corewaf-demo-rig" \
      org.opencontainers.image.version="${VERSION}" \
      com.docker.desktop.extension.api.version=">= 0.3.4" \
      com.docker.desktop.extension.icon="https://raw.githubusercontent.com/ext-corero/corewaf-demo-rig/main/extension/icon.svg" \
      com.docker.extension.categories="utility-tools" \
      com.docker.extension.detailed-description="One-click Up / Verify / Enrol kit / Stop / Down / Reset for the Corero WAAP demo rig. Requires KVM exposed to containers (Windows: WSL2 nested virtualization) and an AWS profile with the Corero WAAP ECR pull policy." \
      com.docker.extension.publisher-url="https://github.com/ext-corero/corewaf-demo-rig" \
      com.docker.extension.additional-urls='[{"title":"README","url":"https://github.com/ext-corero/corewaf-demo-rig#readme"}]' \
      com.docker.extension.changelog="See GitHub releases." \
      com.docker.extension.screenshots='[]'
COPY metadata.json icon.svg /
COPY --from=ui /ui/build /ui
COPY --from=host /out/linux /linux
COPY --from=host /out/darwin /darwin
COPY --from=host /out/windows /windows
