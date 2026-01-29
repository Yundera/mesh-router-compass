# mesh-router-compass

The final routing component of the [Mesh Router](https://nsl.sh) ecosystem. Compass runs on your home server and dispatches incoming requests to Docker containers based on labels.

## Overview

Compass is a **standalone reverse proxy** built on OpenResty (Nginx + Lua) that:

- Discovers Docker containers via labels (Caddy-docker-proxy compatible format)
- Automatically provisions TLS certificates (Let's Encrypt → Gateway cert → Self-signed)
- Provides built-in security hardening (fail2ban, rate limiting)
- Works independently or as part of the Mesh Router stack

```
Internet Request
       ↓
┌──────────────────┐
│  mesh-router-    │  (optional - can receive direct requests)
│  gateway/tunnel  │
└────────┬─────────┘
         ↓
┌──────────────────┐
│  mesh-router-    │  ← You are here
│  compass         │
└────────┬─────────┘
         ↓
┌──────────────────┐
│  Docker          │
│  Containers      │
│  (immich, etc.)  │
└──────────────────┘
```

## Quick Start

```bash
docker run -d \
  --name compass \
  -p 80:80 \
  -p 443:443 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -e COMPASS_NETWORK=mesh \
  ghcr.io/yundera/mesh-router-compass:latest
```

## Container Labels

Compass uses a Caddy-docker-proxy inspired label format:

```yaml
services:
  immich:
    image: ghcr.io/immich-app/immich-server:release
    labels:
      compass: "immich.user.nsl.sh"
      compass.reverse_proxy: "{{upstreams 3001}}"
    networks:
      - mesh

networks:
  mesh:
    external: true
```

### Label Reference

| Label | Required | Description | Example |
|-------|----------|-------------|---------|
| `compass` | Yes | The hostname to route to this container | `app.example.com` |
| `compass.reverse_proxy` | Yes | Upstream configuration with port | `{{upstreams 3000}}` |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `COMPASS_NETWORK` | `mesh` | Docker network to watch for labeled containers |
| `COMPASS_HTTP_PORT` | `80` | HTTP listener port |
| `COMPASS_HTTPS_PORT` | `443` | HTTPS listener port |
| `COMPASS_ACME_EMAIL` | - | Email for Let's Encrypt registration |
| `COMPASS_LOG_LEVEL` | `info` | Log verbosity (debug, info, warn, error) |

## TLS Certificate Strategy

Compass automatically manages TLS certificates with an **on-demand fallback chain** (like Caddy):

```
Request arrives → Check LE cert → Check shared cert → Use self-signed
                      ↓ missing
              Trigger async LE acquisition
```

1. **Let's Encrypt** (preferred) - HTTP-01 challenge, per-service certificates, acquired on-demand
2. **Shared Certificate** - Mounted from mesh-router-agent via Docker volume (private CA, encrypts traffic but browser shows warning)
3. **Self-Signed** - Single certificate for all domains, generated on startup

### Certificate Volumes

```yaml
compass:
  volumes:
    - agent-data:/certs/shared:ro       # From agent (private CA cert)
    - compass-certs:/certs/letsencrypt  # LE certs (persisted)
```

The shared certificate comes from the existing mesh-router-agent certificate system. It uses a private CA managed by mesh-router-backend, primarily for encrypting agent-gateway traffic. When Let's Encrypt is unavailable (port 80 blocked, rate limited, etc.), Compass falls back to this cert - the connection will be encrypted but browsers will show a certificate warning.

## Security Features

### Built-in Fail2ban

Protects against:
- Failed TLS handshake attempts
- (Future: 4xx/5xx floods, unknown subdomain scanning)

### Rate Limiting

Built-in request rate limiting per client IP.

### Unknown Service Handling

Requests to `*.user.nsl.sh` for non-existent services return a friendly "Service not found" page instead of connection errors.

## Standalone Mode

Compass is designed to work independently of the Mesh Router stack. You can:

- Point your own domain (`*.yourdomain.com`) directly to Compass
- Use it without the gateway or tunnel components
- Integrate with any reverse proxy that forwards requests

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    compass container                     │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │  OpenResty  │  │   Config    │  │    Fail2ban     │  │
│  │  (Nginx +   │←─│  Generator  │  │                 │  │
│  │   Lua)      │  │   (Lua)     │  │                 │  │
│  └──────┬──────┘  └──────┬──────┘  └─────────────────┘  │
│         │                │                               │
│         │         ┌──────┴──────┐                        │
│         │         │   Docker    │                        │
│         │         │   Socket    │                        │
│         │         │   Watcher   │                        │
│         │         └─────────────┘                        │
└─────────┼───────────────────────────────────────────────┘
          ↓
    Docker Containers (on COMPASS_NETWORK)
```

## Development

```bash
# Clone the repository
git clone https://github.com/Yundera/mesh-router-compass.git
cd mesh-router-compass

# Build the image locally
docker build -t compass:dev .

# Run with development settings
docker run -d \
  --name compass-dev \
  -p 8080:80 \
  -p 8443:443 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v $(pwd)/config:/etc/compass \
  -e COMPASS_NETWORK=mesh \
  -e COMPASS_LOG_LEVEL=debug \
  compass:dev
```

## Comparison with Similar Projects

| Feature | Compass | Caddy Docker Proxy | Traefik |
|---------|---------|-------------------|---------|
| Label format | Caddy-like | Caddy native | Traefik native |
| Base | OpenResty | Caddy | Go native |
| Built-in fail2ban | ✅ | ❌ | ❌ |
| Mesh Router integration | ✅ | ❌ | ❌ |
| Standalone mode | ✅ | ✅ | ✅ |
| Let's Encrypt | ✅ | ✅ | ✅ |

## License

MIT License - see [LICENSE](LICENSE)

## Related Projects

- [mesh-router-gateway](https://github.com/Yundera/mesh-router-gateway) - Edge proxy for the Mesh Router network
- [mesh-router-backend](https://github.com/Yundera/mesh-router-backend) - API for domain and route management
- [mesh-router-tunnel](https://github.com/Yundera/mesh-router-tunnel) - WireGuard VPN for NAT traversal
- [mesh-router-agent](https://github.com/Yundera/mesh-router-agent) - Lightweight IP registration agent
- [mesh-dashboard](https://github.com/Yundera/mesh-dashboard) - Admin dashboard
