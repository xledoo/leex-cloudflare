# CF IP Optimizer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Docker container that automatically optimizes Cloudflare IPs and stores results in Workers KV.

**Architecture:** Docker container runs cfst tool on schedule, results uploaded to CF Workers KV via API. A separate Worker provides read APIs for clients.

**Tech Stack:** Alpine Linux, Shell Script, Cloudflare Workers, Workers KV

---

## Task 1: Project Setup

**Files:**
- Create: `docker/Dockerfile`
- Create: `docker/docker-compose.yml`
- Create: `.gitignore`

**Step 1: Create project directory structure**

Run:
```bash
mkdir -p docker/cfst docker/scripts worker
```

Expected: Directories created

**Step 2: Create .gitignore**

Create `.gitignore`:
```gitignore
# Logs
logs/
*.log

# OS
.DS_Store
Thumbs.db

# IDE
.idea/
.vscode/
*.swp

# Secrets (never commit)
.env
*.pem
```

**Step 3: Commit setup**

```bash
git add .gitignore
git commit -m "chore: initial project setup with gitignore"
```

---

## Task 2: Create IP Pool Files

**Files:**
- Create: `docker/cfst/ip.txt`
- Create: `docker/cfst/ipv6.txt`

**Step 1: Create IPv4 pool file**

Create `docker/cfst/ip.txt`:
```
173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/12
172.64.0.0/13
131.0.72.0/22
```

**Step 2: Create IPv6 pool file**

Create `docker/cfst/ipv6.txt`:
```
2606:4700::/32
```

**Step 3: Commit IP pools**

```bash
git add docker/cfst/ip.txt docker/cfst/ipv6.txt
git commit -m "feat: add Cloudflare IP pool files"
```

---

## Task 3: Create Random IP Generator Script

**Files:**
- Create: `docker/scripts/generate_ips.sh`

**Step 1: Create generate_ips.sh**

Create `docker/scripts/generate_ips.sh`:
```bash
#!/bin/sh
# generate_ips.sh - Generate random IPs from CF IP pools
# Usage: generate_ips.sh <count> <ipVersion>
#   count: number of IPs to generate
#   ipVersion: ipv4 | ipv6 | both

set -e

COUNT=${1:-1000}
IP_VERSION=${2:-"both"}
IPV4_FILE="/opt/cf-optimizer/ip.txt"
IPV6_FILE="/opt/cf-optimizer/ipv6.txt"

# CIDR blocks for IPv4
CIDRS_V4="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/12 172.64.0.0/13 131.0.72.0/22"

# IPv6 CIDR
CIDRS_V6="2606:4700::/32"

rand_octet() {
    echo $((RANDOM % 256))
}

# Generate random IP from CIDR
generate_ipv4_from_cidr() {
    local cidr=$1
    local base_ip=${cidr%/*}
    local mask=${cidr#*/}

    local IFS='.'
    set -- $base_ip
    local o1=$1 o2=$2 o3=$3 o4=$4

    local host_bits=$((32 - mask))
    local max_offset=$((2 ** host_bits - 1))
    local offset=$((RANDOM % max_offset))

    # Add offset to base IP
    local new_o4=$((o4 + offset))
    local new_o3=$o3
    local new_o2=$o2
    local new_o1=$o1

    while [ $new_o4 -gt 255 ]; do
        new_o4=$((new_o4 - 256))
        new_o3=$((new_o3 + 1))
    done
    while [ $new_o3 -gt 255 ]; do
        new_o3=$((new_o3 - 256))
        new_o2=$((new_o2 + 1))
    done
    while [ $new_o2 -gt 255 ]; do
        new_o2=$((new_o2 - 256))
        new_o1=$((new_o1 + 1))
    done

    echo "${new_o1}.${new_o2}.${new_o3}.${new_o4}"
}

generate_ipv6_from_cidr() {
    local cidr=$1
    local base=${cidr%/*}
    # Simplified: generate random suffix for 2606:4700::/32
    local h1=$(printf '%x' $((RANDOM % 65536)))
    local h2=$(printf '%x' $((RANDOM % 65536)))
    local h3=$(printf '%x' $((RANDOM % 65536)))
    local h4=$(printf '%x' $((RANDOM % 65536)))
    echo "${base%%::*}:${h1}:${h2}:${h3}:${h4}"
}

generate_ips() {
    local count=$1
    local version=$2
    local generated=0

    while [ $generated -lt $count ]; do
        if [ "$version" = "ipv4" ] || [ "$version" = "both" ]; then
            for cidr in $CIDRS_V4; do
                if [ $generated -lt $count ]; then
                    generate_ipv4_from_cidr "$cidr"
                    generated=$((generated + 1))
                fi
            done
        fi

        if [ "$version" = "ipv6" ] || [ "$version" = "both" ]; then
            for cidr in $CIDRS_V6; do
                if [ $generated -lt $count ]; then
                    generate_ipv6_from_cidr "$cidr"
                    generated=$((generated + 1))
                fi
            done
        fi
    done
}

# Shuffle and output
generate_ips "$COUNT" "$IP_VERSION" | shuf 2>/dev/null || generate_ips "$COUNT" "$IP_VERSION"
```

