#!/bin/bash
#
# Verifica si existen certificados SSL válidos para HAProxy.
# Comprueba certs/haproxy-certs/*.pem (un .pem por dominio base), haproxy.pem (legacy) o conf/live/BASE/.
# Retorna 0 si existen y no están por expirar en 24h, 1 en caso contrario.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

set -euo pipefail
get_project_dirs
cd "$PROJECT_DIR"

load_env_file 2>/dev/null || true

CERT_DIR="$PROJECT_DIR/certs"
HAPROXY_CRTS_DIR="$CERT_DIR/haproxy-certs"
HAPROXY_PEM="$CERT_DIR/haproxy.pem"
LIVE_BASE="$CERT_DIR/conf/live"

# 1) haproxy-certs/*.pem (prioridad): comprobar el primero que sea válido
for _p in "$HAPROXY_CRTS_DIR"/*.pem 2>/dev/null; do
    [[ -f "$_p" ]] || continue
    if openssl x509 -in "$_p" -noout -checkend 86400 >/dev/null 2>&1; then
        log_success "Certificados SSL válidos en $HAPROXY_CRTS_DIR (multi-dominio)"
        exit 0
    fi
done
if ls "$HAPROXY_CRTS_DIR"/*.pem 1>/dev/null 2>&1; then
    log_warning "Certificados en $HAPROXY_CRTS_DIR expirados o por expirar en 24h"
    exit 1
fi

# 2) Legacy haproxy.pem
if [[ -f "$HAPROXY_PEM" ]]; then
    if openssl x509 -in "$HAPROXY_PEM" -noout -checkend 86400 >/dev/null 2>&1; then
        log_success "Certificado SSL válido (legacy): $HAPROXY_PEM"
        exit 0
    fi
    log_warning "Certificado en $HAPROXY_PEM expirado o por expirar en 24h"
    exit 1
fi

# 3) conf/live/BASE/ (certbot o mkcert sin haber construido haproxy-certs aún)
if [[ -d "$LIVE_BASE" ]]; then
    for _d in "$LIVE_BASE"/*/; do
        [[ -d "$_d" ]] || continue
        _f="${_d}fullchain.pem"
        if [[ -f "$_f" ]] && openssl x509 -in "$_f" -noout -checkend 86400 >/dev/null 2>&1; then
            log_success "Certificados en conf/live (válidos); ejecuta make setup-ssl para construir haproxy-certs"
            exit 0
        fi
    done
fi

log_error "No se encontraron certificados SSL (certs/haproxy-certs, haproxy.pem o conf/live)"
exit 1
