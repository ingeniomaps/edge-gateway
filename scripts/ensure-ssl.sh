#!/bin/sh
#
# Asegura que exista al menos un certificado SSL para HAProxy (entrypoint).
# Un cert por dominio base en certs/haproxy-certs/*.pem; HAProxy usa SNI con el directorio crt.
#
# - Si haproxy-certs/ tiene .pem: comprueba caducidad (aviso si alguno <30 días).
# - Si no pero hay conf/live/BASE/: construye haproxy-certs/BASE.pem para cada BASE.
# - Si no pero existe haproxy.pem (legacy): copia a haproxy-certs/legacy.pem.
# - Si no hay nada: letsencrypt|mkcert → /tmp/ssl_disable_https; selfsigned/vacío → selfsigned en haproxy-certs/.
#

set -e

CERT_DIR="${CERT_DIR:-/etc/ssl/certs}"
HAPROXY_CRTS_DIR="${HAPROXY_CRTS_DIR:-$CERT_DIR/haproxy-certs}"
# Legacy: ruta antigua de un único haproxy.pem (solo para migrar a haproxy-certs)
CONF_LIVE="${CONF_LIVE:-$CERT_DIR/conf/live}"
CERT_FILE_LEGACY="${CERT_FILE:-/etc/ssl/certs/haproxy.pem}"
ENV_FILE="${ENV_FILE:-/usr/local/etc/haproxy/.env}"
DISABLE_MARK="/tmp/ssl_disable_https"
CHECKEND_SECONDS=2592000

get_ssl_type() {
    [ -f "$ENV_FILE" ] || return 0
    grep -E '^SSL_CERT_TYPE=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs || true
}

# Construir haproxy-certs/BASE.pem desde conf/live/BASE/
build_cert_for_base() {
    _b="$1"
    _live="$CONF_LIVE/$_b"
    _fn="$(echo "$_b" | tr '.' '_').pem"
    _out="$HAPROXY_CRTS_DIR/$_fn"
    if [ -f "$_live/fullchain.pem" ] && [ -f "$_live/privkey.pem" ]; then
        mkdir -p "$HAPROXY_CRTS_DIR"
        cat "$_live/fullchain.pem" "$_live/privkey.pem" > "$_out"
        chmod 644 "$_out" 2>/dev/null || true
        return 0
    fi
    return 1
}

# 1) haproxy-certs/ con al menos un .pem
_first_pem=""
for _f in "$HAPROXY_CRTS_DIR"/*.pem 2>/dev/null; do
    [ -f "$_f" ] || continue
    _first_pem="$_f"
    break
done
if [ -n "$_first_pem" ]; then
    if openssl x509 -in "$_first_pem" -noout -checkend "$CHECKEND_SECONDS" 2>/dev/null; then
        echo "Certificate OK: $HAPROXY_CRTS_DIR (multi-dominio)"
        exit 0
    fi
    echo "WARNING: Certificate in $HAPROXY_CRTS_DIR expiring in less than 30 days. Run: make renew-cert"
    exit 0
fi

# 2) Construir haproxy-certs/ desde conf/live/BASE/ (todos los subdirs)
_built=0
if [ -d "$CONF_LIVE" ]; then
    for _d in "$CONF_LIVE"/*/; do
        [ -d "$_d" ] || continue
        _base=$(basename "$_d")
        if build_cert_for_base "$_base"; then
            _built=1
            _fn="$(echo "$_base" | tr '.' '_').pem"
            echo "Certificate built: $HAPROXY_CRTS_DIR/$_fn (from conf/live/$_base)"
        fi
    done
    if [ "$_built" = "1" ]; then
        exit 0
    fi
fi

# 3) Legacy: haproxy.pem → haproxy-certs/legacy.pem
if [ -f "$CERT_FILE_LEGACY" ]; then
    mkdir -p "$HAPROXY_CRTS_DIR"
    cp "$CERT_FILE_LEGACY" "$HAPROXY_CRTS_DIR/legacy.pem" 2>/dev/null && chmod 644 "$HAPROXY_CRTS_DIR/legacy.pem" 2>/dev/null || true
    if [ -f "$HAPROXY_CRTS_DIR/legacy.pem" ]; then
        echo "Certificate built from legacy haproxy.pem to $HAPROXY_CRTS_DIR/legacy.pem"
        exit 0
    fi
fi

# 4) No hay certificado
_ssl_type=$(get_ssl_type)
case "$_ssl_type" in
    letsencrypt|mkcert)
        echo "No certificate found. For $_ssl_type run: make setup-ssl (and mount ./certs). Disabling HTTPS."
        touch "$DISABLE_MARK"
        exit 0
        ;;
    *)
        if command -v openssl >/dev/null 2>&1; then
            _tmp="/tmp/ssl-certs"
            mkdir -p "$_tmp" "$HAPROXY_CRTS_DIR"
            if openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout "$_tmp/haproxy.key" -out "$_tmp/haproxy.crt" \
                -subj "/C=ES/ST=State/L=City/O=Organization/CN=localhost" 2>/dev/null; then
                cat "$_tmp/haproxy.crt" "$_tmp/haproxy.key" > "$HAPROXY_CRTS_DIR/selfsigned.pem" 2>/dev/null
                chmod 644 "$HAPROXY_CRTS_DIR/selfsigned.pem" 2>/dev/null || true
                echo "Self-signed certificate generated: $HAPROXY_CRTS_DIR/selfsigned.pem"
                exit 0
            fi
        fi
        echo "Cannot generate certificate (openssl not available). Disabling HTTPS."
        touch "$DISABLE_MARK"
        exit 0
        ;;
esac
