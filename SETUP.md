# Quick Setup Guide

## Step 1: Configure Environment Variables

```bash
cp .env.example .env
nano .env
```

**Recommended:** Run the setup wizard to automatically generate your `.env`:

```bash
./setup.sh
```

Or manually fill in the values:
- `CLOUDFLARE_API_TOKEN` - API token (create at https://dash.cloudflare.com/profile/api-tokens)
- `CLOUDFLARE_DOMAIN` - Your domain (e.g., `example.com`)
- `CLOUDFLARE_ZONE_ID` - Zone ID for your domain
- `CLOUDFLARE_ACCOUNT_ID` - Your Cloudflare account ID
- `CLOUDFLARE_TUNNEL_NAME` - Name for your tunnel (e.g., `docker-tunnel`)

## Step 2: Start the Tunnel Manager

```bash
docker-compose up -d cloudflare-tunnel-manager
```

This will:
- Monitor your Docker containers
- Create DNS records automatically
- Push ingress configuration to Cloudflare API

## Step 3: Start Cloudflared

```bash
docker-compose up -d cloudflared
```

The tunnel token from `.env` is used automatically.

## Step 4: Verify

Check that everything is running:

```bash
# Check tunnel manager logs
docker logs cloudflare-tunnel-manager

# Check cloudflared logs
docker logs cloudflared

# Should see: "Registered tunnel connection"
```

## Step 5: Test with a Container

Deploy any container with an exposed port:

```bash
docker run -d --name test -p 80 nginx
```

Your app will automatically be available at: `test.yourdomain.com`

Routes update automatically without restarting cloudflared.

## Troubleshooting

### Cloudflared won't start

- Check that `CLOUDFLARE_TUNNEL_TOKEN` is set in `.env`
- Verify the setup script ran successfully: `./setup.sh`
- Check cloudflared logs: `docker logs cloudflared`

### DNS not resolving

- Wait a few minutes for DNS propagation
- Check Cloudflare DNS records in your dashboard
- Verify the tunnel manager is running: `docker logs cloudflare-tunnel-manager`

### Containers not getting tunnels

- Ensure container has exactly ONE exposed port
- Or add label: `cloudflare.tunnel.port=8080`
- Check generated config: `cat config/tunnel-config.json`
