FROM nginxproxy/docker-gen:latest

# Install required dependencies for the update script
RUN apk add --no-cache \
    bash \
    curl \
    jq \
    openssl

# Set bash as the default shell for scripts
ENV SHELL=/bin/bash
