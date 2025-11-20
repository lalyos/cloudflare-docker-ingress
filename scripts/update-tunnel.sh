#!/bin/bash
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -e

# Cloudflare Tunnel Update Script
# Automatically manages Cloudflare Tunnel routes based on Docker containers

CONFIG_FILE="/config/tunnel-config.json"
STATE_FILE="/config/tunnel-state.json"
LOG_PREFIX="[ctm]"

# Required environment variables
: "${CLOUDFLARE_API_TOKEN:?Environment variable CLOUDFLARE_API_TOKEN is required}"
: "${CLOUDFLARE_TUNNEL_ID:?Environment variable CLOUDFLARE_TUNNEL_ID is required}"
: "${CLOUDFLARE_ZONE_ID:?Environment variable CLOUDFLARE_ZONE_ID is required}"
: "${CLOUDFLARE_ACCOUNT_ID:?Environment variable CLOUDFLARE_ACCOUNT_ID is required}"

API_BASE="https://api.cloudflare.com/client/v4"

log() {
    echo "$LOG_PREFIX $1" >&2
}

error() {
    echo "$LOG_PREFIX ERROR: $1" >&2
}

# Make API call to Cloudflare
cf_api() {
    local method="$1"
    local endpoint="$2"
    local data="$3"

    local curl_args=(
        -X "$method"
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"
        -H "Content-Type: application/json"
        -s
    )

    if [ -n "$data" ]; then
        curl_args+=(-d "$data")
    fi

    curl "${curl_args[@]}" "${API_BASE}${endpoint}"
}


# Create or update DNS record
upsert_dns_record() {
    local zone_id="$1"
    local hostname="$2"
    local tunnel_id="$3"

    log "Upserting DNS record for: $hostname"

    # Check if record exists
    local response
    response=$(cf_api GET "/zones/$zone_id/dns_records?name=$hostname")

    local record_id
    record_id=$(echo "$response" | jq -r '.result[0].id // empty')

    local dns_data
    dns_data=$(cat <<EOF
{
  "type": "CNAME",
  "name": "$hostname",
  "content": "$tunnel_id.cfargotunnel.com",
  "ttl": 1,
  "proxied": true
}
EOF
)

    if [ -n "$record_id" ]; then
        log "Updating existing DNS record: $record_id"
        cf_api PUT "/zones/$zone_id/dns_records/$record_id" "$dns_data" > /dev/null
    else
        log "Creating new DNS record"
        cf_api POST "/zones/$zone_id/dns_records" "$dns_data" > /dev/null
    fi
}

# Delete DNS record
delete_dns_record() {
    local zone_id="$1"
    local hostname="$2"

    log "Deleting DNS record for: $hostname"

    local response
    response=$(cf_api GET "/zones/$zone_id/dns_records?name=$hostname")

    local record_id
    record_id=$(echo "$response" | jq -r '.result[0].id // empty')

    if [ -n "$record_id" ]; then
        cf_api DELETE "/zones/$zone_id/dns_records/$record_id" > /dev/null
        log "Deleted DNS record: $hostname"
    fi
}

# Main execution
main() {
    log "Starting tunnel update process"

    # Check if config file exists and is valid
    if [ ! -f "$CONFIG_FILE" ]; then
        log "No config file found, skipping update"
        return 0
    fi

    # Validate JSON
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        error "Invalid JSON in config file"
        return 1
    fi

    # Get current containers
    local current_containers
    current_containers=$(jq -c '.' "$CONFIG_FILE")

    # Use tunnel ID from environment
    local tunnel_id="$CLOUDFLARE_TUNNEL_ID"
    log "Using tunnel ID: $tunnel_id"

    # Build tunnel configuration
    local ingress_rules="[]"
    local container_count
    container_count=$(echo "$current_containers" | jq 'length')

    log "Processing $container_count containers"

    # Create ingress rules for each container
    for i in $(seq 0 $((container_count - 1))); do
        local container
        container=$(echo "$current_containers" | jq -r ".[$i]")

        local hostname
        hostname=$(echo "$container" | jq -r '.hostname')

        local service
        service=$(echo "$container" | jq -r '.service')

        log "Adding route: $hostname -> $service"

        ingress_rules=$(echo "$ingress_rules" | jq ". += [{\"hostname\": \"$hostname\", \"service\": \"$service\"}]")

        # Update DNS record
        upsert_dns_record "$CLOUDFLARE_ZONE_ID" "$hostname" "$tunnel_id"
    done

    # Add catch-all rule (required by Cloudflare)
    ingress_rules=$(echo "$ingress_rules" | jq '. += [{"service": "http_status:404"}]')

    # Push configuration to Cloudflare API (remote-managed tunnel)
    log "Pushing tunnel configuration to Cloudflare API"
    local config_payload
    config_payload=$(jq -n --argjson ingress "$ingress_rules" '{
        "config": {
            "ingress": $ingress
        }
    }')

    local config_response
    config_response=$(cf_api PUT "/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel/$tunnel_id/configurations" "$config_payload")

    if ! echo "$config_response" | jq -e '.success' > /dev/null 2>&1; then
        error "Failed to update tunnel configuration"
        error "Response: $config_response"
        return 1
    fi

    log "Tunnel configuration pushed to Cloudflare API successfully"

    # Handle removed containers (compare with previous state)
    if [ -f "$STATE_FILE" ]; then
        local previous_hostnames
        previous_hostnames=$(jq -r '.[].hostname' "$STATE_FILE" 2>/dev/null || echo "")

        local current_hostnames
        current_hostnames=$(echo "$current_containers" | jq -r '.[].hostname')

        # Find removed hostnames
        while IFS= read -r hostname; do
            if [ -n "$hostname" ] && ! echo "$current_hostnames" | grep -q "^$hostname$"; then
                log "Container removed, cleaning up: $hostname"
                delete_dns_record "$CLOUDFLARE_ZONE_ID" "$hostname"
            fi
        done <<< "$previous_hostnames"
    fi

    # Save current state
    echo "$current_containers" > "$STATE_FILE"

    log "Tunnel update completed successfully"
    log "Tunnel ID: $tunnel_id"
    log "Active routes: $container_count"
}

# Run main function
main "$@"
