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
    dos2unix \
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

RUN chmod +x /opt/cf-optimizer/*.sh && \
    dos2unix /opt/cf-optimizer/*.sh

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
