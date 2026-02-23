#!/bin/sh
# optimizer.sh - Main optimization loop
# Uses Worker API for config and result upload

CFST_BIN="/opt/cf-optimizer/cfst"
LOG_DIR="/var/log/cf-optimizer"
LOG_FILE="${LOG_DIR}/optimizer.log"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

fetch_config() {
    curl -s --max-time 10 "${WORKER_URL}/api/ips/conf?client_id=${CLIENT_ID}" 2>/dev/null || echo '{}'
}

get_public_ip() {
    curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
    curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
    curl -s --max-time 5 https://icanhazip.com 2>/dev/null || \
    echo "unknown"
}

upload_results() {
    local data=$1

    curl -s -X POST \
        "${WORKER_URL}/api/report" \
        -H "Content-Type: application/json" \
        -d "{\"client_id\":\"${CLIENT_ID}\",\"token\":\"${TOKEN}\",\"data\":${data}}" \
        --max-time 30 > /dev/null
}

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
    echo "$json" | tr -d '\n' | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\[[^]]*\]" | \
        grep -o '\[[^]]*\]'
}

main_loop() {
    while true; do
        log "========== Starting optimization cycle =========="

        log "Fetching configuration..."
        CONFIG=$(fetch_config)

        INTERVAL=$(json_val "$CONFIG" "interval" "3600")
        TEST_COUNT=$(json_val "$CONFIG" "testCount" "1000")
        DOWNLOAD_COUNT=$(json_val "$CONFIG" "downloadCount" "50")
        LATENCY_MAX=$(json_val "$CONFIG" "latencyMax" "200")
        DOWNLOAD_MIN=$(json_val "$CONFIG" "downloadMin" "5")
        IP_VERSION=$(json_val "$CONFIG" "ipVersion" "both")
        PORTS_JSON=$(json_array "$CONFIG" "ports")

        log "Config: interval=${INTERVAL}s, testCount=${TEST_COUNT}, ports=${PORTS_JSON}"

        if [ -z "$PORTS_JSON" ] || [ "$PORTS_JSON" = "[]" ]; then
            PORTS="443"
        else
            PORTS=$(echo "$PORTS_JSON" | tr -d '[]' | tr ',' ' ')
        fi

        START_TIME=$(date +%s)
        TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        PUBLIC_IP=$(get_public_ip)
        IPS_TEMP_FILE="/tmp/ips_json_parts.txt"
        > "$IPS_TEMP_FILE"

        # 优先使用外部IP源，失败则随机生成
        IP_SOURCE_FILE="/tmp/ip_source.txt"
        
        log "Fetching IP source from wetest.vip..."
        FETCHED=0
        
        # 从wetest.vip解析优选IP (兼容POSIX shell)
        if curl -s --max-time 30 "https://www.wetest.vip/page/cloudflare/address_v4.html" -o /tmp/wetest.html 2>/dev/null; then
            # 提取优选地址列中的IP
            sed -n 's/.*data-label="优选地址">\([0-9.]*\).*/\1/p' /tmp/wetest.html > "$IP_SOURCE_FILE" 2>/dev/null
            if [ -s "$IP_SOURCE_FILE" ]; then
                FETCHED=1
                IP_COUNT=$(wc -l < "$IP_SOURCE_FILE")
                log "Fetched $IP_COUNT IPs from wetest.vip"
            fi
        fi
        
        if [ $FETCHED -eq 0 ]; then
            log "Warning: Failed to fetch external IP source, using random generation"
            /opt/cf-optimizer/generate_ips.sh "$TEST_COUNT" "$IP_VERSION" > "$IP_SOURCE_FILE"
        fi
        
        IP_FILE="$IP_SOURCE_FILE"

        for PORT in $PORTS; do
            RESULT_FILE="/tmp/result_${PORT}.csv"

            log "Testing port ${PORT}..."

            $CFST_BIN \
                -f "$IP_FILE" \
                -tp "$PORT" \
                -dn "$DOWNLOAD_COUNT" \
                -tl "$LATENCY_MAX" \
                -sl "$DOWNLOAD_MIN" \
                -p 10 \
                -url "https://cftest.speedtestcustom.com/__down?measId=123" \
                -o "$RESULT_FILE" 2>/dev/null

            if [ -f "$RESULT_FILE" ]; then
                tail -n +2 "$RESULT_FILE" | while IFS=, read -r ip sent recv loss latency speed region; do
                    if [ -n "$ip" ]; then
                        echo "{\"ip\":\"${ip}\",\"port\":${PORT},\"latency\":${latency},\"downloadSpeed\":${speed}}" >> "$IPS_TEMP_FILE"
                    fi
                done
            fi
        done

        if [ -s "$IPS_TEMP_FILE" ]; then
            ALL_IPS=$(cat "$IPS_TEMP_FILE" | tr '\n' ',' | sed 's/,$//')
            ALL_IPS="[${ALL_IPS}]"
        else
            ALL_IPS="[]"
        fi

        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))

        RESULT_DATA="{\"lastUpdated\":\"${TIMESTAMP}\",\"duration\":${DURATION},\"reporterIp\":\"${PUBLIC_IP}\",\"ips\":${ALL_IPS}}"

        log "Uploading results via Worker API..."
        if upload_results "$RESULT_DATA"; then
            log "Results uploaded successfully"
        else
            log "Warning: Failed to upload results"
        fi

        log "Optimization complete. Sleeping for ${INTERVAL} seconds..."
        sleep "$INTERVAL"
    done
}

if [ -z "$CLIENT_ID" ] || [ -z "$TOKEN" ]; then
    log "ERROR: CLIENT_ID and TOKEN are required"
    exit 1
fi

log "CF IP Optimizer starting..."
log "Client ID: ${CLIENT_ID}"
log "Worker URL: ${WORKER_URL}"

main_loop
