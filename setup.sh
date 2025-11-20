#!/bin/bash
set -e

echo "=================================="
echo "Cloudflare Tunnel Setup Wizard"
echo "=================================="
echo ""

# Check for required tools
for cmd in curl jq; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd is required but not installed"
        exit 1
    fi
done

# Step 1: Get Cloudflare credentials
echo "Step 1: Cloudflare Credentials"
echo "-------------------------------"
echo ""
echo "Find your Global API Key at:"
echo "https://dash.cloudflare.com/profile/api-tokens"
echo "(Scroll down to 'Global API Key' section)"
echo ""

read -p "Enter your Cloudflare email: " cf_email
read -sp "Enter your Global API Key: " global_key
echo ""

echo ""
echo "Testing credentials..."

# Test API access and list zones
zones_response=$(curl -s "https://api.cloudflare.com/client/v4/zones" \
    -H "X-Auth-Email: $cf_email" \
    -H "X-Auth-Key: $global_key" \
    -H "Content-Type: application/json")

if ! echo "$zones_response" | jq -e '.success' > /dev/null 2>&1; then
    echo "Error: Failed to authenticate with Cloudflare"
    echo "Response: $(echo "$zones_response" | jq -r '.errors[0].message // "Unknown error"')"
    exit 1
fi

echo "✓ Authentication successful"
echo ""

# Step 2: Select domain
echo "Step 2: Select Domain"
echo "---------------------"
echo ""

# Get domain names into array
domains=()
while IFS= read -r domain; do
    domains+=("$domain")
done < <(echo "$zones_response" | jq -r '.result[].name')

if [ ${#domains[@]} -eq 0 ]; then
    echo "No zones found in your account"
    exit 1
fi

echo "Select your domain:"
select selected_domain in "${domains[@]}"; do
    if [ -n "$selected_domain" ]; then
        break
    fi
done

# Extract zone and account info for selected domain
zone_info=$(echo "$zones_response" | jq -r ".result[] | select(.name == \"$selected_domain\") | \"\(.id)\t\(.account.id)\"")

zone_id=$(echo "$zone_info" | cut -f1)
account_id=$(echo "$zone_info" | cut -f2)

echo ""
echo "✓ Domain: $selected_domain"
echo "  Zone ID: $zone_id"
echo "  Account ID: $account_id"
echo ""

# Step 3: Create API Token via API
echo "Step 3: Create API Token"
echo "------------------------"
echo ""
echo "Creating scoped API token with required permissions..."

token_name="tunnel-ingress-$selected_domain-$(date +%Y%m%d-%H%M%S)"

# Create token with required permissions
token_payload=$(jq -n \
    --arg name "$token_name" \
    --arg zone_id "$zone_id" \
    --arg account_id "$account_id" \
    '{
        "name": $name,
        "policies": [
            {
                "effect": "allow",
                "resources": {
                    ("com.cloudflare.api.account.zone." + $zone_id): "*"
                },
                "permission_groups": [
                    {"id": "c8fed203ed3043cba015a93ad1616f1f", "name": "Zone Read"},
                    {"id": "4755a26eedb94da69e1066d98aa820be", "name": "DNS Write"}
                ]
            },
            {
                "effect": "allow",
                "resources": {
                    ("com.cloudflare.api.account." + $account_id): "*"
                },
                "permission_groups": [
                    {"id": "c07321b023e944ff818fec44d8203567", "name": "Cloudflare Tunnel Write"},
                    {"id": "c1fde68c7bcc44588cbb6ddbc16d6480", "name": "Account Settings Read"}
                ]
            }
        ]
    }')

token_response=$(curl -s "https://api.cloudflare.com/client/v4/user/tokens" \
    -X POST \
    -H "X-Auth-Email: $cf_email" \
    -H "X-Auth-Key: $global_key" \
    -H "Content-Type: application/json" \
    -d "$token_payload")

if ! echo "$token_response" | jq -e '.success' > /dev/null 2>&1; then
    echo "Error: Failed to create API token"
    echo "Response: $(echo "$token_response" | jq -r '.errors[0].message // "Unknown error"')"
    exit 1
fi

api_token=$(echo "$token_response" | jq -r '.result.value')

echo "✓ API Token created: $token_name"

# Step 4: Tunnel name
echo ""
echo "Step 4: Tunnel Name"
echo "-------------------"
echo ""
read -p "Enter tunnel name [default: docker-tunnel]: " tunnel_name
tunnel_name=${tunnel_name:-docker-tunnel}

# Step 5: Get or create tunnel
echo ""
echo "Step 5: Create Tunnel"
echo "---------------------"
echo ""
echo "Checking for existing tunnel: $tunnel_name"

# Check if tunnel exists
tunnel_response=$(curl -s "https://api.cloudflare.com/client/v4/accounts/$account_id/cfd_tunnel?is_deleted=false" \
    -H "Authorization: Bearer $api_token" \
    -H "Content-Type: application/json")

tunnel_id=$(echo "$tunnel_response" | jq -r ".result[] | select(.name == \"$tunnel_name\") | .id // empty")

if [ -n "$tunnel_id" ]; then
    echo "✓ Found existing tunnel: $tunnel_id"
else
    echo "Creating new tunnel: $tunnel_name"

    create_response=$(curl -s "https://api.cloudflare.com/client/v4/accounts/$account_id/cfd_tunnel" \
        -X POST \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"$tunnel_name\", \"config_src\": \"cloudflare\"}")

    if ! echo "$create_response" | jq -e '.success' > /dev/null 2>&1; then
        echo "Error: Failed to create tunnel"
        echo "Response: $(echo "$create_response" | jq -r '.errors[0].message // "Unknown error"')"
        exit 1
    fi

    tunnel_id=$(echo "$create_response" | jq -r '.result.id')
    echo "✓ Created tunnel: $tunnel_id"
fi

# Get tunnel token
echo "Fetching tunnel token..."

token_response=$(curl -s "https://api.cloudflare.com/client/v4/accounts/$account_id/cfd_tunnel/$tunnel_id/token" \
    -H "Authorization: Bearer $api_token" \
    -H "Content-Type: application/json")

if ! echo "$token_response" | jq -e '.success' > /dev/null 2>&1; then
    echo "Error: Failed to get tunnel token"
    echo "Response: $(echo "$token_response" | jq -r '.errors[0].message // "Unknown error"')"
    exit 1
fi

tunnel_token=$(echo "$token_response" | jq -r '.result')

echo "✓ Tunnel token retrieved"

# Step 6: Generate .env file
echo ""
echo "Step 6: Generating .env file"
echo "-----------------------------"
echo ""

cat > .env <<EOF
# Cloudflare API Configuration
CLOUDFLARE_API_TOKEN=$api_token

# Domain Configuration
CLOUDFLARE_DOMAIN=$selected_domain
CLOUDFLARE_ZONE_ID=$zone_id
CLOUDFLARE_ACCOUNT_ID=$account_id

# Tunnel Configuration
CLOUDFLARE_TUNNEL_NAME=$tunnel_name
CLOUDFLARE_TUNNEL_ID=$tunnel_id
CLOUDFLARE_TUNNEL_TOKEN=$tunnel_token
EOF

echo "✓ .env file created successfully!"
echo ""
echo "Configuration:"
echo "  Domain: $selected_domain"
echo "  Tunnel: $tunnel_name ($tunnel_id)"
echo "  Zone ID: $zone_id"
echo "  Account ID: $account_id"
echo ""
echo "Next steps:"
echo "  1. Review .env file"
echo "  2. Run: docker-compose up -d"
echo ""
