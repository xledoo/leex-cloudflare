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