**Step 2: Commit script**

```bash
git add docker/scripts/generate_ips.sh
git commit -m "feat: add random IP generator script"
```

---

## Task 4: Create Main Optimizer Script

**Files:**
- Create: `docker/scripts/optimizer.sh`

**Step 1: Create optimizer.sh**

Create `docker/scripts/optimizer.sh`:
```bash
#!/bin/sh
# optimizer.sh - Main optimization loop
# Reads config from Workers KV, runs cfst, uploads results

set -e

CFST_BIN="/opt/cf-optimizer/cfst"
LOG_DIR="/var/log/cf-optimizer"
LOG_FILE="${LOG_DIR}/optimizer.log"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Fetch config from Worker API
fetch_config() {
    curl -s -f "${WORKER_URL}/api/ips/conf" 2>/dev/null || echo '{}'
}

# Write to KV via Cloudflare API
write_kv() {
    local key=$1
    local value=$2

    curl -s -X PUT \
        "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/values/${key}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$value" > /dev/null
}

# Parse JSON value (simple jq alternative using grep/sed for Alpine)
json_val() {
    local json=$1
    local key=$2
    local default=$3

    echo "$json" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*[^,}]*" | \
        sed 's/.*:[[:space:]]*//' | tr -d '"' | head -1 || echo "$default"
}

json_array() {
    local json=$1
    local key=$2
    echo "$json" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\[[^]]*\]" | \
        grep -o '\[[^]]*\]'
}

# Run cfst for a specific port
run_cfst() {
    local port=$1
    local test_count=$2
    local download_count=$3
    local latency_max=$4
    local download_min=$5
    local ip_version=$6

    log "Testing port ${port}..."

    # Generate random IPs
    local ip_file="/tmp/test_ips_${port}.txt"
    /opt/cf-optimizer/generate_ips.sh "$test_count" "$ip_version" > "$ip_file"

    # Run cfst
    local result_file="/tmp/result_${port}.csv"
    $CFST_BIN \
        -f "$ip_file" \
        -tp "$port" \
        -dn "$download_count" \
        -tl "$latency_max" \
        -sl "$download_min" \
        -p 0 \
        -o "$result_file"

    # Return result file path
    echo "$result_file"
}

# Parse CSV result to JSON array
csv_to_json() {
    local csv_file=$1
    local port=$2

    if [ ! -f "$csv_file" ]; then
        echo "[]"
        return
    fi

    local json="["
    local first=true

    # Skip header, parse each line
    tail -n +2 "$csv_file" | while IFS=, read -r ip sent recv loss latency speed region; do
        if [ -n "$ip" ]; then
            if [ "$first" = true ]; then
                first=false
            else
                json="${json},"
            fi
            json="${json}{\"ip\":\"${ip}\",\"port\":${port},\"latency\":${latency},\"downloadSpeed\":${speed}}"
        fi
    done

    json="${json}]"
    echo "$json"
}

# Main optimization loop
main_loop() {
    while true; do
        log "========== Starting optimization cycle =========="

        # 1. Fetch config
        log "Fetching configuration..."
        CONFIG=$(fetch_config)

        # Parse config with defaults
        INTERVAL=$(json_val "$CONFIG" "interval" "3600")
        TEST_COUNT=$(json_val "$CONFIG" "testCount" "1000")
        DOWNLOAD_COUNT=$(json_val "$CONFIG" "downloadCount" "50")
        LATENCY_MAX=$(json_val "$CONFIG" "latencyMax" "200")
        DOWNLOAD_MIN=$(json_val "$CONFIG" "downloadMin" "5")
        IP_VERSION=$(json_val "$CONFIG" "ipVersion" "both")
        PORTS_JSON=$(json_array "$CONFIG" "ports")

        log "Config: interval=${INTERVAL}s, testCount=${TEST_COUNT}, ports=${PORTS_JSON}"

        # Default ports if not specified
        if [ -z "$PORTS_JSON" ] || [ "$PORTS_JSON" = "[]" ]; then
            PORTS="443"
        else
            PORTS=$(echo "$PORTS_JSON" | tr -d '[]' | tr ',' ' ')
        fi

        # 2. Run optimization for each port
        ALL_IPS="["
        FIRST_PORT=true
        TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

        for PORT in $PORTS; do
            RESULT_FILE=$(run_cfst "$PORT" "$TEST_COUNT" "$DOWNLOAD_COUNT" "$LATENCY_MAX" "$DOWNLOAD_MIN" "$IP_VERSION")

            # Parse results and append
            if [ -f "$RESULT_FILE" ]; then
                tail -n +2 "$RESULT_FILE" | while IFS=, read -r ip sent recv loss latency speed region; do
                    if [ -n "$ip" ]; then
                        if [ "$FIRST_PORT" = true ]; then
                            FIRST_PORT=false
                        else
                            ALL_IPS="${ALL_IPS},"
                        fi
                        ALL_IPS="${ALL_IPS}{\"ip\":\"${ip}\",\"port\":${PORT},\"latency\":${latency},\"downloadSpeed\":${speed}}"
                    fi
                done
            fi
        done

        ALL_IPS="${ALL_IPS}]"

        # 3. Build result JSON
        RESULT_JSON="{\"lastUpdated\":\"${TIMESTAMP}\",\"ips\":${ALL_IPS}}"

        # 4. Upload to KV
        log "Uploading results to KV..."
        write_kv "result" "$RESULT_JSON"

        log "Optimization complete. Sleeping for ${INTERVAL} seconds..."
        sleep "$INTERVAL"
    done
}

# Start the loop
log "CF IP Optimizer starting..."
log "Worker URL: ${WORKER_URL}"
log "CF Account: ${CF_ACCOUNT_ID}"

main_loop
```

