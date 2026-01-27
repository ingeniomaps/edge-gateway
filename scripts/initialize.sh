#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Carga un archivo .env y exporta sus variables al entorno actual.
#
# Parámetros:
#   $1 - Ruta al archivo de entorno (.env, .env.template, etc.)
# -----------------------------------------------------------------------------
load_env_file() {
  local file="$1"

  set -a
  source "$file"
  set +a
}

# -----------------------------------------------------------------------------
# Verifica si una clave existe dentro de un archivo `.env`.
#
# Parámetros:
#   $1 - Clave a buscar (por ejemplo: "DB_HOST").
#   $2 - Ruta al archivo `.env`.
#
# Descripción:
#   - Busca si la clave proporcionada aparece al inicio de alguna línea del archivo,
#     seguida de un signo igual (`=`), ignorando líneas comentadas.
#   - Retorna el código de salida de `grep -q`:
#       0 → la clave existe
#       1 → la clave no existe
#
# Retorno:
#   Código de salida estándar de `grep` (usa `$?` tras ejecutar para capturarlo).
# -----------------------------------------------------------------------------
env_has_key() {
  local key="$1"
  local env_file="$2"

  grep -qE "^[[:space:]]*${key}=" "$env_file"
}


# -----------------------------------------------------------------------------
# Filtra las variables KEY=VALUE que aún no existen en un archivo `.env`.
#
# Parámetros:
#   $1 - Cadena multilinea con pares KEY=VALUE (uno por línea).
#   $2 - Ruta del archivo `.env` contra el cual comparar.
#
# Descripción:
#   - Recorre línea por línea la lista dada de variables tipo KEY=VALUE.
#   - Extrae la clave (`KEY`) de cada línea.
#   - Verifica si ya existe en el `.env` usando la función `env_has_key`.
#   - Acumula las variables que **no existen** aún en el archivo.
#
# Retorno:
#   Imprime (stdout) la lista de líneas KEY=VALUE **no presentes** en el archivo `.env`,
#   preservando el orden de entrada.
#
# Uso esperado:
#   detect_new_variables "$vars" ".env" > new.env
# -----------------------------------------------------------------------------
detect_new_variables() {
  local key_value_pairs="$1"
  local env_file="$2"
  local new_vars=""

  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue  # Ignora líneas vacías o comentarios

    local key="${line%%=*}"
    if ! env_has_key "$key" "$env_file"; then
      new_vars+="$line"$'\n'
    fi
  done <<< "$key_value_pairs"

  printf "%s" "$new_vars"
}


# -----------------------------------------------------------------------------
# Agrega un título al archivo `.env` si aún no existe y hay variables nuevas.
#
# Parámetros:
#   $1 - Ruta del archivo `.env`.
#   $2 - Lista de nuevas variables KEY=VALUE (puede ser vacía).
#
# Descripción:
#   - Si existen nuevas variables y el título aún no
#     está presente en el archivo `.env`, lo agrega como encabezado separado.
#
# Uso esperado:
#   add_title_if_needed ".env" "$nuevas_variables"
# -----------------------------------------------------------------------------
add_title_if_needed() {
  local title="# 🔐 Secret variables"
  local env_file="$1"
  local new_variables="$2"

  if [[ -n "$new_variables" && ! $(grep -Fx "$title" "$env_file") ]]; then
    printf "\n%s\n" "$title" >> "$env_file"
  fi
}


# -----------------------------------------------------------------------------
# Escribe o actualiza variables de entorno en un archivo `.env`.
#
# Parámetros:
#   $1 - Cadena con líneas KEY=VALUE (puede contener varias líneas).
#   $2 - Ruta del archivo `.env` a modificar.
#
# Descripción:
#   - Para cada par clave-valor, si la clave ya existe en el archivo `.env`,
#     se actualiza su valor escapando correctamente las comillas.
#   - Si no existe, se agrega una nueva línea al final del archivo.
#   - Se genera una copia de respaldo del archivo original con extensión `.bak`.
#
# Requiere:
#   - Función `env_has_key` que verifica la existencia de una clave en el archivo.
# -----------------------------------------------------------------------------
write_or_update_env() {
  local key_value_pairs="$1"
  local env_file="$2"

  while IFS= read -r line; do
    # Extrae clave y valor
    local key="${line%%=*}"
    local value="${line#*=}"

    # Escapa comillas dobles dentro del valor
    local escaped_value
    escaped_value=$(printf '%s\n' "$value" | sed 's/"/\\"/g')

    if env_has_key "$key" "$env_file"; then
      # Actualiza línea existente con respaldo
      sed -i.bak "s|^$key=.*|$key=\"$escaped_value\"|" "$env_file"
    else
      # Agrega nueva variable al final
      echo "$key=\"$escaped_value\"" >> "$env_file"
    fi
  done <<< "$key_value_pairs"
}


