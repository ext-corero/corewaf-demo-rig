# rig-launcher — zero-install entry point: drives the demo rig from a container.
#   docker run --rm -it -v /var/run/docker.sock:/var/run/docker.sock \
#     -v ~/.aws:/root/.aws:ro -e AWS_PROFILE=corewaf-ecr \
#     <ECR>/io.corewaf.ghcr/rig/launcher up
# The rig checkout lives in a named volume (corewaf-demo-rig_repo); compose runs
# here against the host daemon; everything else is the same rig as the curl path.
FROM alpine:3.23
RUN apk add --no-cache docker-cli docker-cli-compose git bash curl jq openssl ca-certificates
ARG ECR_HELPER_VER=0.9.1
RUN curl -fsSL -o /usr/local/bin/docker-credential-ecr-login \
      "https://amazon-ecr-credential-helper-releases.s3.us-east-2.amazonaws.com/${ECR_HELPER_VER}/linux-amd64/docker-credential-ecr-login" \
 && chmod +x /usr/local/bin/docker-credential-ecr-login
COPY launcher.sh /usr/local/bin/rig-launcher
RUN chmod +x /usr/local/bin/rig-launcher
ENTRYPOINT ["/usr/local/bin/rig-launcher"]
CMD ["help"]