**Step 2: Commit script**

```bash
git add docker/scripts/optimizer.sh
git commit -m "feat: add main optimizer script with KV integration"
```

---

## Task 5: Create Docker Entrypoint

**Files:**
- Create: `docker/scripts/entrypoint.sh`

**Step 1: Create entrypoint.sh**

Create `docker/scripts/entrypoint.sh`:
```bash
#!/bin/sh
# entrypoint.sh - Container entrypoint

set -e

# Validate required environment variables
: "${CF_API_TOKEN:?CF_API_TOKEN is required}"
: "${CF_ACCOUNT_ID:?CF_ACCOUNT_ID is required}"
: "${KV_NAMESPACE_ID:?KV_NAMESPACE_ID is required}"
: "${WORKER_URL:?WORKER_URL is required}"

# Export for sub-scripts
export CF_API_TOKEN CF_ACCOUNT_ID KV_NAMESPACE_ID WORKER_URL

# Create log directory
mkdir -p /var/log/cf-optimizer

echo "CF IP Optimizer container starting..."
echo "  CF Account: ${CF_ACCOUNT_ID}"
echo "  KV Namespace: ${KV_NAMESPACE_ID}"
echo "  Worker URL: ${WORKER_URL}"

# Start optimizer
exec /opt/cf-optimizer/optimizer.sh
```

**Step 2: Commit script**

```bash
git add docker/scripts/entrypoint.sh
git commit -m "feat: add container entrypoint with validation"
```

---

## Task 6: Create Dockerfile

**Files:**
- Create: `docker/Dockerfile`

**Step 1: Create Dockerfile**

