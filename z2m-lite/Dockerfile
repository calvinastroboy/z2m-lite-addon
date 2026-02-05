ARG BUILD_FROM=ghcr.io/hassio-addons/base:16.3.2
FROM ${BUILD_FROM}

# Install Node.js and nginx
RUN apk add --no-cache nodejs npm nginx curl jq

# Copy frontend build
COPY frontend/ /var/www/z2m-lite/

# Copy server files
COPY rootfs/ /

# Copy run script
COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
