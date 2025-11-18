# Cloudflare Tunnel Manager for Docker

Automatically create and manage Cloudflare Tunnel routes for your Docker containers using convention over configuration.

## Features

- **Zero Configuration**: Containers automatically get `<container-name>.<your-domain>` hostnames
- **Auto Port Detection**: If a container exposes a single port, it's automatically used
- **Dynamic Updates**: Routes are added/removed as containers start/stop
- **Single Tunnel**: All containers share one Cloudflare tunnel for efficiency
- **Label Overrides**: Customize behavior when needed

## Quick Start

### 1. Prerequisites

- Docker and Docker Compose installed
- Cloudflare account with a domain
- Cloudflare API token with permissions:
  - `Account.Cloudflare Tunnel:Edit`
  - `Zone.DNS:Edit`

### 2. Setup

Clone or create this project, then configure your environment:

```bash
# Copy example environment file
cp .env.example .env

# Edit .env with your Cloudflare credentials
```

### 3. Start the Tunnel Manager

```bash
docker-compose up -d cloudflare-tunnel-manager
```

This will create your Cloudflare tunnel and start monitoring containers.

### 4. Start Cloudflared

The tunnel manager automatically creates a remotely-managed tunnel and saves the token to `config/tunnel-token`. Start cloudflared to establish the connection:

```bash
docker-compose up -d cloudflared
```

The tunnel configuration (ingress rules) is managed via the Cloudflare API, so routes update automatically without restarting `cloudflared`.

### 5. Deploy Your Applications

The tunnel manager automatically detects containers on the same Docker network.

#### Example: Simple Web App

```yaml
version: '3.8'

services:
  my-web-app:
    image: nginx:alpine
    ports:
      - "80"
```

Start your app:

```bash
docker-compose up -d
```

Your app is now accessible at: `http://my-web-app.yourdomain.com`

## Configuration

### Environment Variables

Edit `.env` file:

| Variable | Required | Description | Default |
|----------|----------|-------------|---------|
| `CLOUDFLARE_API_TOKEN` | Yes | API token from Cloudflare dashboard | - |
| `CLOUDFLARE_ACCOUNT_ID` | Yes | Your Cloudflare account ID | - |
| `CLOUDFLARE_DEFAULT_DOMAIN` | Yes | Base domain for hostnames | - |
| `CLOUDFLARE_TUNNEL_NAME` | No | Name of the tunnel | `default-tunnel` |
| `CLOUDFLARE_ZONE_ID` | No | Zone ID (auto-detected if not set) | - |

### Convention Rules

1. **Hostname Generation**: `<container-name>.<CLOUDFLARE_DEFAULT_DOMAIN>`
2. **Port Detection**:
   - One exposed port → automatically used
   - Multiple ports → skipped (use label override)
   - No ports → skipped

### Label Overrides

Customize behavior with Docker labels:

```yaml
services:
  my-app:
    image: my-image
    labels:
      # Disable tunnel for this container
      cloudflare.tunnel.enable: "false"

      # Custom hostname
      cloudflare.tunnel.hostname: "custom.example.com"

      # Specific port (when multiple are exposed)
      cloudflare.tunnel.port: "8080"
    ports:
      - "8080"
      - "8081"
```

## Examples

### Example 1: Basic Web Server

```yaml
services:
  nginx:
    image: nginx:alpine
    ports:
      - "80"
```

**Result**: Accessible at `nginx.yourdomain.com`

### Example 2: API with Custom Hostname

```yaml
services:
  api:
    image: my-api:latest
    labels:
      cloudflare.tunnel.hostname: "api.example.com"
    ports:
      - "3000"
```

**Result**: Accessible at `api.example.com`

### Example 3: Multiple Services

```yaml
services:
  frontend:
    image: my-frontend
    ports:
      - "80"

  backend:
    image: my-backend
    ports:
      - "8080"

  admin:
    image: my-admin
    labels:
      cloudflare.tunnel.enable: "false"
    ports:
      - "9000"
```

