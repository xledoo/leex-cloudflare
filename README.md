# CF IP Optimizer

Automatically optimize Cloudflare IPs and store results in Workers KV.

## Features

- Automatic IP optimization on configurable schedule
- Multi-port support (80, 443, etc.)
- IPv4 and IPv6 support
- Results stored in Cloudflare Workers KV
- Simple API for reading results

## Quick Start

See [Setup Guide](docs/setup-guide.md) for detailed instructions.

### 1. Deploy Worker

```bash
cd worker && npm install && npm run deploy
```

### 2. Build Docker Image

```bash
cd docker
cp .env.example .env
# Edit .env
docker-compose up -d
```

### 3. Get Optimized IPs

```bash
curl https://your-worker.workers.dev/api/ips
```

## API Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /api/ips` | Plain text IP list |
| `GET /api/ips/json` | JSON with full details |
| `GET /api/ips/conf` | Current configuration |

## Architecture

```
Docker Container (NAS)
    │
    ├── cfst (IP testing)
    ├── optimizer.sh (main loop)
    │
    ▼
Cloudflare API ──► Workers KV
                        │
    ┌───────────────────┤
    ▼                   ▼
Workers API      Your Apps/Scripts
```

## Configuration

Edit KV `config` key to adjust optimization parameters:

```json
{
  "interval": 3600,
  "testCount": 1000,
  "downloadCount": 50,
  "latencyMax": 200,
  "downloadMin": 5,
  "ports": [443],
  "ipVersion": "both"
}
```

## License

MIT
