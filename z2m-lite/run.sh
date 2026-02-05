#!/usr/bin/with-contenv bashio
# Z2M Lite Add-on Startup Script v1.0.7

bashio::log.info "Starting Z2M Lite Panel v1.0.7..."

# ============================================
# Auto-discover Zigbee2MQTT
# ============================================
Z2M_HOST=""
Z2M_PORT="8099"
Z2M_WS_PATH="/api"

# 1. Check user config first
if bashio::config.has_value "z2m_host"; then
    USER_HOST=$(bashio::config 'z2m_host')
    if [ -n "${USER_HOST}" ]; then
        Z2M_HOST="${USER_HOST}"
        Z2M_PORT=$(bashio::config 'z2m_port')
        bashio::log.info "Using manual config: ${Z2M_HOST}:${Z2M_PORT}"
    fi
fi

if [ -z "${Z2M_HOST}" ]; then
    bashio::log.info "Auto-discovering Zigbee2MQTT..."

    # Debug env
    bashio::log.info "SUPERVISOR_TOKEN set: $([ -n "${SUPERVISOR_TOKEN}" ] && echo "yes (${#SUPERVISOR_TOKEN} chars)" || echo "NO")"

    # ============================================
    # Strategy 1: Supervisor API (direct)
    # ============================================
    Z2M_SLUG=""

    # Try Supervisor with verbose error reporting
    SUPERVISOR_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        "http://supervisor/addons" 2>&1) || true
    HTTP_CODE=$(echo "${SUPERVISOR_RESP}" | tail -1)
    BODY=$(echo "${SUPERVISOR_RESP}" | sed '$d')

    bashio::log.info "Supervisor /addons response code: ${HTTP_CODE}"

    if [ "${HTTP_CODE}" = "200" ]; then
        Z2M_SLUG=$(echo "${BODY}" | jq -r '
            .data.addons[]?
            | select(.slug | test("zigbee2mqtt"))
            | .slug
        ' 2>/dev/null | head -1) || true
        bashio::log.info "Found Z2M slug from Supervisor: '${Z2M_SLUG}'"
    else
        bashio::log.warning "Supervisor API failed (HTTP ${HTTP_CODE})"
        bashio::log.info "Supervisor response: $(echo "${BODY}" | head -c 200)"
    fi

    # If we got the slug, get its hostname/IP
    if [ -n "${Z2M_SLUG}" ]; then
        ADDON_INFO=$(curl -sf -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            "http://supervisor/addons/${Z2M_SLUG}/info" 2>/dev/null) || true

        if [ -n "${ADDON_INFO}" ]; then
            ADDON_HOSTNAME=$(echo "${ADDON_INFO}" | jq -r '.data.hostname // ""' 2>/dev/null) || true
            ADDON_IP=$(echo "${ADDON_INFO}" | jq -r '.data.ip_address // ""' 2>/dev/null) || true
            ADDON_STATE=$(echo "${ADDON_INFO}" | jq -r '.data.state // ""' 2>/dev/null) || true
            bashio::log.info "Addon hostname: '${ADDON_HOSTNAME}', IP: '${ADDON_IP}', state: '${ADDON_STATE}'"

            # Prefer IP, then hostname
            if [ -n "${ADDON_IP}" ] && [ "${ADDON_IP}" != "null" ]; then
                Z2M_HOST="${ADDON_IP}"
            elif [ -n "${ADDON_HOSTNAME}" ] && [ "${ADDON_HOSTNAME}" != "null" ]; then
                Z2M_HOST="${ADDON_HOSTNAME}"
            fi
        fi
    fi

    # ============================================
    # Strategy 2: HA Core API - check Z2M integration state
    # ============================================
    if [ -z "${Z2M_HOST}" ]; then
        bashio::log.info "Trying HA Core API to find Z2M..."

        # Check if Z2M bridge entity exists (proves Z2M is running)
        BRIDGE_STATE=$(curl -sf -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            "http://supervisor/core/api/states/binary_sensor.zigbee2mqtt_bridge_connection_state" 2>/dev/null) || true

        if [ -n "${BRIDGE_STATE}" ]; then
            BRIDGE_OK=$(echo "${BRIDGE_STATE}" | jq -r '.state // ""' 2>/dev/null) || true
            bashio::log.info "Z2M bridge state: ${BRIDGE_OK}"
        else
            bashio::log.info "Could not reach HA Core API via Supervisor proxy"
        fi
    fi

    # ============================================
    # Strategy 3: DNS probe - try known Z2M addon hostnames
    # HA docs: hostname format is {REPO}-{SLUG} (hyphens, not underscores)
    # But Docker container name uses underscores
    # ============================================
    if [ -z "${Z2M_HOST}" ]; then
        bashio::log.info "Trying DNS-based discovery..."

        # Both underscore (Docker name) and hyphen (DNS hostname) variants
        for HOST in \
            "45df7312-zigbee2mqtt" \
            "45df7312_zigbee2mqtt" \
            "a0d7b954-zigbee2mqtt" \
            "a0d7b954_zigbee2mqtt" \
            "core-zigbee2mqtt" \
            "core_zigbee2mqtt" \
            "local-zigbee2mqtt" \
            "local_zigbee2mqtt"; do

            # Try DNS resolution
            if getent hosts "${HOST}" >/dev/null 2>&1; then
                RESOLVED_IP=$(getent hosts "${HOST}" | awk '{print $1}')
                bashio::log.info "DNS resolved ${HOST} → ${RESOLVED_IP}"
                Z2M_HOST="${RESOLVED_IP}"
                break
            fi
        done

        if [ -z "${Z2M_HOST}" ]; then
            bashio::log.info "No DNS entries found for known Z2M hostnames"
        fi
    fi

    # ============================================
    # Strategy 4: Network probe - scan hassio subnet for Z2M
    # Addons are on 172.30.33.0/24
    # ============================================
    if [ -z "${Z2M_HOST}" ]; then
        bashio::log.info "Scanning hassio addon subnet for Z2M..."

        # Get our own IP to know the subnet
        OWN_IP=$(hostname -i 2>/dev/null | awk '{print $1}') || true
        bashio::log.info "Own IP: ${OWN_IP}"

        # Scan 172.30.33.0/24 (addon network) for port 8099
        for i in $(seq 1 30); do
            TEST_IP="172.30.33.${i}"
            [ "${TEST_IP}" = "${OWN_IP}" ] && continue

            if nc -z -w1 "${TEST_IP}" 8099 2>/dev/null; then
                bashio::log.info "Found port 8099 open on ${TEST_IP}"

                # Verify it's Z2M by checking response
                RESP_BODY=$(curl -sf -m2 "http://${TEST_IP}:8099/" 2>/dev/null | head -c 500) || true

                if echo "${RESP_BODY}" | grep -qi "zigbee2mqtt" 2>/dev/null; then
                    Z2M_HOST="${TEST_IP}"
                    bashio::log.info "Confirmed Z2M at ${TEST_IP}:8099"
                    break
                elif echo "${RESP_BODY}" | grep -qi "<!doctype\|<!DOCTYPE" 2>/dev/null; then
                    bashio::log.info "${TEST_IP}:8099 serves HTML but not Z2M (skipping)"
                fi
            fi
        done

        # Also try port 8080 (alternate Z2M frontend port)
        if [ -z "${Z2M_HOST}" ]; then
            for i in $(seq 1 30); do
                TEST_IP="172.30.33.${i}"
                [ "${TEST_IP}" = "${OWN_IP}" ] && continue

                if nc -z -w1 "${TEST_IP}" 8080 2>/dev/null; then
                    RESP_BODY=$(curl -sf -m2 "http://${TEST_IP}:8080/" 2>/dev/null | head -c 500) || true
                    if echo "${RESP_BODY}" | grep -qi "zigbee2mqtt" 2>/dev/null; then
                        Z2M_HOST="${TEST_IP}"
                        Z2M_PORT="8080"
                        bashio::log.info "Found Z2M at ${TEST_IP}:8080"
                        break
                    fi
                fi
            done
        fi
    fi

    # ============================================
    # Strategy 5: MQTT service discovery
    # If Z2M is connected via MQTT, we can find it
    # ============================================
    if [ -z "${Z2M_HOST}" ]; then
        bashio::log.info "Trying MQTT service discovery..."

        MQTT_HOST=$(bashio::services mqtt "host" 2>/dev/null) || true
        MQTT_PORT=$(bashio::services mqtt "port" 2>/dev/null) || true

        if [ -n "${MQTT_HOST}" ]; then
            bashio::log.info "MQTT broker at: ${MQTT_HOST}:${MQTT_PORT}"
            # Can't directly find Z2M from MQTT, but this confirms the network is up
        fi
    fi

    # ============================================
    # Last resort
    # ============================================
    if [ -z "${Z2M_HOST}" ]; then
        bashio::log.error "==========================================="
        bashio::log.error "Could not auto-discover Zigbee2MQTT!"
        bashio::log.error "Please set z2m_host in the addon configuration."
        bashio::log.error "  Go to: Settings → Add-ons → Z2M Lite → Configuration"
        bashio::log.error "  Set z2m_host to your Z2M addon's hostname"
        bashio::log.error "  (e.g., 45df7312-zigbee2mqtt)"
        bashio::log.error "==========================================="
        Z2M_HOST="127.0.0.1"
    fi
fi

bashio::log.info "Z2M WebSocket target: ws://${Z2M_HOST}:${Z2M_PORT}${Z2M_WS_PATH}"

# ============================================
# Wait for Z2M to be reachable (skip if fallback)
# ============================================
if [ "${Z2M_HOST}" != "127.0.0.1" ]; then
    MAX_WAIT=30
    WAITED=0
    bashio::log.info "Verifying Z2M reachability..."
    while ! nc -z -w1 "${Z2M_HOST}" "${Z2M_PORT}" 2>/dev/null; do
        if [ $WAITED -ge $MAX_WAIT ]; then
            bashio::log.warning "Z2M not reachable after ${MAX_WAIT}s, starting anyway"
            break
        fi
        [ $((WAITED % 10)) -eq 0 ] && bashio::log.info "Waiting for Z2M... (${WAITED}s)"
        sleep 2
        WAITED=$((WAITED+2))
    done
    nc -z -w1 "${Z2M_HOST}" "${Z2M_PORT}" 2>/dev/null && \
        bashio::log.info "Z2M reachable at ${Z2M_HOST}:${Z2M_PORT}" || true
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

bashio::log.info "nginx upstream: ${Z2M_HOST}:${Z2M_PORT}"
bashio::log.info "Starting nginx..."
exec nginx -g "daemon off;"
