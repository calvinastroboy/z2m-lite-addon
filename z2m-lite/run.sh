#!/usr/bin/with-contenv bashio
# Z2M Lite Add-on Startup Script

bashio::log.info "Starting Z2M Lite Panel v1.0.6..."

# ============================================
# Auto-discover Zigbee2MQTT
# ============================================
Z2M_HOST=""
Z2M_PORT="8099"
Z2M_WS_PATH="/api"

# 1. Check user config first
if bashio::config.has_value "z2m_host"; then
    Z2M_HOST=$(bashio::config 'z2m_host')
    Z2M_PORT=$(bashio::config 'z2m_port')
    bashio::log.info "Using manual config: ${Z2M_HOST}:${Z2M_PORT}"
fi

if [ -z "${Z2M_HOST}" ]; then
    # 2. Auto-discover via Supervisor API
    bashio::log.info "Auto-discovering Zigbee2MQTT..."
    
    # Debug: check if SUPERVISOR_TOKEN is available
    if [ -n "${SUPERVISOR_TOKEN}" ]; then
        bashio::log.info "SUPERVISOR_TOKEN is set (length: ${#SUPERVISOR_TOKEN})"
    else
        bashio::log.warning "SUPERVISOR_TOKEN is NOT set!"
    fi

    # Try bashio API first (more reliable than raw curl)
    Z2M_SLUG=""
    if bashio::supervisor.ping 2>/dev/null; then
        bashio::log.info "Supervisor is reachable via bashio"
        
        # Get addon list via bashio
        ADDONS_RAW=$(bashio::api.supervisor GET /addons false 2>/dev/null) || true
        
        if [ -n "${ADDONS_RAW}" ]; then
            Z2M_SLUG=$(echo "${ADDONS_RAW}" | jq -r '
                .addons[]?
                | select(.slug | test("zigbee2mqtt"))
                | .slug
            ' 2>/dev/null | head -1) || true
        fi
    else
        bashio::log.warning "Supervisor not reachable via bashio, trying curl..."
        
        # Fallback to curl
        ADDONS_RAW=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            "http://supervisor/addons" 2>/dev/null) || true
        
        if [ -n "${ADDONS_RAW}" ]; then
            # Log response for debugging
            RESULT=$(echo "${ADDONS_RAW}" | jq -r '.result // "unknown"' 2>/dev/null) || true
            bashio::log.info "Supervisor curl response result: ${RESULT}"
            
            Z2M_SLUG=$(echo "${ADDONS_RAW}" | jq -r '
                .data.addons[]?
                | select(.slug | test("zigbee2mqtt"))
                | .slug
            ' 2>/dev/null | head -1) || true
        else
            bashio::log.warning "Supervisor API returned empty response"
        fi
    fi

    bashio::log.info "Z2M slug: '${Z2M_SLUG}'"

    if [ -n "${Z2M_SLUG}" ]; then
        bashio::log.info "Found Z2M addon: ${Z2M_SLUG}"
        
        # Use slug directly as Docker internal hostname
        Z2M_HOST="${Z2M_SLUG}"
        
        # Also try to get IP from addon info
        ADDON_INFO=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            "http://supervisor/addons/${Z2M_SLUG}/info" 2>/dev/null) || true
        
        if [ -n "${ADDON_INFO}" ]; then
            ADDON_IP=$(echo "${ADDON_INFO}" | jq -r '.data.ip_address // ""' 2>/dev/null) || true
            ADDON_STATE=$(echo "${ADDON_INFO}" | jq -r '.data.state // ""' 2>/dev/null) || true
            bashio::log.info "Addon state: ${ADDON_STATE}, IP: ${ADDON_IP}"
            
            if [ -n "${ADDON_IP}" ] && [ "${ADDON_IP}" != "null" ] && [ "${ADDON_IP}" != "" ]; then
                Z2M_HOST="${ADDON_IP}"
                bashio::log.info "Using addon IP: ${Z2M_HOST}"
            fi
        fi
    fi

    # 3. DNS-based fallback: try known Z2M addon hostnames
    if [ -z "${Z2M_HOST}" ]; then
        bashio::log.info "Trying DNS-based discovery..."
        for SLUG in "45df7312_zigbee2mqtt" "a0d7b954_zigbee2mqtt" "core_zigbee2mqtt"; do
            if getent hosts "${SLUG}" >/dev/null 2>&1; then
                Z2M_HOST="${SLUG}"
                bashio::log.info "Found ${SLUG} via DNS"
                break
            else
                bashio::log.info "DNS lookup failed for ${SLUG}"
            fi
        done
    fi

    # 4. Network scan fallback: try to find Z2M on common IPs
    if [ -z "${Z2M_HOST}" ]; then
        bashio::log.info "Trying network scan..."
        # In hassio network, addons are on 172.30.33.x
        for IP in $(seq 1 20); do
            TEST_IP="172.30.33.${IP}"
            if nc -z -w1 "${TEST_IP}" 8099 2>/dev/null; then
                # Verify it's actually Z2M (check for WS upgrade)
                RESP=$(curl -sf -m2 "${TEST_IP}:8099/" 2>/dev/null | head -1) || true
                if echo "${RESP}" | grep -qi "zigbee2mqtt\|<!doctype" 2>/dev/null; then
                    Z2M_HOST="${TEST_IP}"
                    bashio::log.info "Found Z2M at ${TEST_IP}:8099 via network scan"
                    break
                fi
            fi
        done
    fi

    # 5. Last resort
    if [ -z "${Z2M_HOST}" ]; then
        bashio::log.error "Could not find Zigbee2MQTT! Please set z2m_host in addon config."
        bashio::log.error "Common values: 'a0d7b954_zigbee2mqtt' or '45df7312_zigbee2mqtt'"
        # Still start nginx to serve the UI (will show connection error)
        Z2M_HOST="127.0.0.1"
    fi
fi

bashio::log.info "Z2M WebSocket target: ws://${Z2M_HOST}:${Z2M_PORT}${Z2M_WS_PATH}"

# ============================================
# Wait for Z2M to be reachable
# ============================================
if [ "${Z2M_HOST}" != "127.0.0.1" ]; then
    MAX_WAIT=60
    WAITED=0
    bashio::log.info "Checking Z2M reachability at ${Z2M_HOST}:${Z2M_PORT}..."
    while ! nc -z -w1 "${Z2M_HOST}" "${Z2M_PORT}" 2>/dev/null; do
        if [ $WAITED -ge $MAX_WAIT ]; then
            bashio::log.warning "Z2M not reachable after ${MAX_WAIT}s, starting nginx anyway"
            break
        fi
        if [ $((WAITED % 10)) -eq 0 ]; then
            bashio::log.info "Waiting for Z2M... (${WAITED}/${MAX_WAIT}s)"
        fi
        sleep 2
        WAITED=$((WAITED+2))
    done
    if nc -z -w1 "${Z2M_HOST}" "${Z2M_PORT}" 2>/dev/null; then
        bashio::log.info "Z2M is reachable at ${Z2M_HOST}:${Z2M_PORT}!"
    fi
fi

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
        proxy_pass \$z2m_backend${Z2M_WS_PATH};
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
  "ingressPath": "${INGRESS_ENTRY}",
  "z2mHost": "${Z2M_HOST}",
  "z2mPort": "${Z2M_PORT}"
}
CFGEOF

bashio::log.info "Generated nginx config with upstream: ${Z2M_HOST}:${Z2M_PORT}"
bashio::log.info "Starting nginx..."
exec nginx -g "daemon off;"
