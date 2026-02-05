#!/usr/bin/with-contenv bashio
# Z2M Lite Add-on Startup Script

bashio::log.info "Starting Z2M Lite Panel..."

# ============================================
# Auto-discover Zigbee2MQTT
# ============================================
Z2M_HOST=""
Z2M_PORT="8099"

# 1. Check user config first
if bashio::config.has_value "z2m_host" && [ "$(bashio::config 'z2m_host')" != "" ]; then
    Z2M_HOST=$(bashio::config 'z2m_host')
    Z2M_PORT=$(bashio::config 'z2m_port')
    bashio::log.info "Using manual config: ${Z2M_HOST}:${Z2M_PORT}"
else
    # 2. Auto-discover via Supervisor API — list ALL addons, find Z2M
    bashio::log.info "Auto-discovering Zigbee2MQTT..."

    ADDONS_JSON=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        "http://supervisor/addons" 2>/dev/null)

    # Find Z2M addon slug by matching name or slug pattern
    Z2M_SLUG=$(echo "${ADDONS_JSON}" | jq -r '
        .data.addons[]
        | select(.slug | test("zigbee2mqtt"))
        | .slug
    ' 2>/dev/null | head -1)

    if [ -n "${Z2M_SLUG}" ]; then
        bashio::log.info "Found Z2M addon: ${Z2M_SLUG}"

        # Get detailed info for this addon
        ADDON_INFO=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            "http://supervisor/addons/${Z2M_SLUG}/info" 2>/dev/null)

        # Try to get IP address
        ADDON_IP=$(echo "${ADDON_INFO}" | jq -r '.data.ip_address // empty' 2>/dev/null)
        bashio::log.info "Addon info ip_address: '${ADDON_IP}'"

        if [ -n "${ADDON_IP}" ] && [ "${ADDON_IP}" != "null" ] && [ "${ADDON_IP}" != "" ]; then
            Z2M_HOST="${ADDON_IP}"
            bashio::log.info "Using Z2M addon IP: ${Z2M_HOST}"
        else
            # Try hostname: addon slugs with _ replaced by - work as Docker hostnames
            Z2M_HOST="${Z2M_SLUG//_/-}"
            bashio::log.info "IP not available, trying Docker hostname: ${Z2M_HOST}"
        fi

        # Check if addon has a custom port
        ADDON_PORT=$(echo "${ADDON_INFO}" | jq -r '.data.network["8099/tcp"] // empty' 2>/dev/null)
        if [ -n "${ADDON_PORT}" ] && [ "${ADDON_PORT}" != "null" ]; then
            bashio::log.info "Z2M host-exposed port: ${ADDON_PORT}"
        fi
    else
        bashio::log.warning "No Zigbee2MQTT addon found!"
    fi

    # 3. Fallback: try HA host gateway
    if [ -z "${Z2M_HOST}" ]; then
        # Get the gateway IP (usually the HA host)
        GW_IP=$(ip route | grep default | awk '{print $3}' | head -1)
        if [ -n "${GW_IP}" ]; then
            Z2M_HOST="${GW_IP}"
            bashio::log.info "Fallback: using gateway IP ${Z2M_HOST}:${Z2M_PORT}"
        else
            Z2M_HOST="172.30.32.1"
            Z2M_PORT="8099"
            bashio::log.warning "Final fallback: ${Z2M_HOST}:${Z2M_PORT}"
        fi
    fi
fi

bashio::log.info "Z2M WebSocket target: ws://${Z2M_HOST}:${Z2M_PORT}/api"

# ============================================
# Generate nginx config with WebSocket proxy
# ============================================
INGRESS_ENTRY=$(bashio::addon.ingress_entry)
bashio::log.info "Ingress entry: ${INGRESS_ENTRY}"

cat > /etc/nginx/http.d/default.conf << EOF
server {
    listen 8099;
    server_name _;

    root /var/www/z2m-lite;
    index index.html;

    resolver 127.0.0.11 valid=30s ipv6=off;

    set \$z2m_backend http://${Z2M_HOST}:${Z2M_PORT};

    # WebSocket proxy to Z2M
    location /z2m-ws {
        proxy_pass \$z2m_backend/api;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    # SPA fallback
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Cache static assets
    location /assets/ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
EOF

# Write runtime config for frontend
cat > /var/www/z2m-lite/z2m-config.json << EOF
{
  "wsProxy": true,
  "ingressPath": "${INGRESS_ENTRY}"
}
EOF

bashio::log.info "Starting nginx..."
exec nginx -g "daemon off;"
