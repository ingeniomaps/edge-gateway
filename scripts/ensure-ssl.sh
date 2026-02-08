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
if [ -d "$HAPROXY_CRTS_DIR" ]; then
    for _f in "$HAPROXY_CRTS_DIR"/*.pem; do
        [ -f "$_f" ] || continue
        _first_pem="$_f"
        break
    done
fi
if [ -n "$_first_pem" ]; then
    _ssl_t=$(get_ssl_type)
    _checkend="$CHECKEND_SECONDS"
    [ "$_ssl_t" = "letsencrypt" ] && _checkend=1296000
    if openssl x509 -in "$_first_pem" -noout -checkend "$_checkend" 2>/dev/null; then
        echo "Certificate OK: $HAPROXY_CRTS_DIR (multi-dominio)"
        exit 0
    fi
    [ "$_ssl_t" = "letsencrypt" ] || echo "WARNING: Certificate expiring in less than 30 days. Run: make renew-cert"
    [ "$_ssl_t" = "letsencrypt" ] || exit 0
fi

# 2) Construir haproxy-certs/ desde conf/live/BASE/ (todos los subdirs)
_built=0
if [ -d "$CONF_LIVE" ]; then
    for _d in "$CONF_LIVE"/*/; do
        [ -d "$_d" ] || [ -f "$_d" ] || continue
        _base=$(basename "$_d" 2>/dev/null || echo "")
        [ -n "$_base" ] || continue
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
    mkcert)
        # Generar certificados con mkcert (dentro del contenedor, según DNS_LIST del .env)
        if command -v mkcert >/dev/null 2>&1 && [ -f "$ENV_FILE" ]; then
            echo "SSL_CERT_TYPE=mkcert: generating certificates from DNS_LIST..."
            # Extraer dominios base únicos de DNS_LIST y DNS_LIST_*
            _bases=""
            for _line in $(grep -E '^DNS_LIST(_[a-zA-Z0-9_]+)?=' "$ENV_FILE" 2>/dev/null); do
                _val=$(echo "$_line" | cut -d= -f2- | tr ',' '\n' | tr -d '"' | tr -d "'" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$')
                for _fqdn in $_val; do
                    [ -n "$_fqdn" ] || continue
                    _base=$(echo "$_fqdn" | awk -F. '{if(NF>=2) print $(NF-1)"."$NF; else print $0}')
                    [ -n "$_base" ] && _bases="$_bases $_base"
                done
            done
            _bases=$(echo "$_bases" | tr ' ' '\n' | sort -u | grep -v '^$')
            if [ -n "$_bases" ]; then
                mkdir -p "$CONF_LIVE" "$HAPROXY_CRTS_DIR"
                # mkcert -install crea la CA (CAROOT si se monta el host mkcert CA, usa esa)
                mkcert -install 2>/dev/null || true
                _built=0
                for _base in $_bases; do
                    _live="$CONF_LIVE/$_base"
                    mkdir -p "$_live"
                    if mkcert -cert-file "$_live/fullchain.pem" -key-file "$_live/privkey.pem" "$_base" "*.$_base" 2>/dev/null; then
                        if build_cert_for_base "$_base"; then
                            _built=1
                            _fn="$(echo "$_base" | tr '.' '_').pem"
                            echo "Certificate generated: $HAPROXY_CRTS_DIR/$_fn (mkcert for $_base + *.$_base)"
                        fi
                    fi
                done
                [ "$_built" = "1" ] && exit 0
            fi
        fi
        echo "No certificate generated (mkcert failed or no DNS_LIST). Disabling HTTPS."
        touch "$DISABLE_MARK"
        exit 0
        ;;
    letsencrypt)
        # Generar o renovar certificados Let's Encrypt (dentro del contenedor)
        # Requiere CERTBOT_EMAIL en .env. Dominios desde DNS_LIST. Renovar si <15 días.
        _email=""
        [ -f "$ENV_FILE" ] && _email=$(grep -E '^CERTBOT_EMAIL=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs)
        if [ -z "$_email" ]; then
            echo "CERTBOT_EMAIL required for letsencrypt. Disabling HTTPS."
            touch "$DISABLE_MARK"
            exit 0
        fi
        LE_LIVE="/etc/letsencrypt/live"
        LE_WEBROOT="/var/lib/haproxy/acme-challenge"
        CHECKEND_15D=1296000

        # Extraer bases y FQDNs de DNS_LIST
        _bases=""
        for _line in $(grep -E '^DNS_LIST(_[a-zA-Z0-9_]+)?=' "$ENV_FILE" 2>/dev/null); do
            _val=$(echo "$_line" | cut -d= -f2- | tr ',' '\n' | tr -d '"' | tr -d "'" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$')
            for _fqdn in $_val; do
                [ -n "$_fqdn" ] || continue
                _base=$(echo "$_fqdn" | awk -F. '{if(NF>=2) print $(NF-1)"."$NF; else print $0}')
                [ -n "$_base" ] && _bases="$_bases $_base"
            done
        done
        _bases=$(echo "$_bases" | tr ' ' '\n' | sort -u | grep -v '^$')
        [ -z "$_bases" ] && echo "No DNS_LIST for letsencrypt. Disabling HTTPS." && touch "$DISABLE_MARK" && exit 0

        if command -v certbot >/dev/null 2>&1; then
            mkdir -p "$LE_WEBROOT"
            _built=0

            # Si no hay certs LE: crear con --standalone (puerto 80 libre, HAProxy aún no arrancó)
            if ! ls "$LE_LIVE"/*/fullchain.pem 1>/dev/null 2>&1; then
                echo "SSL_CERT_TYPE=letsencrypt: generating certificates (standalone)..."
                for _base in $_bases; do
                    # Recoger FQDNs de este base (sin wildcard; LE HTTP-01 no soporta *.dominio)
                    _domains="-d $_base"
                    for _line in $(grep -E '^DNS_LIST(_[a-zA-Z0-9_]+)?=' "$ENV_FILE" 2>/dev/null); do
                        _val=$(echo "$_line" | cut -d= -f2- | tr ',' '\n' | tr -d '"' | tr -d "'" | xargs)
                        for _fqdn in $_val; do
                            case "$_fqdn" in
                                "$_base"|*".$_base") _domains="$_domains -d $_fqdn";;
                            esac
                        done
                    done
                    _domains=$(echo "$_domains" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')
                    if certbot certonly --standalone --non-interactive --agree-tos --email "$_email" \
                        --logs-dir /tmp --config-dir /etc/letsencrypt --work-dir /tmp \
                        $_domains 2>/dev/null; then
                        _built=1
                    fi
                done
            else
                # Hay certs: comprobar si <15 días para expirar
                _needs_renew=0
                for _fc in "$LE_LIVE"/*/fullchain.pem; do
                    [ -f "$_fc" ] || continue
                    openssl x509 -in "$_fc" -noout -checkend "$CHECKEND_15D" 2>/dev/null || _needs_renew=1
                done
                if [ "$_needs_renew" = "1" ]; then
                    echo "Certificate expiring in <15 days. Renewing (standalone)..."
                    certbot renew --standalone --non-interactive --logs-dir /tmp --config-dir /etc/letsencrypt --work-dir /tmp 2>/dev/null || true
                fi
                _built=1
            fi

            # Reconstruir haproxy-certs desde /etc/letsencrypt/live/
            if [ -d "$LE_LIVE" ]; then
                for _d in "$LE_LIVE"/*/; do
                    [ -d "$_d" ] || continue
                    _base=$(basename "$_d")
                    _fc="$LE_LIVE/$_base/fullchain.pem"
                    _pk="$LE_LIVE/$_base/privkey.pem"
                    if [ -f "$_fc" ] && [ -f "$_pk" ]; then
                        mkdir -p "$HAPROXY_CRTS_DIR"
                        _fn="$(echo "$_base" | tr '.' '_').pem"
                        cat "$_fc" "$_pk" > "$HAPROXY_CRTS_DIR/$_fn"
                        chmod 644 "$HAPROXY_CRTS_DIR/$_fn"
                        _built=1
                        echo "Certificate built: $HAPROXY_CRTS_DIR/$_fn (from Let's Encrypt)"
                    fi
                done
            fi
            [ "$_built" = "1" ] && exit 0
        fi
        echo "Could not generate Let's Encrypt certificates. Disabling HTTPS."
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
