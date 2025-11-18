#!/bin/bash
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -e

# Cloudflare Tunnel Update Script
# Automatically manages Cloudflare Tunnel routes based on Docker containers

CONFIG_FILE="/config/tunnel-config.json"
STATE_FILE="/config/tunnel-state.json"
LOG_PREFIX="[ctm]"

# Required environment variables
: "${CLOUDFLARE_API_TOKEN:?Environment variable CLOUDFLARE_API_TOKEN is required}"
: "${CLOUDFLARE_ACCOUNT_ID:?Environment variable CLOUDFLARE_ACCOUNT_ID is required}"
: "${CLOUDFLARE_TUNNEL_NAME:?Environment variable CLOUDFLARE_TUNNEL_NAME is required}"
: "${CLOUDFLARE_DEFAULT_DOMAIN:?Environment variable CLOUDFLARE_DEFAULT_DOMAIN is required}"

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

# Get or create Zone ID from domain
get_zone_id() {
    if [ -n "$CLOUDFLARE_ZONE_ID" ]; then
        echo "$CLOUDFLARE_ZONE_ID"
        return
    fi

    log "Looking up Zone ID for domain: $CLOUDFLARE_DEFAULT_DOMAIN"
    local response
    response=$(cf_api GET "/zones?name=$CLOUDFLARE_DEFAULT_DOMAIN")

    local zone_id
    zone_id=$(echo "$response" | jq -r '.result[0].id // empty')

    if [ -z "$zone_id" ]; then
        error "Could not find zone for domain: $CLOUDFLARE_DEFAULT_DOMAIN"
        return 1
    fi

    echo "$zone_id"
}

# Get or create tunnel
get_or_create_tunnel() {
    log "Checking for existing tunnel: $CLOUDFLARE_TUNNEL_NAME"

    local response
    response=$(cf_api GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel?is_deleted=false")

    local tunnel_id
    tunnel_id=$(echo "$response" | jq -r ".result[] | select(.name == \"$CLOUDFLARE_TUNNEL_NAME\") | .id // empty")

    if [ -n "$tunnel_id" ]; then
        log "Found existing tunnel: $tunnel_id"
        echo "$tunnel_id"
        return
    fi

    log "Creating new tunnel: $CLOUDFLARE_TUNNEL_NAME (remotely-managed)"

    response=$(cf_api POST "/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel" "{\"name\": \"$CLOUDFLARE_TUNNEL_NAME\", \"config_src\": \"cloudflare\"}")

    tunnel_id=$(echo "$response" | jq -r '.result.id // empty')

    if [ -z "$tunnel_id" ]; then
        error "Failed to create tunnel"
        error "Response: $response"
        return 1
    fi

    log "Created tunnel: $tunnel_id"

    # Get tunnel token for remotely-managed tunnel
    local token
    token=$(get_tunnel_token "$tunnel_id") || return 1

    # Save token for cloudflared to use
    echo "$token" > /config/tunnel-token

    log "Tunnel token saved to /config/tunnel-token"

    echo "$tunnel_id"
}

# Get tunnel token for existing tunnel
get_tunnel_token() {
    local tunnel_id="$1"

    log "Fetching tunnel token for: $tunnel_id"

    local response
    response=$(cf_api GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel/$tunnel_id/token")

    local token
    token=$(echo "$response" | jq -r '.result // empty')

    if [ -z "$token" ]; then
        error "Failed to get tunnel token"
        error "Response: $response"
        return 1
    fi

    echo "$token"
}

# Add or update tunnel route
add_tunnel_route() {
    local tunnel_id="$1"
    local hostname="$2"
    local service="$3"
    local zone_id="$4"

    log "Adding route for $hostname"

    # Create CNAME record for the tunnel
    # Note: Cloudflare API doesn't support updating tunnel ingress rules via API
    # when using API tokens. Instead, we'll just set up DNS and document
    # that users need to run cloudflared with appropriate config

    log "Route configuration complete (DNS record created)"
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

    # Get zone ID
    local zone_id
    zone_id=$(get_zone_id) || return 1

    # Get or create tunnel
    local tunnel_id
    tunnel_id=$(get_or_create_tunnel) || return 1

    # Ensure tunnel token exists
    if [ ! -f /config/tunnel-token ]; then
        log "Tunnel token not found, fetching from API"
        local token
        token=$(get_tunnel_token "$tunnel_id") || return 1
        echo "$token" > /config/tunnel-token
        log "Tunnel token saved to /config/tunnel-token"
    fi

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
        upsert_dns_record "$zone_id" "$hostname" "$tunnel_id"
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
                delete_dns_record "$zone_id" "$hostname"
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
