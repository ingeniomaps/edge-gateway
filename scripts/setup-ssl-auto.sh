#!/bin/bash
#
# Configuración SSL automática para edge-gateway (HAProxy).
# Un certificado por cada dominio base (cada base incluye el dominio y *.base).
# - Si ya hay certificados en haproxy-certs/: comprueba validez; si letsencrypt, renueva.
# - Si no: genera con mkcert o letsencrypt según SSL_CERT_TYPE, uno por base (DNS_LIST, DNS_LIST_*).
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

set -euo pipefail
get_project_dirs
cd "$PROJECT_DIR"

load_env_file || exit 1

SSL_CERT_TYPE="${SSL_CERT_TYPE:-}"

if [[ -z "$SSL_CERT_TYPE" ]]; then
    log_warning "SSL_CERT_TYPE está vacío. No se generarán certificados."
    log_tip "Configura SSL_CERT_TYPE=letsencrypt o SSL_CERT_TYPE=mkcert en .env"
    exit 0
fi

CERT_DIR="$PROJECT_DIR/certs"
HAPROXY_CRTS_DIR="$CERT_DIR/haproxy-certs"
LIVE_BASE="$CERT_DIR/conf/live"

# Construir haproxy-certs/BASE.pem desde conf/live/BASE/ (fullchain+privkey)
build_haproxy_cert_for_base() {
    local base="$1"
    local live="$LIVE_BASE/$base"
    local fn="${base//./_}.pem"
    local out="$HAPROXY_CRTS_DIR/$fn"
    if [[ -f "$live/fullchain.pem" ]] && [[ -f "$live/privkey.pem" ]]; then
        mkdir -p "$HAPROXY_CRTS_DIR"
        cat "$live/fullchain.pem" "$live/privkey.pem" > "$out"
        chmod 644 "$out" 2>/dev/null || true
        return 0
    fi
    return 1
}

# Reconstruir haproxy-certs/ desde todos los conf/live/BASE/
build_all_haproxy_certs() {
    mkdir -p "$HAPROXY_CRTS_DIR"
    local n=0
    for d in "$LIVE_BASE"/*/; do
        [[ -d "$d" ]] || continue
        d=$(basename "$d")
        if build_haproxy_cert_for_base "$d"; then
            ((n++)) || true
        fi
    done
    return $((n > 0 ? 0 : 1))
}

# Obtener bases únicos; si no hay en .env, usar extract_domain como única base
BASES=()
if mapfile -t _b < <(extract_unique_bases) && [[ ${#_b[@]} -gt 0 ]]; then
    BASES=("${_b[@]}")
else
    DOM=$(extract_domain)
    [[ -n "$DOM" ]] && BASES=("$(extract_base_domain "$DOM")")
fi

if [[ ${#BASES[@]} -eq 0 ]]; then
    log_error "No se pudo determinar ningún dominio (DNS_LIST, DNS_LIST_*, SITE_URL o CERTBOT_DOMAIN)"
    exit 1
fi

log_info "Comprobando SSL para ${#BASES[@]} dominio(s) base: ${BASES[*]} (Tipo: $SSL_CERT_TYPE)"

# --- Certificados ya existen (haproxy-certs/ con .pem) ---
if bash "$SCRIPT_DIR/check-ssl.sh" >/dev/null 2>&1; then
    log_success "Certificados SSL ya existen y son válidos (certs/haproxy-certs/)"

    if [[ "$SSL_CERT_TYPE" == "letsencrypt" ]]; then
        log_info "Comprobando renovación Let's Encrypt..."
        if bash "$SCRIPT_DIR/certbot.sh" renew; then
            build_all_haproxy_certs && log_success "certs/haproxy-certs/ actualizado"
        fi
    fi

    log_tip "Asegúrate de montar ./certs en HAProxy y reinicia: docker compose up -d haproxy"
    exit 0
fi

# --- No hay certificados: generar uno por base ---
log_warning "No se encontraron certificados SSL válidos"
mkdir -p "$CERT_DIR" "$HAPROXY_CRTS_DIR"

case "$SSL_CERT_TYPE" in
    letsencrypt)
        log_info "Generando certificados Let's Encrypt (uno por dominio base)..."

        for base in "${BASES[@]}"; do
            if [[ "$base" =~ \.(dev|local|localhost|test|example)$ ]] || [[ "$base" == "localhost" ]] || [[ "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                log_error "Let's Encrypt no sirve para $base (local o IP). Omitting. Usa mkcert."
                continue
            fi
            if bash "$SCRIPT_DIR/certbot.sh" generate "$base"; then
                build_haproxy_cert_for_base "$base" || true
            fi
        done
        if build_all_haproxy_certs; then
            log_success "SSL Let's Encrypt listo. Monta ./certs y reinicia HAProxy."
        else
            log_error "No se pudo generar ningún certificado Let's Encrypt"
            exit 1
        fi
        ;;

    mkcert)
        log_info "Generando certificados locales con mkcert (uno por dominio base)..."

        if ! command -v mkcert &>/dev/null; then
            log_error "mkcert no está instalado"
            log_tip "Instala: sudo apt install mkcert  # o https://github.com/FiloSottile/mkcert"
            exit 1
        fi

        for base in "${BASES[@]}"; do
            live="$LIVE_BASE/$base"
            mkdir -p "$live"
            if mkcert -install -cert-file "$live/fullchain.pem" -key-file "$live/privkey.pem" \
                "$base" "*.$base" 2>/dev/null; then
                build_haproxy_cert_for_base "$base"
                chmod 644 "$live/fullchain.pem" "$live/privkey.pem" 2>/dev/null || true
                log_success "Certificado mkcert para $base (+ *.$base)"
            else
                log_error "mkcert falló para $base"
            fi
        done
        if ls "$HAPROXY_CRTS_DIR"/*.pem 1>/dev/null 2>&1; then
            log_success "Certificados mkcert generados. Monta ./certs y reinicia HAProxy."
        else
            log_error "No se generó ningún certificado mkcert"
            exit 1
        fi
        ;;

    *)
        log_error "SSL_CERT_TYPE no válido: $SSL_CERT_TYPE (usa letsencrypt o mkcert)"
        exit 1
        ;;
esac