# -----------------------------------------------------------------------------
# Extrae claves y valores secretos desde un JSON estructurado.
#
# Parámetros:
#   $1 - JSON como string. Debe tener:
#          - Un arreglo `.secrets[]`
#          - Opcionalmente `.imports[]?.secrets[]?`
#
# Retorno:
#   KEY=VALUE por línea, por ejemplo:
#     API_KEY=12345
#     DB_PASS=secure123
#
# Requiere:
#   - jq >= 1.5
# -----------------------------------------------------------------------------
parse_secrets_from_json() {
  local json_input="$1"
  echo "$json_input" | jq -r '
    (
      [
        .secrets[],
        .imports[]?.secrets[]?
      ]
      | map(select(.secretKey and .secretKey != ""))
      | map("\(.secretKey)=\(.secretValue // "")")
    ) // []
    | .[]
  '
}


# -----------------------------------------------------------------------------
# Actualiza un archivo `.env` con variables secretas extraídas desde un JSON.
#
# Parámetros:
#   $1 - (Opcional) Ruta al archivo `.env`. Por defecto, se usa `.env`.
#   $2 - (Opcional) JSON como string. Si no se pasa, se lee desde stdin.
#
# Descripción:
#   - Asegura que el archivo `.env` exista.
#   - Extrae pares clave-valor desde el JSON usando `parse_secrets_from_json`.
#   - Detecta nuevas variables y añade un título si es necesario.
#   - Actualiza o agrega las variables al `.env`.
#
# Requiere:
#   - Función `parse_secrets_from_json(json_string)` que retorne pares KEY=VALUE.
#   - Función `detect_new_variables(pairs, file)` que identifique variables nuevas.
#   - Función `add_title_if_needed(file, new_vars)` para insertar encabezado.
#   - Función `write_or_update_env(pairs, file)` que aplica los cambios.
# -----------------------------------------------------------------------------
update_env_from_json() {
  local env_file="${1:-.env}"
  local json_input="${2:-$(cat)}"

  # Garantiza que el archivo exista
  touch "$env_file"

  # Extrae los pares clave-valor desde el JSON
  local key_value_pairs
  key_value_pairs=$(parse_secrets_from_json "$json_input")

  if [[ ! -n "$key_value_pairs" ]]; then
    return 0
  fi

  # Detecta nuevas claves para decidir si se añade el título
  local new_vars
  new_vars=$(detect_new_variables "$key_value_pairs" "$env_file")

  # Añade título si hay nuevas variables
  add_title_if_needed "$env_file" "$new_vars"

  # Escribe o actualiza las variables en el archivo
  write_or_update_env "$key_value_pairs" "$env_file"

  # echo "Variables actualizadas en $env_file"
}


# -----------------------------------------------------------------------------
# Clona o actualiza un repositorio GitHub autenticado en un directorio destino.
#
# Parámetros:
#   $1 - Rama Git a utilizar (ej: "main", "develop").
#   $2 - Nombre de usuario de GitHub.
#   $3 - Token personal de acceso de GitHub (para autenticación HTTPS).
#   $4 - Nombre del repositorio (sin `.git`).
#   $5 - [Opcional] Ruta destino donde clonar el repositorio (por defecto: ".toolbox").
#
# Descripción:
#   - Si el directorio destino no existe, se clona el repositorio en modo superficial
#     (`--depth=1`) en la rama especificada.
#   - Si ya existe, se actualiza el repositorio ejecutando `git pull`.
#   - Usa autenticación embebida en la URL HTTPS para entornos automatizados y CI/CD.
# -----------------------------------------------------------------------------
clone_or_update_repo() {
  local branch="$1"
  local git_user="$2"
  local git_token="$3"
  local repo_name="$4"
  local target="${5:-.toolbox}"

  local repo_url="https://${git_token}@github.com/${git_user}/${repo_name}.git"
  local repo_display="github.com/${git_user}/${repo_name}.git"

  if [[ ! -d "$target/.git" ]]; then
    git clone --depth=1 --branch "$branch" "$repo_url" "$target"
  else
    git -C "$target" pull --quiet
  fi
}


