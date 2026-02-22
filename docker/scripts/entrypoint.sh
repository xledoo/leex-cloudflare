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
