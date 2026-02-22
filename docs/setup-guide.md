# CF IP Optimizer Setup Guide

## Prerequisites

- Cloudflare account
- Docker on your NAS/server
- wrangler CLI (for Worker deployment)

## Step 1: Create Cloudflare Resources

### 1.1 Create KV Namespace

1. Go to Cloudflare Dashboard > Workers > KV
2. Create a namespace named `CF_IP_OPTIMIZER`
3. Note the Namespace ID

### 1.2 Create API Token

1. Go to Cloudflare Dashboard > My Profile > API Tokens
2. Create Token with these permissions:
   - Account > Workers KV Storage > Edit
   - Zone > Workers Routes > Edit (optional)
3. Note the token

### 1.3 Get Account ID

1. Go to Cloudflare Dashboard
2. Select any domain
3. Find Account ID in the right sidebar

## Step 2: Deploy Worker

```bash
cd worker

# Install wrangler
npm install

# Login to Cloudflare
npx wrangler login

# Update wrangler.toml with your KV namespace ID

# Deploy
npm run deploy
```

Note the Worker URL (e.g., `https://cf-ip-optimizer.your-subdomain.workers.dev`)

## Step 3: Initialize KV Configuration

```bash
# Set initial config in KV
curl -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/YOUR_ACCOUNT_ID/storage/kv/namespaces/YOUR_KV_NAMESPACE_ID/values/config" \
  -H "Authorization: Bearer YOUR_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "interval": 3600,
    "testCount": 1000,
    "downloadCount": 50,
    "latencyMax": 200,
    "downloadMin": 5,
    "ports": [443],
    "ipVersion": "both"
  }'
```

## Step 4: Download cfst Binary

```bash
cd docker/cfst

# Download latest cfst for Linux AMD64
wget https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.3.4/cfst_linux_amd64.tar.gz
tar -xzf cfst_linux_amd64.tar.gz
mv CloudflareST cfst
rm cfst_linux_amd64.tar.gz
```

## Step 5: Build and Run Docker Container

```bash
cd docker

# Copy and configure environment
cp .env.example .env
# Edit .env with your values

# Build image
docker-compose build

# Run container
docker-compose up -d

# View logs
docker-compose logs -f
```

## Step 6: Verify

```bash
# Check API endpoints
curl https://your-worker.workers.dev/api/ips/conf
curl https://your-worker.workers.dev/api/ips
curl https://your-worker.workers.dev/api/ips/json
```

## Configuration Options

| Field | Default | Description |
|-------|---------|-------------|
| `interval` | 3600 | Seconds between optimization runs |
| `testCount` | 1000 | Number of IPs to test |
| `downloadCount` | 50 | Number of IPs to download test |
| `latencyMax` | 200 | Maximum latency (ms) |
| `downloadMin` | 5 | Minimum download speed (MB/s) |
| `ports` | [443] | Ports to test |
| `ipVersion` | "both" | ipv4, ipv6, or both |

## Usage Examples

### Subscribe in Clash

```yaml
proxy-providers:
  cf-optimized:
    type: http
    url: "https://your-worker.workers.dev/api/ips"
    interval: 3600
    path: ./proxy_provider/cf.yaml
    health-check:
      enable: true
      interval: 600
      url: http://www.gstatic.com/generate_204
```

### Use in Scripts

```bash
# Get best IP
BEST_IP=$(curl -s https://your-worker.workers.dev/api/ips | head -1)
echo "Best IP: $BEST_IP"
```
