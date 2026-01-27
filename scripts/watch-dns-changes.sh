#!/bin/sh
# Watch for DNS_LIST and DNS_LIST_* changes in .env and regenerate configs
# generate-dns-config.sh escribe en STATE_FILE las líneas DNS_LIST*; aquí comparamos ese bloque.

set -e

ENV_FILE="${ENV_FILE:-/usr/local/etc/haproxy/.env}"
STATE_FILE="${STATE_FILE:-/tmp/dns-config.state}"
GENERATOR_SCRIPT="/usr/local/bin/generate-dns-config.sh"

check_and_regenerate() {
    # Bloque actual: todas las DNS_LIST y DNS_LIST_*
    CURRENT_DNS=$(grep -E '^DNS_LIST(_[a-zA-Z0-9_]+)?=' "${ENV_FILE}" 2>/dev/null || echo "")

    # Estado anterior (el que escribe generate-dns-config)
    PREVIOUS_DNS=""
    if [ -f "${STATE_FILE}" ]; then
        PREVIOUS_DNS=$(grep -E '^DNS_LIST(_[a-zA-Z0-9_]+)?=' "${STATE_FILE}" 2>/dev/null || echo "")
    fi

    # Comparar y regenerar si cambió
    if [ "${CURRENT_DNS}" != "${PREVIOUS_DNS}" ]; then
        echo "DNS_LIST / DNS_LIST_* changed, regenerating configurations..."
        echo "Previous: ${PREVIOUS_DNS}"
        echo "Current:  ${CURRENT_DNS}"
        
        # Run generator
        "${GENERATOR_SCRIPT}"
        
        # Reload HAProxy if running
        if command -v haproxy >/dev/null 2>&1; then
            echo "Reloading HAProxy configuration..."
            haproxy -f /usr/local/etc/haproxy/haproxy.cfg -sf "$(pidof haproxy)" 2>/dev/null || true
        fi
        
        return 0
    else
        return 1
    fi
}

# Main
if [ "$1" = "--watch" ]; then
    # Watch mode (requires inotify-tools or similar)
    echo "Watching ${ENV_FILE} for changes..."
    while true; do
        if check_and_regenerate; then
            echo "Configuration updated at $(date)"
        fi
        sleep 5
    done
else
    # One-time check
    check_and_regenerate
fi
