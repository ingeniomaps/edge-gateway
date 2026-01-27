# Configuración HTTPS - edge-gateway

## Resumen

El frontend HTTPS se **habilita** cuando existe al menos un `.pem` en `certs/haproxy-certs/` (HAProxy usa **SNI** con ese directorio). Hay **un certificado por dominio base** (cada uno cubre el dominio y `*.dominio`). Si no hay certificados, el entrypoint **comenta** el frontend HTTPS.

Puedes usar **Let's Encrypt**, **mkcert** (desarrollo) o **certificado manual**. En cada arranque, `ensure-ssl.sh` valida, construye `haproxy-certs/` desde `conf/live/` o desde `haproxy.pem` (legacy), o deshabilita HTTPS.

## Flujo en el entrypoint (ensure-ssl)

1. **Si `haproxy-certs/*.pem` existe**  
   - Comprueba caducidad (aviso si &lt;30 días). Sigue.

2. **Si no, pero existe `conf/live/BASE/` (certbot o mkcert)**  
   - Para cada `BASE`, construye `haproxy-certs/<base>.pem` (fullchain+privkey).

3. **Si no, pero existe `haproxy.pem` (legacy)**  
   - Copia a `haproxy-certs/legacy.pem`.

4. **Si no hay certificado**  
   - **`SSL_CERT_TYPE=letsencrypt` o `mkcert`**: crea `/tmp/ssl_disable_https`. Ejecuta `make setup-ssl` en el host.
   - **`SSL_CERT_TYPE=selfsigned` o vacío**: genera `haproxy-certs/selfsigned.pem` con `openssl` si está disponible; si no, deshabilita HTTPS.

## Variables en `.env`

| Variable          | Uso                                                                 |
|-------------------|---------------------------------------------------------------------|
| `SSL_CERT_TYPE`   | `letsencrypt` \| `mkcert` \| `selfsigned` o vacío. Obligatorio para `make setup-ssl`. |
| `CERTBOT_EMAIL`   | Requerido con Let's Encrypt.                                        |
| `CERTBOT_DOMAIN`  | Dominio para certbot si no se usa `DNS_LIST`/`DNS_LIST_*`/`SITE_URL`. |
| `SITE_URL`        | Ej. `https://example.com`; se usa para sacar el dominio.            |
| `DNS_LIST`, `DNS_LIST_*` | Se obtienen los **dominios base** únicos (ej. `nunzio.dev`, `ejemplo.com`); se genera un cert por base. |

Los dominios base se calculan desde todos los FQDN de `DNS_LIST` y `DNS_LIST_*` (últimas dos etiquetas: `api.ejemplo.com` → `ejemplo.com`).

## Comandos en el host

| Comando            | Descripción                                                                 |
|--------------------|-----------------------------------------------------------------------------|
| `make setup-ssl`   | Genera **un cert por dominio base** (desde `DNS_LIST` y `DNS_LIST_*`) con mkcert o Let's Encrypt. Escribe en `certs/conf/live/BASE/` y construye `certs/haproxy-certs/<base>.pem`. Si ya hay certs y es letsencrypt: intenta renovar. |
| `make check-ssl`   | Comprueba `certs/haproxy-certs/*.pem`, `certs/haproxy.pem` o `certs/conf/live/`. Exit 0 si válido (≥24h). |
| `make generate-cert` | Let's Encrypt: generación por base (sin arg = todos los bases de .env). Para renovar: `make renew-cert`. |
| `make renew-cert`  | Let's Encrypt: renovar y reconstruir `certs/haproxy-certs/` desde `conf/live/`. |

`make setup-ssl` llama a `check-ssl` y, si aplica, a `certbot.sh renew` o a la generación mkcert/certbot.

## Let's Encrypt

1. En `.env`:
   ```bash
   SSL_CERT_TYPE=letsencrypt
   CERTBOT_EMAIL=admin@example.com
   CERTBOT_DOMAIN=example.com   # o deja que use DNS_LIST / SITE_URL
   ```

2. Generar la primera vez:
   ```bash
   make setup-ssl
   # o explícitamente:
   make generate-cert
   ```

3. Renovar (también desde `make setup-ssl` si ya hay certs):
   ```bash
   make renew-cert
   ```

Certbot usa `--standalone` y necesita el puerto 80: los scripts paran HAProxy, ejecutan certbot y vuelven a arrancar. Los certificados se guardan en `certs/conf/live/BASE/`. Tras generate/renew se construye `certs/haproxy-certs/<base>.pem` (fullchain+privkey) por cada base.

