#!/bin/sh
# optimizer.sh - Main optimization loop
# Reads config from Workers KV, runs cfst, uploads results

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
    curl -s --max-time 10 "${WORKER_URL}/api/ips/conf" 2>/dev/null || echo '{}'
}

# Get public IP address
get_public_ip() {
    curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
    curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
    curl -s --max-time 5 https://icanhazip.com 2>/dev/null || \
    echo "unknown"
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
    # Handle multi-line JSON by removing newlines first
    echo "$json" | tr -d '\n' | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\[[^]]*\]" | \
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
        START_TIME=$(date +%s)
        TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        PUBLIC_IP=$(get_public_ip)
        IPS_TEMP_FILE="/tmp/ips_json_parts.txt"
        > "$IPS_TEMP_FILE"  # Clear temp file

        for PORT in $PORTS; do
            RESULT_FILE="/tmp/result_${PORT}.csv"

            # Run cfst
            log "Testing port ${PORT}..."

            # Generate random IPs
            IP_FILE="/tmp/test_ips_${PORT}.txt"
            /opt/cf-optimizer/generate_ips.sh "$TEST_COUNT" "$IP_VERSION" > "$IP_FILE"

            # Run cfst
            $CFST_BIN \
                -f "$IP_FILE" \
                -tp "$PORT" \
                -dn "$DOWNLOAD_COUNT" \
                -tl "$LATENCY_MAX" \
                -sl "$DOWNLOAD_MIN" \
                -p 0 \
                -o "$RESULT_FILE" 2>/dev/null

            # Parse results and append to temp file
            if [ -f "$RESULT_FILE" ]; then
                tail -n +2 "$RESULT_FILE" | while IFS=, read -r ip sent recv loss latency speed region; do
                    if [ -n "$ip" ]; then
                        echo "{\"ip\":\"${ip}\",\"port\":${PORT},\"latency\":${latency},\"downloadSpeed\":${speed}}" >> "$IPS_TEMP_FILE"
                    fi
                done
            fi
        done

        # Build JSON array from temp file
        if [ -s "$IPS_TEMP_FILE" ]; then
            ALL_IPS=$(cat "$IPS_TEMP_FILE" | tr '\n' ',' | sed 's/,$//')
            ALL_IPS="[${ALL_IPS}]"
        else
            ALL_IPS="[]"
        fi

        # Calculate duration
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))

        # 3. Build result JSON
        RESULT_JSON="{\"lastUpdated\":\"${TIMESTAMP}\",\"duration\":${DURATION},\"reporterIp\":\"${PUBLIC_IP}\",\"ips\":${ALL_IPS}}"

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
