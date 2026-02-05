#!/usr/bin/with-contenv bashio
# Z2M Lite Add-on Startup Script

bashio::log.info "Starting Z2M Lite Panel..."

# ============================================
# Auto-discover Zigbee2MQTT
# ============================================
Z2M_HOST=""
Z2M_PORT=""
Z2M_PATH="/api"

# 1. Check user config first
if bashio::config.has_value "z2m_host" && [ "$(bashio::config 'z2m_host')" != "" ]; then
    Z2M_HOST=$(bashio::config 'z2m_host')
    Z2M_PORT=$(bashio::config 'z2m_port')
    Z2M_PATH=$(bashio::config 'z2m_path')
    bashio::log.info "Using manual config: ${Z2M_HOST}:${Z2M_PORT}"
else
    # 2. Auto-discover Z2M addon via Supervisor API
    bashio::log.info "Auto-discovering Zigbee2MQTT..."

    # Known Z2M addon slugs
    Z2M_SLUGS="a0d7b954_zigbee2mqtt 45df7312_zigbee2mqtt core_zigbee2mqtt"

    for slug in ${Z2M_SLUGS}; do
        if bashio::addons.installed "${slug}"; then
            bashio::log.info "Found Z2M addon: ${slug}"

            # Get addon info from Supervisor API
            ADDON_INFO=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
                "http://supervisor/addons/${slug}/info" 2>/dev/null)

            if [ $? -eq 0 ] && [ -n "${ADDON_INFO}" ]; then
                # Get the addon's IP address on the hassio network
                ADDON_IP=$(echo "${ADDON_INFO}" | jq -r '.data.ip_address // empty' 2>/dev/null)

                if [ -n "${ADDON_IP}" ] && [ "${ADDON_IP}" != "null" ]; then
                    Z2M_HOST="${ADDON_IP}"
                    bashio::log.info "Z2M addon IP: ${ADDON_IP}"
                else
                    # Fallback: try hostname via hassio DNS
                    Z2M_HOST="${slug//_/-}"
                    bashio::log.info "Z2M addon IP not found, trying hostname: ${Z2M_HOST}"
                fi

                # Get the internal port (default 8099 for Z2M frontend)
                Z2M_PORT="8099"
                INTERNAL_PORT=$(echo "${ADDON_INFO}" | jq -r '.data.ingress_port // empty' 2>/dev/null)
                if [ -n "${INTERNAL_PORT}" ] && [ "${INTERNAL_PORT}" != "null" ] && [ "${INTERNAL_PORT}" != "0" ]; then
                    Z2M_PORT="${INTERNAL_PORT}"
                fi

                # Also check host-exposed port for logging
                FRONTEND_PORT=$(echo "${ADDON_INFO}" | jq -r '.data.network["8099/tcp"] // empty' 2>/dev/null)
                if [ -n "${FRONTEND_PORT}" ] && [ "${FRONTEND_PORT}" != "null" ]; then
                    bashio::log.info "Z2M frontend also on host port: ${FRONTEND_PORT}"
                fi
            else
                bashio::log.error "Failed to get addon info from Supervisor API"
                # Fallback: use the HA host IP with common Z2M port
                Z2M_HOST=$(bashio::network.ipv4_address | head -1 | cut -d'/' -f1)
                Z2M_PORT="8099"
                bashio::log.info "Fallback: trying HA host ${Z2M_HOST}:${Z2M_PORT}"
            fi

            bashio::log.info "Z2M internal endpoint: ${Z2M_HOST}:${Z2M_PORT}"
            break
        fi
    done

    # 3. Fallback: try common local addresses
    if [ -z "${Z2M_HOST}" ]; then
        bashio::log.warning "Z2M addon not found. Trying localhost:8099..."
        Z2M_HOST="localhost"
        Z2M_PORT="8099"
    fi
fi

bashio::log.info "Z2M WebSocket target: ws://${Z2M_HOST}:${Z2M_PORT}${Z2M_PATH}"

# ============================================
# Generate nginx config with WebSocket proxy
# ============================================
# The frontend connects to /ws which nginx proxies to Z2M's WebSocket
# This way the browser only needs to reach this addon, not Z2M directly

INGRESS_ENTRY=$(bashio::addon.ingress_entry)
bashio::log.info "Ingress entry: ${INGRESS_ENTRY}"

cat > /etc/nginx/http.d/default.conf << EOF
server {
    listen 8099;
    server_name _;

    root /var/www/z2m-lite;
    index index.html;

    # DNS resolver for Docker/hassio network
    resolver 127.0.0.11 valid=30s ipv6=off;

    # WebSocket proxy to Z2M
    set \$z2m_upstream http://${Z2M_HOST}:${Z2M_PORT}/api;
    location /z2m-ws {
        proxy_pass \$z2m_upstream;
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

# ============================================
# Patch frontend config
# ============================================
# Write a runtime config that the frontend reads
# The frontend will connect to /z2m-ws (proxied by nginx) instead of Z2M directly

cat > /var/www/z2m-lite/z2m-config.json << EOF
{
  "wsUrl": "ws://${Z2M_HOST}:${Z2M_PORT}/api",
  "wsProxy": true,
  "ingressPath": "${INGRESS_ENTRY}"
}
EOF

bashio::log.info "Starting nginx..."
exec nginx -g "daemon off;"