Create `docker/Dockerfile`:
```dockerfile
# CF IP Optimizer Docker Image
# Build: docker build -t cf-ip-optimizer:latest -f docker/Dockerfile .

FROM alpine:3.19

LABEL maintainer="CF IP Optimizer"
LABEL description="Automatic Cloudflare IP optimizer with KV storage"

# Install dependencies
RUN apk add --no-cache \
    curl \
    bash \
    coreutils \
    && rm -rf /var/cache/apk/*

# Create app directory
WORKDIR /opt/cf-optimizer

# Copy cfst binary (download separately)
# Place cfst_linux_amd64 in docker/cfst/ before building
COPY cfst/cfst /opt/cf-optimizer/cfst
RUN chmod +x /opt/cf-optimizer/cfst

# Copy IP pool files
COPY cfst/ip.txt /opt/cf-optimizer/ip.txt
COPY cfst/ipv6.txt /opt/cf-optimizer/ipv6.txt

# Copy scripts
COPY scripts/generate_ips.sh /opt/cf-optimizer/generate_ips.sh
COPY scripts/optimizer.sh /opt/cf-optimizer/optimizer.sh
COPY scripts/entrypoint.sh /opt/cf-optimizer/entrypoint.sh

RUN chmod +x /opt/cf-optimizer/*.sh

# Create log directory
RUN mkdir -p /var/log/cf-optimizer

# Environment variables (to be set at runtime)
ENV CF_API_TOKEN=""
ENV CF_ACCOUNT_ID=""
ENV KV_NAMESPACE_ID=""
ENV WORKER_URL=""

# Volume for logs
VOLUME ["/var/log/cf-optimizer"]

# Health check
HEALTHCHECK --interval=1h --timeout=30s --start-period=1m --retries=3 \
    CMD test -f /var/log/cf-optimizer/optimizer.log || exit 1

# Entry point
ENTRYPOINT ["/opt/cf-optimizer/entrypoint.sh"]
```

**Step 2: Commit Dockerfile**

```bash
git add docker/Dockerfile
git commit -m "feat: add Dockerfile for CF IP Optimizer"
```

---

## Task 7: Create docker-compose.yml

**Files:**
- Create: `docker/docker-compose.yml`
- Create: `docker/.env.example`

**Step 1: Create docker-compose.yml**

Create `docker/docker-compose.yml`:
```yaml
version: '3.8'

services:
  cf-ip-optimizer:
    build:
      context: .
      dockerfile: Dockerfile
    image: cf-ip-optimizer:latest
    container_name: cf-ip-optimizer
    restart: unless-stopped

    environment:
      - CF_API_TOKEN=${CF_API_TOKEN}
      - CF_ACCOUNT_ID=${CF_ACCOUNT_ID}
      - KV_NAMESPACE_ID=${KV_NAMESPACE_ID}
      - WORKER_URL=${WORKER_URL}

    volumes:
      - ./logs:/var/log/cf-optimizer

    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
```

**Step 2: Create .env.example**

Create `docker/.env.example`:
```bash
# Cloudflare API Token with KV read/write permissions
CF_API_TOKEN=your_api_token_here

# Your Cloudflare Account ID
CF_ACCOUNT_ID=your_account_id_here

# Workers KV Namespace ID for CF IP Optimizer
KV_NAMESPACE_ID=your_kv_namespace_id_here

# Workers URL for fetching config
WORKER_URL=https://your-worker.your-subdomain.workers.dev
```

**Step 3: Commit compose files**

```bash
git add docker/docker-compose.yml docker/.env.example
git commit -m "feat: add docker-compose configuration"
```

---

## Task 8: Create Workers Code

**Files:**
- Create: `worker/src/index.js`
- Create: `worker/wrangler.toml`
- Create: `worker/package.json`

**Step 1: Create package.json**

Create `worker/package.json`:
```json
{
  "name": "cf-ip-optimizer-worker",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "wrangler dev",
    "deploy": "wrangler deploy"
  },
  "devDependencies": {
    "wrangler": "^3.0.0"
  }
}
```

**Step 2: Create wrangler.toml**

Create `worker/wrangler.toml`:
```toml
name = "cf-ip-optimizer"
main = "src/index.js"
compatibility_date = "2024-01-01"

# KV Namespace binding
# Run: wrangler kv:namespace create CF_IP_OPTIMIZER
# Then update the id below
[[kv_namespaces]]
binding = "KV"
id = "your_kv_namespace_id_here"

[vars]
ENVIRONMENT = "production"
```

**Step 3: Create Worker index.js**

