#!/bin/sh
# Script to generate HAProxy DNS configuration files from .env
# Siempre regenera desde templates (template y DNS_LIST/DNS_TEMPLATE_* son la fuente de verdad):
#   - dns.d/<id>.acl: acl + use_backend (incluido en https_frontend)
#   - dns.d/<id>.cfg: backend (desde el template asignado vía DNS_TEMPLATE o DNS_TEMPLATE_<key>)
# <id> = DNS con puntos sustituidos por _ (ej. nunzio.dev -> nunzio_dev)

set -e

ENV_FILE="${ENV_FILE:-/usr/local/etc/haproxy/.env}"
CONFIG_DIR="${CONFIG_DIR:-/usr/local/etc/haproxy/dns.d}"
TEMPLATE_DIR="${TEMPLATE_DIR:-/usr/local/etc/haproxy/templates}"
STATE_FILE="${STATE_FILE:-/tmp/dns-config.state}"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${TEMPLATE_DIR}"

# Normalized for filenames and HAProxy identifiers (dots -> underscores)
normalize_id() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9.-]/_/g' | tr '.' '_'
}

generate_config() {
    local dns_name="$1"
    local template_filename="${2:-dns-backend.tmpl}"
    local id
    id=$(normalize_id "$dns_name")
    
    # .acl: siempre regenerar (determinista para este dominio)
    {
        echo "    acl is_${id} hdr(host) -i ${dns_name}"
        echo "    use_backend backend_${id} if is_${id}"
    } > "${CONFIG_DIR}/${id}.acl"
    echo "Updated: ${CONFIG_DIR}/${id}.acl for DNS: ${dns_name}"
    
    # .cfg: siempre regenerar desde el template (template y DNS_LIST/DNS_TEMPLATE_* son la fuente de verdad)
    local backend_tmpl="${TEMPLATE_DIR}/${template_filename}"
    [ -f "${backend_tmpl}" ] || backend_tmpl="${TEMPLATE_DIR}/dns-backend.tmpl"
    if [ -f "${backend_tmpl}" ]; then
        sed -e "s|\${DNS_NAME}|${dns_name}|g" -e "s|\${DNS_NORMALIZED}|${id}|g" \
            < "${backend_tmpl}" > "${CONFIG_DIR}/${id}.cfg"
    else
        printf '# Backend for %s\nbackend backend_%s\n    mode http\n    balance roundrobin\n    server dev 127.0.0.1:8080 check inter 5s fall 3 rise 2\n' \
            "${dns_name}" "${id}" > "${CONFIG_DIR}/${id}.cfg"
    fi
    echo "Updated: ${CONFIG_DIR}/${id}.cfg for DNS: ${dns_name} (template: ${template_filename})"
}

remove_config() {
    local base="$1"
    rm -f "${CONFIG_DIR}/${base}.cfg" "${CONFIG_DIR}/${base}.acl" 2>/dev/null || true
    echo "Removed: ${CONFIG_DIR}/${base}.cfg and ${CONFIG_DIR}/${base}.acl"
}

cleanup_orphaned() {
    [ -f "${ENV_FILE}" ] || return 0
    
    # Expected base names (normalized_id) from DNS_LIST and all DNS_LIST_<key>
    EXPECTED=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        val=$(echo "$line" | cut -d= -f2- | tr -d '"' | tr -d "'")
        for dns in $(echo "$val" | tr ',' '\n'); do
            dns=$(echo "$dns" | xargs)
            [ -n "$dns" ] || continue
            id=$(normalize_id "$dns")
            EXPECTED="${EXPECTED}${id} "
        done
    done <<EOF
$(grep -E '^DNS_LIST(_[a-zA-Z0-9_]+)?=' "${ENV_FILE}" 2>/dev/null || true)
EOF
    [ -n "${EXPECTED}" ] || return 0
    
    find "${CONFIG_DIR}" -maxdepth 1 -type f \( -name "*.cfg" -o -name "*.acl" \) 2>/dev/null | while read -r f; do
        base=$(basename "$f" .cfg)
        base=$(basename "$base" .acl)
        [ -n "$base" ] || continue
        case " ${EXPECTED} " in
            *" ${base} "*) ;;
            *) remove_config "$base" ;;
        esac
    done
}

# Obtiene el template para una key (default o sufijo de DNS_LIST_<key>)
get_template_for_key() {
    local key="$1"
    local t
    if [ "$key" = "default" ]; then
        t=$(grep -E '^DNS_TEMPLATE=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs)
    else
        t=$(grep -E "^DNS_TEMPLATE_${key}=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs)
    fi
    echo "${t:-dns-backend.tmpl}"
}

parse_dns_list() {
    [ -f "${ENV_FILE}" ] || {
        echo "Warning: ${ENV_FILE} not found, no DNS configurations will be generated"
        return 0
    }
    
    _found=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        varname=$(echo "$line" | cut -d= -f1)
        val=$(echo "$line" | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs)
        [ -n "$val" ] || continue
        
        if [ "$varname" = "DNS_LIST" ]; then
            key="default"
        else
            key=$(echo "$varname" | sed 's/^DNS_LIST_//')
        fi
        template=$(get_template_for_key "$key")
        
        for dns in $(echo "$val" | tr ',' '\n'); do
            dns=$(echo "$dns" | xargs)
            [ -n "$dns" ] || continue
            _found=1
            generate_config "$dns" "$template"
        done
    done <<EOF
$(grep -E '^DNS_LIST(_[a-zA-Z0-9_]+)?=' "${ENV_FILE}" 2>/dev/null || true)
EOF
    
    [ "$_found" = "1" ] || echo "No DNS_LIST or DNS_LIST_<key> with domains found in ${ENV_FILE}, skipping DNS configuration generation"
}

main() {
    echo "Starting DNS configuration generation..."
    echo "ENV_FILE: ${ENV_FILE}"
    echo "CONFIG_DIR: ${CONFIG_DIR}"
    echo "TEMPLATE_DIR: ${TEMPLATE_DIR}"
    
    parse_dns_list
    cleanup_orphaned
    
    [ -f "${ENV_FILE}" ] && grep -E '^DNS_LIST(_[a-zA-Z0-9_]+)?=' "${ENV_FILE}" > "${STATE_FILE}" 2>/dev/null || true
    echo "DNS configuration generation completed"
}

main "$@"
