#!/bin/sh
# entrypoint.sh - Container entrypoint

set -e

# Validate required environment variables
: "${CLIENT_ID:?CLIENT_ID is required}"
: "${TOKEN:?TOKEN is required}"
: "${WORKER_URL:?WORKER_URL is required}"

# Export for sub-scripts
export CLIENT_ID TOKEN WORKER_URL

# Create log directory
mkdir -p /var/log/cf-optimizer

echo "CF IP Optimizer container starting..."
echo "  Client ID: ${CLIENT_ID}"
echo "  Worker URL: ${WORKER_URL}"

# Start optimizer
exec /opt/cf-optimizer/optimizer.sh