Create `worker/src/index.js`:
```javascript
/**
 * CF IP Optimizer Worker
 * Provides API endpoints for reading IP optimization results
 */

// Default configuration
const DEFAULT_CONFIG = {
  interval: 3600,
  testCount: 1000,
  downloadCount: 50,
  latencyMax: 200,
  downloadMin: 5,
  ports: [443],
  ipVersion: "both"
};

// CORS headers
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Content-Type": "application/json; charset=utf-8"
};

// Text response headers
const textHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Content-Type": "text/plain; charset=utf-8"
};

/**
 * Handle OPTIONS request for CORS
 */
function handleOptions() {
  return new Response(null, {
    status: 204,
    headers: corsHeaders
  });
}

/**
 * Return JSON response
 */
function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: corsHeaders
  });
}

/**
 * Return text response
 */
function textResponse(text, status = 200) {
  return new Response(text, {
    status,
    headers: textHeaders
  });
}

/**
 * GET /api/ips - Return IPs as plain text (ip:port per line)
 */
async function getIpsText(KV) {
  const result = await KV.get("result", { type: "json" });

  if (!result || !result.ips || result.ips.length === 0) {
    return textResponse("# No optimized IPs available yet\n");
  }

  const lines = result.ips.map(ip => `${ip.ip}:${ip.port}`);
  return textResponse(lines.join("\n"));
}

/**
 * GET /api/ips/json - Return full result as JSON
 */
async function getIpsJson(KV) {
  const result = await KV.get("result", { type: "json" });

  if (!result) {
    return jsonResponse({
      lastUpdated: null,
      ips: [],
      error: "No results available yet. Wait for the optimizer to run."
    });
  }

  return jsonResponse(result);
}

/**
 * GET /api/ips/conf - Return configuration
 */
async function getConfig(KV) {
  const config = await KV.get("config", { type: "json" });

  if (!config) {
    return jsonResponse(DEFAULT_CONFIG);
  }

  // Merge with defaults for any missing fields
  return jsonResponse({
    ...DEFAULT_CONFIG,
    ...config
  });
}

/**
 * Main request handler
 */
async function handleRequest(request, env) {
  const url = new URL(request.url);
  const path = url.pathname;

  // Handle CORS preflight
  if (request.method === "OPTIONS") {
    return handleOptions();
  }

  // Route requests
  if (request.method === "GET") {
    switch (path) {
      case "/api/ips":
        return getIpsText(env.KV);

      case "/api/ips/json":
        return getIpsJson(env.KV);

      case "/api/ips/conf":
        return getConfig(env.KV);

      case "/":
      case "/health":
        return jsonResponse({
          name: "CF IP Optimizer API",
          version: "1.0.0",
          endpoints: [
            "GET /api/ips - Plain text IP list (ip:port per line)",
            "GET /api/ips/json - Full result with latency and speed",
            "GET /api/ips/conf - Current optimization configuration"
          ]
        });

      default:
        return jsonResponse({ error: "Not found" }, 404);
    }
  }

  return jsonResponse({ error: "Method not allowed" }, 405);
}

// Export for Cloudflare Workers
export default {
  async fetch(request, env, ctx) {
    return handleRequest(request, env);
  }
};
```

**Step 4: Commit Worker code**

```bash
git add worker/
git commit -m "feat: add Cloudflare Worker for IP optimization API"
```

---

## Task 9: Create Setup Documentation

**Files:**
- Create: `docs/setup-guide.md`

**Step 1: Create setup guide**

Create `docs/setup-guide.md`:
```markdown
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
```

**Step 2: Commit documentation**

```bash
git add docs/setup-guide.md
git commit -m "docs: add setup guide"
```

---

## Task 10: Final README

**Files:**
- Create: `README.md`

**Step 1: Create README**

Create `README.md`:
```markdown
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
```

**Step 2: Final commit**

```bash
git add README.md
git commit -m "docs: add README"
```

---

## Summary

| Task | Description |
|------|-------------|
| 1 | Project setup |
| 2 | IP pool files |
| 3 | Random IP generator |
| 4 | Main optimizer script |
| 5 | Docker entrypoint |
| 6 | Dockerfile |
| 7 | docker-compose |
| 8 | Workers code |
| 9 | Setup documentation |
| 10 | README |

## Execution Order

1. Tasks 1-7: Build Docker components
2. Task 8: Deploy Worker
3. Task 9-10: Documentation
