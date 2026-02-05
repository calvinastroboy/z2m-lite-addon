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

            # Get the addon's web interface port
            # Z2M frontend runs inside the addon container
            # From another addon, we can reach it via the addon's hostname
            Z2M_HOST="${slug}"
            Z2M_PORT="8099"

            # Try to get the actual port from addon options
            ADDON_OPTIONS=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
                "http://supervisor/addons/${slug}/info" 2>/dev/null)

            if [ $? -eq 0 ] && [ -n "${ADDON_OPTIONS}" ]; then
                # Check if frontend is enabled and get port
                FRONTEND_PORT=$(echo "${ADDON_OPTIONS}" | jq -r '.data.network["8099/tcp"] // empty' 2>/dev/null)
                if [ -n "${FRONTEND_PORT}" ] && [ "${FRONTEND_PORT}" != "null" ]; then
                    bashio::log.info "Z2M frontend exposed on host port: ${FRONTEND_PORT}"
                fi

                # For internal Docker network, use the addon slug as hostname
                # and the internal port (8099 for Z2M frontend)
                INTERNAL_PORT=$(echo "${ADDON_OPTIONS}" | jq -r '.data.ingress_port // empty' 2>/dev/null)
                if [ -n "${INTERNAL_PORT}" ] && [ "${INTERNAL_PORT}" != "null" ]; then
                    Z2M_PORT="${INTERNAL_PORT}"
                fi
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

    # WebSocket proxy to Z2M
    location /z2m-ws {
        proxy_pass http://${Z2M_HOST}:${Z2M_PORT}/api;
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
