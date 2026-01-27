#!/bin/bash
#
# Let's Encrypt con Certbot: generar y renovar certificados (uno por dominio base).
# Usa --standalone (requiere liberar puerto 80: se para HAProxy durante la operación).
# generate [base]: genera cert para base y todos los FQDN de .env que cuelgan de ese base (-d base -d fqdn1 ...).
# renew: renueva todos y reconstruye certs/haproxy-certs/ desde conf/live/.
# Para mkcert usa setup-ssl-auto.sh con SSL_CERT_TYPE=mkcert.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

set -euo pipefail
get_project_dirs
cd "$PROJECT_DIR"

COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
load_env_file 2>/dev/null || true

CERT_DIR="$PROJECT_DIR/certs"
HAPROXY_CRTS_DIR="$CERT_DIR/haproxy-certs"
LIVE_BASE="$CERT_DIR/conf/live"

ACTION="${1:-}"
BASE_ARG="${2:-}"
EMAIL="${CERTBOT_EMAIL:-}"

if [[ -z "$ACTION" ]]; then
    log_error "Uso: $0 [generate|renew] [dominio_base]"
    log_tip "  generate: sin args usa bases de DNS_LIST/DNS_LIST_*; con arg genera solo ese base."
    exit 1
fi

if [[ -z "$EMAIL" ]]; then
    log_error "Configura CERTBOT_EMAIL en .env"
    exit 1
fi

# Construir haproxy-certs/BASE.pem desde conf/live/BASE/
build_haproxy_cert_for_base() {
    local base="$1"
    local live="$LIVE_BASE/$base"
    local fn="${base//./_}.pem"
    local out="$HAPROXY_CRTS_DIR/$fn"
    if [[ -f "$live/fullchain.pem" ]] && [[ -f "$live/privkey.pem" ]]; then
        mkdir -p "$HAPROXY_CRTS_DIR"
        cat "$live/fullchain.pem" "$live/privkey.pem" > "$out"
        chmod 644 "$out" 2>/dev/null || true
        log_success "Generado $out (base: $base)"
        return 0
    fi
    return 1
}

build_all_haproxy_certs() {
    mkdir -p "$HAPROXY_CRTS_DIR"
    local n=0
    for d in "$LIVE_BASE"/*/; do
        [[ -d "$d" ]] || continue
        d=$(basename "$d")
        build_haproxy_cert_for_base "$d" && ((n++)) || true
    done
    return $((n > 0 ? 0 : 1))
}

if [[ "$ACTION" == "generate" ]]; then
    if [[ -n "$BASE_ARG" ]]; then
        BASES=("$BASE_ARG")
    else
        BASES=()
        if mapfile -t _b < <(extract_unique_bases) && [[ ${#_b[@]} -gt 0 ]]; then
            BASES=("${_b[@]}")
        else
            DOM=$(extract_domain)
            [[ -n "$DOM" ]] && BASES=("$(extract_base_domain "$DOM")")
        fi
    fi

    if [[ ${#BASES[@]} -eq 0 ]]; then
        log_error "Indica el dominio base o configura DNS_LIST/DNS_LIST_*/CERTBOT_DOMAIN/SITE_URL en .env"
        exit 1
    fi

    mkdir -p "$CERT_DIR/conf"
    docker compose -f "$COMPOSE_FILE" stop haproxy 2>/dev/null || true
    sleep 2

    for base in "${BASES[@]}"; do
        FQDNS=()
        while IFS= read -r f; do [[ -n "$f" ]] && FQDNS+=("$f"); done < <(fqdns_for_base "$base")
        [[ ${#FQDNS[@]} -eq 0 ]] && FQDNS=("$base")
        D_OPTS=()
        for f in "${FQDNS[@]}"; do
            D_OPTS+=(-d "$f")
        done
        log_info "Generando Let's Encrypt para $base (${#D_OPTS[@]} nombres: ${FQDNS[*]}) (standalone, puerto 80)..."

        if docker compose -f "$COMPOSE_FILE" --profile cert run --rm -p 80:80 certbot \
            certonly --standalone \
            "${D_OPTS[@]}" \
            --email "$EMAIL" \
            --agree-tos --no-eff-email \
            --logs-dir /tmp --config-dir /etc/letsencrypt --work-dir /tmp; then
            build_haproxy_cert_for_base "$base" || log_warning "No se pudo crear cert en haproxy-certs para $base"
        else
            log_error "Certbot falló para $base"
        fi
    done

    docker compose -f "$COMPOSE_FILE" start haproxy 2>/dev/null || true
    log_success "Proceso de generación finalizado. Reinicia si hace falta: docker compose up -d haproxy"

elif [[ "$ACTION" == "renew" ]]; then
    log_info "Renovando certificados Let's Encrypt (standalone, puerto 80)..."

    docker compose -f "$COMPOSE_FILE" stop haproxy 2>/dev/null || true
    sleep 2

    if docker compose -f "$COMPOSE_FILE" --profile cert run --rm -p 80:80 certbot renew; then
        build_all_haproxy_certs || log_warning "No se pudo reconstruir haproxy-certs desde conf/live"
    else
        log_warning "Renovación terminada con avisos o sin cambios"
    fi

    docker compose -f "$COMPOSE_FILE" start haproxy 2>/dev/null || true
    log_success "Proceso de renovación finalizado"

else
    log_error "Acción no válida: $ACTION (use generate o renew)"
    exit 1
fi