# ------------------------------------------------------------------------------
# Carga de forma segura todos los scripts `.sh` de un directorio.
#
# Parámetros:
#   $1 (directorio) - Ruta al directorio que contiene los scripts.
#                     (Opcional, string, default: '.')
#   $2 (recursivo)  - Si es "true", busca en subdirectorios.
#                     (Opcional, string, default: 'false')
#
# Descripción:
#   - Localiza todos los archivos con extensión `.sh` dentro del directorio
#     especificado.
#   - Valida que el directorio de entrada exista antes de proceder.
#   - Carga cada script encontrado en el entorno de shell actual.
#
# Uso esperado:
#   # Cargar scripts solo del directorio 'utils/'
#   source_all_scripts "utils"
#
#   # Cargar todos los scripts recursivamente desde el directorio actual
#   source_all_scripts . "true"
# ------------------------------------------------------------------------------
source_all_scripts() {
  local directory="${1:-.}"
  local recursive="${2:-false}"

  # Principio de "Fail-Fast": valida que el directorio exista.
  if [[ ! -d "$directory" ]]; then
    echo "Error: El directorio '$directory' no existe." >&2
    return 1
  fi

  local find_args=()
  if [[ "$recursive" != "true" ]]; then
    find_args+=("-maxdepth" "1")
  fi

  # Usar `mapfile` con delimitador NUL (`-d ''`) y `find -print0` es el
  # método más robusto para manejar CUALQUIER nombre de archivo.
  local -a scripts
  mapfile -d '' -t scripts < <(find "$directory" "${find_args[@]}" -type f -name "*.sh" -print0)

  if [[ "${#scripts[@]}" -eq 0 ]]; then
    return 0
  fi

  for script in "${scripts[@]}"; do
    if [[ -f "$script" ]]; then
      source "$script"
    fi
  done
}

# ------------------------------------------------------------------------------
# Obtiene secretos de una API y los actualiza en un archivo .env.
#
# Parámetros:
#   $1 (token)        - Token de autorización "Bearer" para la API.
#                       (Requerido, string)
#   $2 (archivo_env)  - Ruta al archivo `.env` que se va a actualizar.
#                       (Requerido, string)
#   $3 (url_base)     - URL base de la API de secretos (p. ej., Infisical).
#                       (Requerido, string)
#
# Descripción:
#   - Realiza una petición GET autenticada a la API de secretos para obtener
#     un objeto JSON con las variables de entorno.
#   - Pasa el token de autorización a `curl` de forma segura a través de la
#     entrada estándar para evitar que sea visible en la lista de procesos
#     del sistema (`ps aux`).
#   - El JSON de respuesta se redirige a la función `update_env_from_json`
#     para procesarlo y actualizar el archivo `.env` especificado.
#
# Uso esperado:
#   fetch_and_update_secrets "$API_TOKEN" ".env.prod" "https://app.infisical.com"
# ------------------------------------------------------------------------------
fetch_and_update_secrets() {
  local token="$1"
  local env_file="$2"
  local base_url="$3"
  local secrets_json

  # Captura la salida de curl para un manejo de errores.
  secrets_json=$(
    curl --silent --fail --request GET \
      --url "${base_url}/api/v3/secrets/raw" \
      --header @- <<< "Authorization: Bearer ${token}"
  )

  # Comprueba el código de salida de curl.
  if [[ $? -ne 0 ]]; then
    echo "Error: Fallo al obtener los secretos de la API. Verifique la URL y el token." >&2
    return 1
  fi

  # Pasa el JSON capturado a la función de actualización.
  echo "$secrets_json" | update_env_from_json "$env_file"
}


#------------------------------------------------------------------------------
# INICIO DEL PROCESO
#------------------------------------------------------------------------------
ENV_FILE=".env"
ENV_TEMPLATE=".env.example"

# Si no existe .env, se genera desde la plantilla
[[ -f "$ENV_FILE" ]] || cp "$ENV_TEMPLATE" "$ENV_FILE"

load_env_file "$ENV_FILE"

# Si hay tokens, descarga secretos y actualiza .env
for var in $(env | grep ^INFISICAL_TOKEN_ | cut -d= -f1); do
  token="${!var}"
  fetch_and_update_secrets "$token" "$ENV_FILE" "$INFISICAL_URL"
done

load_env_file "$ENV_FILE"