Let's Encrypt **no** sirve para dominios como `*.local`, `localhost` o IPs; en ese caso usa `SSL_CERT_TYPE=mkcert`.

## mkcert (desarrollo)

1. En `.env`:
   ```bash
   SSL_CERT_TYPE=mkcert
   DNS_LIST=mi-app.local   # o el host que uses
   ```

2. Instalar mkcert en el host, por ejemplo:
   ```bash
   sudo apt install mkcert   # o ver https://github.com/FiloSottile/mkcert
   mkcert -install
   ```

3. Generar:
   ```bash
   make setup-ssl
   ```

Se crean `certs/conf/live/BASE/` (fullchain.pem, privkey.pem) por cada dominio base y se genera `certs/haproxy-certs/<base>.pem`.

## Certificado manual (self-signed u otro)

1. Crea uno o más `.pem` en `certs/haproxy-certs/` (cert+clave en un PEM por archivo):
   ```bash
   mkdir -p certs/haproxy-certs
   openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
     -keyout certs/haproxy.key -out certs/haproxy.crt -subj "/CN=localhost"
   cat certs/haproxy.crt certs/haproxy.key > certs/haproxy-certs/selfsigned.pem
   ```
   O con un cert existente: `cat tu-cert.pem tu-clave.key > certs/haproxy-certs/midominio.pem`

2. **Legacy:** `certs/haproxy.pem` (un solo PEM): `ensure-ssl` lo copia a `haproxy-certs/legacy.pem`.

3. Monta `./certs` y reinicia: `docker compose up -d haproxy`. `ensure-ssl` usará `haproxy-certs/*.pem` o construirá desde `conf/live/` o `haproxy.pem`.

## Self-signed dentro del contenedor

Con `SSL_CERT_TYPE=selfsigned` o vacío, `ensure-ssl` intenta generar un self-signed con `openssl`. La imagen **haproxy:3.3-alpine** no incluye `openssl`, por lo que suele fallar y se deshabilita HTTPS. Opciones:

- Usar **`mkcert`** en el host (`SSL_CERT_TYPE=mkcert`) y `make setup-ssl`, o  
- Generar **en el host** un `certs/haproxy.pem` como en “Certificado manual” y montar `./certs`.

## Acceso al frontend HTTPS

Con certificado válido:

- `https://localhost`, `https://tu-dominio`  
- Con self-signed o mkcert local: el navegador puede mostrar advertencia; en `curl` usa `-k` si quieres ignorar la verificación.

## Verificar que HTTPS está habilitado

```bash
# Logs
docker compose logs haproxy | grep -i "certificate\|https\|ssl"

# Que el frontend no esté comentado
docker compose exec haproxy grep -A2 "frontend https_frontend" /tmp/haproxy.cfg

# Comprobar certificado
make check-ssl
openssl x509 -in certs/haproxy-certs/*.pem -noout -dates -subject
```

## Troubleshooting

### El frontend HTTPS sigue comentado

1. `make check-ssl` y que exista al menos un `certs/haproxy-certs/*.pem` (o `certs/conf/live/BASE/` o `certs/haproxy.pem` legacy).
2. Que `./certs` esté montado en `/etc/ssl/certs` y que `haproxy-certs/` tenga `.pem` (o `ensure-ssl` pueda construirlo desde `conf/live/` o `haproxy.pem`).
3. Revisar logs: `docker compose logs haproxy` por “Disabling HTTPS”, “ssl_disable_https” o “Cannot generate certificate”.

### “Cannot generate certificate (openssl not available). Disabling HTTPS.”

La imagen no trae `openssl`. Usa `make setup-ssl` con `mkcert` o `letsencrypt`, o crea `certs/haproxy.pem` en el host manualmente.

### Let's Encrypt: “Let's Encrypt no sirve para dominios locales o IPs”

Pon `SSL_CERT_TYPE=mkcert` para desarrollo local o usa un dominio público con `letsencrypt`.

### Certbot: “CERTBOT_EMAIL” / “Configura CERTBOT_EMAIL en .env”

Añade en `.env`:
```bash
CERTBOT_EMAIL=admin@tudominio.com
```

### Renovación automática

Puedes programar en cron, por ejemplo:

```bash
0 3 * * * cd /ruta/edge-gateway && make renew-cert
```

O `make setup-ssl` periódicamente; si ya hay certs y es letsencrypt, intentará renovar y reconstruir `certs/haproxy-certs/`.
