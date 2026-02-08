#!/bin/sh
#
# Renovación periódica de certificados Let's Encrypt.
# Ejecutar una vez al día: comprueba si faltan <15 días para expirar y renueva.
# Usa --webroot (HAProxy debe servir /.well-known/acme-challenge/).
#

set -e

CERT_DIR="${CERT_DIR:-/etc/ssl/certs}"
HAPROXY_CRTS_DIR="${HAPROXY_CRTS_DIR:-$CERT_DIR/haproxy-certs}"
LE_LIVE="${LE_LIVE:-/etc/letsencrypt/live}"
LE_WEBROOT="${LE_WEBROOT:-/var/lib/haproxy/acme-challenge}"
ENV_FILE="${ENV_FILE:-/usr/local/etc/haproxy/.env}"
CHECKEND_SECONDS=1296000
RELOAD_SCRIPT="/usr/local/bin/reload-config.sh"

get_ssl_type() {
    [ -f "$ENV_FILE" ] || return 1
    _t=$(grep -E '^SSL_CERT_TYPE=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs)
    [ "$_t" = "letsencrypt" ]
}

# Reconstruir haproxy-certs desde /etc/letsencrypt/live/
build_haproxy_certs_from_le() {
    _built=0
    if [ -d "$LE_LIVE" ]; then
        for _d in "$LE_LIVE"/*/; do
            [ -d "$_d" ] || continue
            _base=$(basename "$_d")
            _fc="$LE_LIVE/$_base/fullchain.pem"
            _pk="$LE_LIVE/$_base/privkey.pem"
            _fn="$(echo "$_base" | tr '.' '_').pem"
            _out="$HAPROXY_CRTS_DIR/$_fn"
            if [ -f "$_fc" ] && [ -f "$_pk" ]; then
                mkdir -p "$HAPROXY_CRTS_DIR"
                cat "$_fc" "$_pk" > "$_out"
                chmod 644 "$_out"
                _built=1
            fi
        done
    fi
    return $_built
}

# Comprobar si algún cert en haproxy-certs o /etc/letsencrypt expira en <15 días
needs_renewal() {
    if [ -d "$LE_LIVE" ]; then
        for _fc in "$LE_LIVE"/*/fullchain.pem; do
            [ -f "$_fc" ] || continue
            if ! openssl x509 -in "$_fc" -noout -checkend "$CHECKEND_SECONDS" 2>/dev/null; then
                return 0
            fi
        done
    fi
    return 1
}

main() {
    get_ssl_type || exit 0
    needs_renewal || exit 0

    echo "Certificate expiring in <15 days. Running certbot renew..."
    if certbot renew --webroot -w "$LE_WEBROOT" --quiet 2>/dev/null; then
        if build_haproxy_certs_from_le; then
            echo "Certificates renewed. Reloading HAProxy..."
            [ -x "$RELOAD_SCRIPT" ] && "$RELOAD_SCRIPT" 2>/dev/null || true
        fi
    fi
}

main "$@"