**Result**:
- `frontend.yourdomain.com` → frontend:80
- `backend.yourdomain.com` → backend:8080
- admin service is not exposed

### Example 4: Multi-Port Container

```yaml
services:
  app:
    image: multi-port-app
    labels:
      cloudflare.tunnel.port: "8080"
    ports:
      - "8080"
      - "8081"
      - "9090"
```

**Result**: Only port 8080 is exposed at `app.yourdomain.com`

## How It Works

1. **docker-gen** monitors Docker events for container changes
2. Template extracts container metadata (name, ports, labels)
3. Generates JSON configuration with routing rules
4. Triggers bash script on any change
5. Script:
   - Creates remotely-managed Cloudflare tunnel (if needed)
   - Manages DNS records (CNAME to tunnel)
   - Pushes ingress configuration to Cloudflare API
   - Cleans up removed containers

**Note:** This tool creates a remotely-managed tunnel and pushes configuration via API. Routes update automatically without restarting `cloudflared`. You'll need to run `cloudflared` separately to establish the actual tunnel connection. See [Running Cloudflared](#running-cloudflared) below.

## Running Cloudflared

After the tunnel manager creates your tunnel and DNS records, you need to run `cloudflared` to establish the connection.

### Option 1: Docker Compose (Recommended)

Add cloudflared to your `docker-compose.yml`:

```yaml
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    command: tunnel run --token $$(cat /config/tunnel-token)
    volumes:
      - ./config:/config:ro
    restart: unless-stopped
    depends_on:
      - cloudflare-tunnel-manager
```

Or use the token directly from environment:

```yaml
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    command: tunnel run --token ${CLOUDFLARE_TUNNEL_TOKEN}
    restart: unless-stopped
```

### Option 2: Manual Setup

Run cloudflared with the token:

```bash
docker run -d \
  --name cloudflared \
  -v $(pwd)/config:/config:ro \
  cloudflare/cloudflared:latest \
  tunnel run --token $(cat config/tunnel-token)
```

### Verify Tunnel is Running

```bash
# Check cloudflared logs
docker logs cloudflared

# You should see: "Connection established"
```

## Troubleshooting

### Check Manager Logs

```bash
docker logs cloudflare-tunnel-manager
```

### Verify Configuration

```bash
# Check generated config
cat config/tunnel-config.json

# Check tunnel state
cat config/tunnel-state.json
```

### Common Issues

**Containers not getting tunnels:**
- Ensure container has exactly one exposed port, or add `cloudflare.tunnel.port` label
- Check `cloudflare.tunnel.enable` is not set to "false"

**DNS not resolving:**
- Verify Cloudflare API token has DNS edit permissions
- Check zone ID matches your domain
- Allow a few minutes for DNS propagation

**Tunnel creation fails:**
- Verify API token has Tunnel edit permissions
- Check account ID is correct
- Ensure tunnel name doesn't contain special characters

## API Token Setup

1. Go to https://dash.cloudflare.com/profile/api-tokens
2. Click "Create Token"
3. Use "Create Custom Token"
4. Set permissions:
   - **Account** → Cloudflare Tunnel → Edit
   - **Zone** → DNS → Edit
5. Set zone resources to include your domain
6. Create token and copy to `.env` file

## Project Structure

```
.
├── docker-compose.yml          # Main compose file
├── .env.example                # Environment template
├── templates/
│   └── tunnel-config.tmpl      # docker-gen template
├── scripts/
│   └── update-tunnel.sh        # Cloudflare API script
└── config/                     # Generated configs (git-ignored)
    ├── tunnel-config.json      # Current container routes
    ├── tunnel-state.json       # Previous state for diff
    └── tunnel-token            # Tunnel authentication token
```

## License

MIT

## Contributing

Issues and pull requests welcome!
