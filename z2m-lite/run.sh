#!/usr/bin/with-contenv bashio
# Z2M Lite Add-on Startup Script

bashio::log.info "Starting Z2M Lite Panel v1.0.4..."

# ============================================
# Auto-discover Zigbee2MQTT
# ============================================
Z2M_HOST=""
Z2M_PORT="8099"

# 1. Check user config first
USER_HOST=""
if bashio::config.has_value "z2m_host"; then
    USER_HOST=$(bashio::config 'z2m_host')
fi

if [ -n "${USER_HOST}" ]; then
    Z2M_HOST="${USER_HOST}"
    Z2M_PORT=$(bashio::config 'z2m_port')
    bashio::log.info "Using manual config: ${Z2M_HOST}:${Z2M_PORT}"
else
    # 2. Auto-discover via Supervisor API
    bashio::log.info "Auto-discovering Zigbee2MQTT..."

    # List all addons
    ADDONS_RAW=$(curl -sf -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        "http://supervisor/addons" 2>&1) || true

    if [ -n "${ADDONS_RAW}" ]; then
        bashio::log.info "Got addons list from Supervisor"

        # Find Z2M slug
        Z2M_SLUG=$(echo "${ADDONS_RAW}" | jq -r '
            .data.addons[]?
            | select(.slug | test("zigbee2mqtt"))
            | .slug
        ' 2>/dev/null | head -1) || true

        bashio::log.info "Z2M slug search result: '${Z2M_SLUG}'"

        if [ -n "${Z2M_SLUG}" ]; then
            bashio::log.info "Found Z2M addon: ${Z2M_SLUG}"

            # Get detailed info
            ADDON_INFO=$(curl -sf -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
                "http://supervisor/addons/${Z2M_SLUG}/info" 2>&1) || true

            if [ -n "${ADDON_INFO}" ]; then
                # Try IP address
                ADDON_IP=$(echo "${ADDON_INFO}" | jq -r '.data.ip_address // ""' 2>/dev/null) || true
                bashio::log.info "Addon IP from API: '${ADDON_IP}'"

                if [ -n "${ADDON_IP}" ] && [ "${ADDON_IP}" != "null" ] && [ "${ADDON_IP}" != "" ]; then
                    Z2M_HOST="${ADDON_IP}"
                else
                    # Try hostname format
                    Z2M_HOST="${Z2M_SLUG//_/-}"
                    bashio::log.info "No IP, trying hostname: ${Z2M_HOST}"
                fi

                # Log network info
                NETWORK_INFO=$(echo "${ADDON_INFO}" | jq -r '.data.network // {}' 2>/dev/null) || true
                bashio::log.info "Addon network: ${NETWORK_INFO}"
            else
                bashio::log.warning "Could not get addon info for ${Z2M_SLUG}"
            fi
        else
            bashio::log.warning "No zigbee2mqtt addon found in addon list"
        fi
    else
        bashio::log.warning "Could not reach Supervisor API"
    fi

    # 3. Fallback
    if [ -z "${Z2M_HOST}" ]; then
        GW_IP=$(ip route 2>/dev/null | grep default | awk '{print $3}' | head -1) || true
        if [ -n "${GW_IP}" ]; then
            Z2M_HOST="${GW_IP}"
            bashio::log.info "Fallback: gateway IP ${Z2M_HOST}:${Z2M_PORT}"
        else
            Z2M_HOST="172.30.32.1"
            bashio::log.warning "Final fallback: ${Z2M_HOST}:${Z2M_PORT}"
        fi
    fi
fi

bashio::log.info "Final Z2M target: ws://${Z2M_HOST}:${Z2M_PORT}/api"

# ============================================
# Generate nginx config
# ============================================
INGRESS_ENTRY=$(bashio::addon.ingress_entry)
bashio::log.info "Ingress entry: ${INGRESS_ENTRY}"

cat > /etc/nginx/http.d/default.conf << NGINXEOF
server {
    listen 8099;
    server_name _;

    root /var/www/z2m-lite;
    index index.html;

    resolver 127.0.0.11 valid=30s ipv6=off;

    set \$z2m_backend http://${Z2M_HOST}:${Z2M_PORT};

    location /z2m-ws {
        proxy_pass \$z2m_backend/api;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /assets/ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
NGINXEOF

cat > /var/www/z2m-lite/z2m-config.json << CFGEOF
{
  "wsProxy": true,
  "ingressPath": "${INGRESS_ENTRY}"
}
CFGEOF

bashio::log.info "Starting nginx..."
exec nginx -g "daemon off;"
