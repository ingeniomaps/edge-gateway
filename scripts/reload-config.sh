#!/bin/sh
# Recarga la configuración de HAProxy sin reiniciar el contenedor (zero-downtime).
# 1) Regenera dns.d desde .env (generate-dns-config)
# 2) Reconstruye /tmp/haproxy.cfg (inyección ACL + backends, comentar https si no hay cert)
# 3) Valida y hace soft reload: haproxy -f /tmp/haproxy.cfg -sf $(pidof haproxy)
# No ejecuta ensure-ssl (los certs se gestionan con make setup-ssl / restart).

set -e

CONFIG_FILE="${HAPROXY_CONFIG:-/usr/local/etc/haproxy/haproxy.cfg}"
CONFIG_DIR="${CONFIG_DIR:-/usr/local/etc/haproxy/dns.d}"
ENV_FILE="${ENV_FILE:-/usr/local/etc/haproxy/.env}"
HAPROXY_CRTS_DIR="/etc/ssl/certs/haproxy-certs"
WORKING_CONFIG="/tmp/haproxy.cfg"

echo "=== HAProxy reload (regenerar config + soft reload) ==="

if [ ! -f "${ENV_FILE}" ]; then
    echo "Warning: ${ENV_FILE} not found. Rebuilding from base config only."
fi

# 1) Regenerar dns.d desde .env
if [ -f "${ENV_FILE}" ]; then
    /usr/local/bin/generate-dns-config.sh
fi

# 2) Reconstruir /tmp/haproxy.cfg (misma lógica que el entrypoint)
#    haproxy.cfg usa crt /etc/ssl/certs/haproxy-certs (directorio; un .pem por dominio base)
cp "${CONFIG_FILE}" "${WORKING_CONFIG}"

# Inyectar ACL DNS
if ls ${CONFIG_DIR}/*.acl 1>/dev/null 2>&1; then
    ls ${CONFIG_DIR}/*.acl 2>/dev/null | sort | xargs cat > /tmp/dns-acls.inject
    sed -i '/# __DNS_ACL_INCLUDE__/{ r /tmp/dns-acls.inject
    d
    }' "${WORKING_CONFIG}"
else
    sed -i 's|# __DNS_ACL_INCLUDE__|# (no dns acl)|' "${WORKING_CONFIG}"
fi

# Inyectar backends DNS
if ls ${CONFIG_DIR}/*.cfg 1>/dev/null 2>&1; then
    ls ${CONFIG_DIR}/*.cfg 2>/dev/null | sort | xargs cat > /tmp/dns-backends.inject
    sed -i '/^# __DNS_BACKEND_INCLUDE__$/{ r /tmp/dns-backends.inject
    d
    }' "${WORKING_CONFIG}"
else
    sed -i '/^# __DNS_BACKEND_INCLUDE__$/d' "${WORKING_CONFIG}"
fi

# Comentar https_frontend si no hay certificados (ssl_disable o haproxy-certs vacío)
if [ -f /tmp/ssl_disable_https ] || ! ls "${HAPROXY_CRTS_DIR}"/*.pem 1>/dev/null 2>&1; then
    rm -f /tmp/ssl_disable_https 2>/dev/null
    sed -i '/^frontend https_frontend/,/^frontend\|^backend\|^# Include\|^include\|^$/ {
        /^frontend https_frontend/ s/^/#/
        /^[^#]/ s/^/    #/
    }' "${WORKING_CONFIG}" 2>/dev/null || true
fi

# 3) Validar
if ! haproxy -c -f "${WORKING_CONFIG}"; then
    echo "ERROR: Configuración inválida. No se recarga. Corrige y vuelve a ejecutar make reload."
    exit 1
fi

# 4) Soft reload: -sf indica al proceso actual que cierre conexiones y salga; el nuevo toma el puerto.
# En Docker, si HAProxy es PID 1, el proceso al salir puede detener el contenedor; la política
# "restart" lo volverá a levantar. El nuevo haproxy se lanza en segundo plano para que este
# script (y make reload) termine; de lo contrario haproxy quedaría en primer plano y colgaría.
echo "Aplicando nueva configuración (soft reload)..."
if command -v nohup >/dev/null 2>&1; then
    nohup haproxy -f "${WORKING_CONFIG}" -sf $(pidof haproxy) </dev/null >/dev/null 2>&1 &
else
    haproxy -f "${WORKING_CONFIG}" -sf $(pidof haproxy) </dev/null >/dev/null 2>&1 &
fi
sleep 1
echo "Reload enviado. El nuevo HAProxy está en marcha."
