#!/bin/sh
# HAProxy entrypoint: ensure-ssl, DNS, validación y arranque.

set -e

CONFIG_FILE="${HAPROXY_CONFIG:-/usr/local/etc/haproxy/haproxy.cfg}"
CONFIG_DIR="${CONFIG_DIR:-/usr/local/etc/haproxy/dns.d}"
ENV_FILE="${ENV_FILE:-/usr/local/etc/haproxy/.env}"
HAPROXY_CRTS_DIR="/etc/ssl/certs/haproxy-certs"
WORKING_CONFIG="/tmp/haproxy.cfg"

echo "=== HAProxy Entrypoint ==="

mkdir -p /run/haproxy /var/lib/haproxy 2>/dev/null || true

# 1) SSL: ensure-ssl valida/crea certs en haproxy-certs/ (un .pem por dominio base) o marca /tmp/ssl_disable_https
/usr/local/bin/ensure-ssl.sh

echo "Starting DNS configuration generation..."

# 2) DNS: generar configs desde .env
if [ -f "${ENV_FILE}" ]; then
    /usr/local/bin/generate-dns-config.sh

    cp "${CONFIG_FILE}" "${WORKING_CONFIG}" 2>/dev/null || WORKING_CONFIG="${CONFIG_FILE}"

    # Inject DNS ACLs into https_frontend (HAProxy does NOT allow 'include' inside frontend/backend)
    if ls ${CONFIG_DIR}/*.acl 1>/dev/null 2>&1; then
        ls ${CONFIG_DIR}/*.acl 2>/dev/null | sort | xargs cat > /tmp/dns-acls.inject
        sed -i '/# __DNS_ACL_INCLUDE__/{ r /tmp/dns-acls.inject
        d
        }' "${WORKING_CONFIG}"
    else
        sed -i 's|# __DNS_ACL_INCLUDE__|# (no dns acl)|' "${WORKING_CONFIG}"
    fi

    # Inject DNS backends (HAProxy needs backend before use_backend; include/glob can fail, so we inject content)
    if ls ${CONFIG_DIR}/*.cfg 1>/dev/null 2>&1; then
        ls ${CONFIG_DIR}/*.cfg 2>/dev/null | sort | xargs cat > /tmp/dns-backends.inject
        sed -i '/^# __DNS_BACKEND_INCLUDE__$/{ r /tmp/dns-backends.inject
        d
        }' "${WORKING_CONFIG}"
    else
        sed -i '/^# __DNS_BACKEND_INCLUDE__$/d' "${WORKING_CONFIG}"
    fi

    # Deshabilitar HTTPS si ensure-ssl marcó ssl_disable o no hay .pem en haproxy-certs
    if [ -f /tmp/ssl_disable_https ] || ! ls "${HAPROXY_CRTS_DIR}"/*.pem 1>/dev/null 2>&1; then
        rm -f /tmp/ssl_disable_https 2>/dev/null
        echo "Warning: Certificate not found or disabled, commenting out HTTPS frontend..."
        sed -i '/^frontend https_frontend/,/^backend unknown_host/ {
            /^backend unknown_host$/b
            /^frontend https_frontend/ s/^/#/
            /^[^#]/ s/^/    #/
        }' "${WORKING_CONFIG}" 2>/dev/null || true
    fi

    CONFIG_FILE="${WORKING_CONFIG}"
else
    echo "Warning: ${ENV_FILE} not found, skipping DNS configuration generation"
    if [ -f /tmp/ssl_disable_https ] || ! ls "${HAPROXY_CRTS_DIR}"/*.pem 1>/dev/null 2>&1; then
        rm -f /tmp/ssl_disable_https 2>/dev/null
        cp "${CONFIG_FILE}" "${WORKING_CONFIG}" 2>/dev/null || WORKING_CONFIG="${CONFIG_FILE}"
        sed -i '/^frontend https_frontend/,/^backend unknown_host/ {
            /^backend unknown_host$/b
            /^frontend https_frontend/ s/^/#/
            /^[^#]/ s/^/    #/
        }' "${WORKING_CONFIG}" 2>/dev/null || true
        CONFIG_FILE="${WORKING_CONFIG}"
    fi
fi

echo "Validating HAProxy configuration..."
if ! haproxy -c -f "${CONFIG_FILE}"; then
    echo "ERROR: HAProxy configuration validation failed!"
    exit 1
fi

echo "Configuration validated successfully"

# Let's Encrypt: arrancar httpd para ACME challenge y proceso de renovación diaria
_ssl_type=""
[ -f "${ENV_FILE}" ] && _ssl_type=$(grep -E '^SSL_CERT_TYPE=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs)
if [ "$_ssl_type" = "letsencrypt" ]; then
    mkdir -p /var/lib/haproxy/acme-challenge/.well-known/acme-challenge
    busybox httpd -p 54321 -h /var/lib/haproxy/acme-challenge -f &
    ( while true; do sleep 86400; /usr/local/bin/renew-ssl.sh; done ) &
fi

echo "Starting HAProxy..."

FINAL_CONFIG="${WORKING_CONFIG}"
if [ ! -f "${FINAL_CONFIG}" ] || [ "${FINAL_CONFIG}" = "${CONFIG_FILE}" ]; then
    FINAL_CONFIG="${CONFIG_FILE}"
fi

exec haproxy -f "${FINAL_CONFIG}"
