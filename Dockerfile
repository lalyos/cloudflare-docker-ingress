FROM nginxproxy/docker-gen:latest

LABEL org.opencontainers.image.title="Cloudflare Docker Ingress" \
      org.opencontainers.image.description="Automatic Cloudflare Tunnel ingress controller for Docker containers" \
      org.opencontainers.image.url="https://github.com/lalyos/cloudflare-docker-ingress" \
      org.opencontainers.image.source="https://github.com/lalyos/cloudflare-docker-ingress" \
      org.opencontainers.image.vendor="lalyos"

# Install required dependencies for the update script
RUN apk add --no-cache \
    bash \
    curl \
    jq \
    openssl \
    cmd:docker

# Set bash as the default shell for scripts
ENV SHELL=/bin/bash
