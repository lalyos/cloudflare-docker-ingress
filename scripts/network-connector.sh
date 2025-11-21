#!/bin/bash

# Network Connector Script
# Connects cloudflared container to all Docker bridge networks

NETWORKS_FILE="/config/networks.txt"
CLOUDFLARED_CONTAINER="${CLOUDFLARED_CONTAINER:-cloudflared}"
LOG_PREFIX="[network-connector]"

log() {
    echo "$LOG_PREFIX $1" >&2
}

error() {
    echo "$LOG_PREFIX ERROR: $1" >&2
}

# Check if cloudflared container exists
if ! docker inspect "$CLOUDFLARED_CONTAINER" &>/dev/null; then
    log "Cloudflared container '$CLOUDFLARED_CONTAINER' not found, skipping"
    exit 0
fi

# Get current networks cloudflared is connected to
current_networks=$(docker inspect "$CLOUDFLARED_CONTAINER" --format '{{range $net, $_ := .NetworkSettings.Networks}}{{$net}} {{end}}')

# Read desired networks from file
if [ ! -f "$NETWORKS_FILE" ]; then
    log "Networks file not found: $NETWORKS_FILE"
    exit 0
fi

# Connect to new networks
while IFS= read -r network; do
    # Skip empty lines
    [ -z "$network" ] && continue

    # Check if already connected
    if echo "$current_networks" | grep -q "$network"; then
        log "Already connected to: $network"
    else
        log "Connecting to network: $network"
        if docker network connect "$network" "$CLOUDFLARED_CONTAINER" 2>/dev/null; then
            log "Successfully connected to: $network"
        else
            error "Failed to connect to: $network"
        fi
    fi
done < "$NETWORKS_FILE"

log "Network connection check completed"
