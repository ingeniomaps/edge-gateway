#!/bin/bash
#
# Utilidades comunes para scripts de edge-gateway
# Fuente: source "$SCRIPT_DIR/common.sh"
#

readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

get_project_dirs() {
    local script_path="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
    SCRIPT_DIR="$(cd "$(dirname "$script_path")" && pwd)"
    PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"
}

load_env_file() {
    local env_file="${1:-$ENV_FILE}"
    if [[ ! -f "$env_file" ]]; then
        echo -e "${RED}❌ No se encontró .env: $env_file${NC}" >&2
        return 1
    fi
    set -a
    source "$env_file" 2>/dev/null || { set +a; return 1; }
    set +a
    return 0
}

# Lista todos los FQDN de DNS_LIST y DNS_LIST_<key> (uno por línea)
extract_all_fqdns() {
    local env_file="${ENV_FILE:-}"
    [[ -n "$env_file" ]] && [[ -f "$env_file" ]] || return 0
    grep -E '^DNS_LIST(_[a-zA-Z0-9_]+)?=' "$env_file" 2>/dev/null | cut -d= -f2- | tr ',' '\n' | tr -d '"' | tr -d "'" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
}

# Dado un FQDN, devuelve el "dominio base" (últimas dos etiquetas: ejemplo.com, nunzio.dev)
# api.ejemplo.com -> ejemplo.com; nunzio.dev -> nunzio.dev
extract_base_domain() {
    local fqdn="$1"
    echo "$fqdn" | awk -F. '{if(NF>=2) print $(NF-1)"."$NF; else print $0}'
}

# Dominios base únicos a partir de todos los FQDN en .env (DNS_LIST, DNS_LIST_*)
extract_unique_bases() {
    local fqdn base
    while IFS= read -r fqdn; do
        [[ -n "$fqdn" ]] || continue
        base=$(extract_base_domain "$fqdn")
        [[ -n "$base" ]] && echo "$base"
    done < <(extract_all_fqdns) | sort -u
}

# FQDNs que pertenecen a un dominio base (igual o subdominio)
# Uso: fqdns_for_base "ejemplo.com" -> ejemplo.com, api.ejemplo.com, www.ejemplo.com (de los listados en .env)
fqdns_for_base() {
    local base="$1"
    local fqdn
    while IFS= read -r fqdn; do
        [[ -n "$fqdn" ]] || continue
        if [[ "$fqdn" == "$base" ]] || [[ "$fqdn" == *".$base" ]]; then
            echo "$fqdn"
        fi
    done < <(extract_all_fqdns)
}

# Obtener dominio: primer elemento de DNS_LIST, o primera DNS_LIST_<key>, o SITE_URL, o CERTBOT_DOMAIN
extract_domain() {
    local domain_raw="${1:-}"
    if [[ -z "$domain_raw" ]]; then
        if [[ -n "${DNS_LIST:-}" ]]; then
            domain_raw=$(echo "$DNS_LIST" | cut -d',' -f1 | xargs)
        fi
        if [[ -z "$domain_raw" ]] && [[ -f "${ENV_FILE:-}" ]]; then
            domain_raw=$(grep -E '^DNS_LIST_[a-zA-Z0-9_]+=' "${ENV_FILE}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | cut -d',' -f1 | xargs)
        fi
        domain_raw="${domain_raw:-${CERTBOT_DOMAIN:-${SITE_URL:-}}}"
    fi
    local domain
    domain=$(echo "$domain_raw" | sed 's|^https\?://*||' | sed 's|^http://*||')
    domain=$(echo "$domain" | sed 's|/.*||' | sed 's|?.*||' | sed 's|#.*||')
    echo "$domain" | xargs | tr -d ' '
}

get_env_value() {
    local key="$1"
    local env_file="${2:-$ENV_FILE}"
    if [[ -f "$env_file" ]]; then
        grep "^${key}=" "$env_file" 2>/dev/null | cut -d '=' -f2- | tr -d '"' | tr -d "'" | xargs
    fi
}

log_info()    { echo -e "${GREEN}ℹ️  $1${NC}" >&2; }
log_success() { echo -e "${GREEN}✅ $1${NC}" >&2; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}" >&2; }
log_error()   { echo -e "${RED}❌ $1${NC}" >&2; }
log_tip()     { echo -e "${BLUE}💡 $1${NC}" >&2; }
