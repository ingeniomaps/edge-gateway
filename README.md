# HAProxy Load Balancer - Producción

Proyecto HAProxy **3.3** configurado y listo para producción, funcionando como load balancer con soporte para HTTP/HTTPS, health checks, estadísticas y configuraciones de seguridad siguiendo las mejores prácticas de 2026.

## Versión

- **HAProxy**: 3.3-alpine (última versión estable)
- **Alpine Linux**: Latest
- **Actualizado**: 2026

## Características

- ✅ **HAProxy 3.3** con todas las últimas características
- ✅ Balanceo de carga con múltiples algoritmos (roundrobin por defecto)
- ✅ Terminación SSL/TLS con soporte HTTP/2 y ALPN
- ✅ **SNI automático** (característica nueva en HAProxy 3.3)
- ✅ Health checks automáticos mejorados
- ✅ Redirección HTTP → HTTPS
- ✅ **Rate limiting avanzado** (DDoS protection)
- ✅ Headers de seguridad modernos (HSTS, CSP, Permissions-Policy, etc.)
- ✅ Estadísticas y monitoreo
- ✅ Compresión HTTP mejorada
- ✅ Logging configurado con separación de errores
- ✅ Configuraciones de seguridad para producción
- ✅ **TLS 1.2+ solamente** (sin SSLv3, TLS 1.0, TLS 1.1)
- ✅ **Ciphers modernos** (TLS 1.3 compatible)
- ✅ Dockerizado con seguridad mejorada (read-only filesystem)
- ✅ **Protección contra ataques comunes**
- ✅ **Gestión dinámica de DNS** - Configuración automática desde lista en .env
- ✅ **Templates configurables** - Generación automática de frontends/backends
- ✅ **SSL automático** - Let's Encrypt, mkcert o self-signed; validación/renovación en arranque

## Estructura del Proyecto

```
.
├── haproxy.cfg              # Configuración principal de HAProxy
├── Dockerfile               # Imagen Docker de HAProxy
├── docker-compose.yml       # Orquestación con Docker Compose (desarrollo)
├── compose.production.yml   # Overrides para producción
├── env.example              # Ejemplo de archivo .env con DNS_LIST
├── scripts/                 # Scripts de generación y gestión
│   ├── common.sh               # Utilidades (extract_domain, log_*, etc.)
│   ├── generate-dns-config.sh  # Genera configuraciones DNS desde .env
│   ├── entrypoint.sh           # Entrypoint: ensure-ssl + DNS + HAProxy
│   ├── ensure-ssl.sh           # En entrypoint: valida/crea cert o deshabilita HTTPS
│   ├── check-ssl.sh            # Comprueba si hay certificados válidos (host)
│   ├── certbot.sh              # Let's Encrypt: generate | renew (host)
│   ├── setup-ssl-auto.sh       # mkcert o letsencrypt según SSL_CERT_TYPE (host)
│   └── watch-dns-changes.sh    # Monitor de cambios en DNS_LIST
├── certs/                  # Certificados: haproxy-certs/*.pem (un por dominio base), conf/live/ (certbot/mkcert)
├── templates/               # Templates para generación de configs
│   ├── dns-frontend.tmpl   # (legacy) Referencia
│   ├── dns-backend.tmpl    # Backend por DNS (por defecto, HTTP estándar)
│   ├── dns-backend-api.tmpl # API REST (health check TCP)
│   ├── dns-backend-grpc.tmpl # gRPC (HTTP/2, proto h2, streaming)
│   ├── dns-backend-websocket.tmpl # WebSocket (conexiones persistentes)
│   ├── dns-backend-streaming.tmpl # SSE/Streaming HTTP (Server-Sent Events)
│   └── dns-backend-long-response.tmpl # Respuestas largas (IA, procesamiento pesado)
├── dns-configs/            # Configuraciones generadas (gitignored)
├── docs/                   # Documentación adicional
│   ├── CHANGELOG.md          # Historial de cambios
│   ├── DNS_CONFIGURATION.md  # Configuración dinámica DNS (listas, templates)
│   ├── HTTPS_SETUP.md        # SSL/HTTPS detallado (Let's Encrypt, mkcert, manual)
│   └── PRODUCTION.md         # Checklist y despliegue en producción
├── README.md                # Esta documentación
└── logs/                    # Directorio para logs (se crea automáticamente)
```

## Requisitos Previos

- **Docker Engine 20.10+** y **Docker Compose V2** (recomendado)
- Certificados SSL (opcional): `make setup-ssl` con mkcert/Let's Encrypt o `certs/haproxy.pem` manual
- **Docker Compose V2** es el estándar desde 2022 (no requiere campo `version`)

## Configuración Rápida

### 1. Clonar/Descargar el proyecto

```bash
cd edge-gateway
```

### 2. Configurar DNS dinámicos (Nuevo)

El sistema genera automáticamente configuraciones para cada DNS listado en `.env`:

```bash
# Copiar el archivo de ejemplo
cp env.example .env

# Editar .env y agregar tus DNS (también DNS_LIST_<key> y DNS_TEMPLATE_<key> para varias listas/templates)
# DNS_LIST=example.com,www.example.com
# DNS_LIST_api=api.example.com
# DNS_TEMPLATE_api=dns-backend-api.tmpl
```

Cada DNS en la(s) lista(s) generará automáticamente:
- Reglas por `Host` dentro del frontend HTTPS (`.acl`) y un backend (`.cfg`)
- Configuración de seguridad y rate limiting

**Desarrollo local (mkcert):** para que `https://tudominio.dev` funcione en el navegador, añade en `/etc/hosts`: `127.0.0.1   tudominio.dev`

**Importante:** Después de cambiar `DNS_LIST` o `DNS_LIST_*` en `.env`, reinicia el contenedor:
```bash
docker compose restart haproxy
```

### 3. Configurar servidores backend en templates

Los archivos generados desde templates incluyen ejemplos de servidores. Para personalizar:

1. Edita los templates en `templates/` según tu tipo de servicio (los `.cfg` en `dns-configs/` se regeneran desde ellos en cada arranque o `make reload`)

**Templates disponibles:**
- `dns-backend.tmpl` - HTTP estándar (por defecto)
- `dns-backend-api.tmpl` - API REST
- `dns-backend-grpc.tmpl` - gRPC (HTTP/2, streaming)
- `dns-backend-websocket.tmpl` - WebSocket (conexiones persistentes)
- `dns-backend-streaming.tmpl` - SSE/Streaming HTTP (Server-Sent Events)
- `dns-backend-long-response.tmpl` - Respuestas largas (IA, procesamiento pesado)

Ejemplo de servidores en el template:
```cfg
server server1 192.168.1.10:80 check inter 5s fall 3 rise 2
server server2 192.168.1.11:80 check inter 5s fall 3 rise 2
```

**Ver [docs/DNS_CONFIGURATION.md](docs/DNS_CONFIGURATION.md) para detalles de cada template y cuándo usarlo.**

### 4. Configurar certificados SSL para HTTPS

El `https_frontend` se **habilita** si existe al menos un `.pem` en `certs/haproxy-certs/` (un certificado por dominio base; HAProxy usa SNI). El volumen `./certs` → `/etc/ssl/certs` está montado. En cada arranque, `ensure-ssl` valida, construye `haproxy-certs/` desde `conf/live/` (certbot/mkcert) o desde `haproxy.pem` (legacy), o deshabilita HTTPS si no hay cert.

**Automático (recomendado):** Define en `.env` `SSL_CERT_TYPE=letsencrypt` o `SSL_CERT_TYPE=mkcert` y ejecuta:

```bash
make setup-ssl    # genera o, si ya hay certs letsencrypt, intenta renovar
make check-ssl    # comprobar validez
make renew-cert   # solo Let's Encrypt: renovar
```

- **Let's Encrypt:** dominio público; en `.env`: `CERTBOT_EMAIL`, `CERTBOT_DOMAIN` (o `DNS_LIST`/`SITE_URL`).
- **mkcert:** desarrollo local; requiere `mkcert` instalado en el host.

**Manual:** Crea `certs/haproxy-certs/<nombre>.pem` (cert+clave en un PEM) o el legacy `certs/haproxy.pem` (se copia a `haproxy-certs/legacy.pem`). Ejemplo self-signed:

```bash
mkdir -p certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/haproxy.key -out certs/haproxy.crt -subj "/CN=localhost"
mkdir -p certs/haproxy-certs && cat certs/haproxy.crt certs/haproxy.key > certs/haproxy-certs/selfsigned.pem
```

**Nota:** La imagen no incluye `openssl`; para self-signed genera en el host como arriba o usa `mkcert`. Detalles: [docs/HTTPS_SETUP.md](docs/HTTPS_SETUP.md).

### 5. Cambiar credenciales de estadísticas

Edita `haproxy.cfg` y cambia la contraseña en la sección `frontend stats`:
```cfg
stats auth admin:TU_CONTRASEÑA_SEGURA
```

### 6. Construir y ejecutar

**Desarrollo:**
```bash
# Construir la imagen
docker compose build

# Iniciar el servicio
docker compose up -d

# Ver logs
docker compose logs -f
```

**Producción:**
```bash
# Usar el archivo de producción
docker compose -f docker-compose.yml -f compose.production.yml up -d

# Ver logs
docker compose logs -f haproxy
```

## Configuración Detallada

### Docker Compose V2 (2026 Best Practices)

El archivo `docker-compose.yml` sigue las mejores prácticas de 2026:

- ✅ **Sin campo `version`** - Compose V2 valida características automáticamente
- ✅ **Labels para metadata** - Organización y monitoreo mejorado
- ✅ **Logging configurado** - Rotación automática de logs (10MB, 3 archivos)
- ✅ **Ulimits optimizados** - 65536 file descriptors
- ✅ **Graceful shutdown** - `stop_grace_period` configurado
- ✅ **Health checks mejorados** - Con `start_period` configurado
- ✅ **Networks con labels** - Mejor organización
- ✅ **Volúmenes con bind options** - `create_host_path: true` para logs
- ✅ **Deploy resources** - Límites y reservas de recursos
- ✅ **Restart policies** - Configuración avanzada de reinicio
- ✅ **Separación desarrollo/producción** - `compose.production.yml` para overrides

### Puertos

- **80**: HTTP (redirige a HTTPS)
- **443**: HTTPS
- **8404**: Estadísticas y monitoreo

### Backends por DNS

Los backends se generan desde `DNS_LIST` y `DNS_LIST_<key>`: uno por dominio (`backend_<id>`). Se inyectan desde `dns-configs/*.cfg`. El tráfico se enruta por `Host`; si no coincide, usa `unknown_host` (503). Edita los templates en `templates/` para los servidores reales.

### Algoritmos de Balanceo

Por defecto se usa `roundrobin`. Puedes cambiar a:
- `leastconn`: Menor número de conexiones
- `source`: Basado en IP de origen
- `uri`: Basado en URI
- `hdr(name)`: Basado en header HTTP

Ejemplo:
```cfg
backend backend_mi_dominio
    balance leastconn
```

### Health Checks

Los health checks están configurados para verificar el endpoint `/health`:
```cfg
option httpchk GET /health
http-check expect status 200
```

Asegúrate de que tus servidores backend tengan este endpoint.

### Rate Limiting (DDoS Protection)

El rate limiting está configurado con múltiples capas de protección:
- **100 requests HTTP por 10 segundos** por IP
- **50 conexiones por 10 segundos** por IP
- **10 conexiones simultáneas** por IP

```cfg
http-request deny if { sc_http_req_rate(0) gt 100 }
http-request deny if { sc_conn_rate(0) gt 50 }
http-request deny if { sc_conn_cur(0) gt 10 }
```

Ajusta según tus necesidades.

### Gestión Dinámica de DNS

El sistema incluye un generador automático de configuraciones DNS que:

1. **Listas de DNS en `.env`**: `DNS_LIST` y `DNS_LIST_<key>` (cada una puede usar `DNS_TEMPLATE` o `DNS_TEMPLATE_<key>`)
   ```bash
   DNS_LIST=example.com,www.example.com
   DNS_LIST_api=api.example.com
   DNS_TEMPLATE_api=dns-backend-api.tmpl
   ```

2. **Genera `.acl` y `.cfg` automáticamente**:
   - Cada DNS obtiene su propio backend; los `.acl` y `.cfg` se generan en `dns-configs/` (montado como `dns.d`)
   - Se **inyectan** en `haproxy.cfg` en el arranque y en `make reload` (no se usa `include`)

3. **Sincronización**:
   - Al iniciar o `make reload` se **regeneran siempre** desde los templates
   - Al cambiar listas o templates, reinicia o `make reload`; los dominios quitados pierden sus `.acl`/`.cfg`

4. **Templates**: `templates/dns-backend.tmpl` (por defecto), `dns-backend-api.tmpl`, etc. Variables: `${DNS_NAME}`, `${DNS_NORMALIZED}`

**Ejemplo de uso:**
```bash
# 1. Editar .env
echo "DNS_LIST=mi-app.com,api.mi-app.com" >> .env

# 2. Reiniciar contenedor
docker compose restart haproxy

# 3. Verificar configuraciones generadas
ls -la dns-configs/
```

**Personalizar servidores backend:** Edita los templates en `templates/` (p. ej. `dns-backend.tmpl`, `dns-backend-api.tmpl`, `dns-backend-grpc.tmpl`); los `.cfg` en `dns-configs/` se regeneran desde ellos. Más ejemplos y troubleshooting: [docs/DNS_CONFIGURATION.md](docs/DNS_CONFIGURATION.md).

### Nuevas Características de HAProxy 3.3

- **SNI Automático**: HAProxy 3.3 establece automáticamente el SNI basado en el header Host, sin configuración manual
- **HTTP/2 nativo**: Soporte completo para HTTP/2 con ALPN
- **TLS 1.3**: Soporte para los ciphers más modernos
- **Mejores timeouts**: Configuraciones optimizadas para aplicaciones modernas
- **Logging mejorado**: Separación de errores y mejor formato de logs

## Estadísticas y Monitoreo

Accede a las estadísticas en:
```
http://tu-servidor:8404/stats
```

**Importante:** Debes usar la ruta `/stats`, no solo el puerto.

Credenciales por defecto:
- Usuario: `admin`
- Contraseña: `changeme` (¡CÁMBIALA!)

**Acceso desde navegador:**
1. Ve a `http://localhost:8404/stats` (o `http://tu-servidor:8404/stats`)
2. Cuando aparezca el diálogo de autenticación, ingresa:
   - Usuario: `admin`
   - Contraseña: `changeme`

**Acceso desde línea de comandos:**
```bash
curl -u admin:changeme http://localhost:8404/stats
```

**Nota:** Si recibes un error 401, es normal - significa que necesitas autenticarte. Si recibes 403, verifica que estés accediendo a `/stats` y no solo al puerto.

## Producción

**Checklist y detalles:** [docs/PRODUCTION.md](docs/PRODUCTION.md) (stats, SSL, backends por DNS, renovación Let's Encrypt, etc.).

Resumen obligatorio: cambiar `stats auth` en haproxy.cfg, restringir stats por IP, `SSL_CERT_TYPE=letsencrypt` + cron de `make renew-cert`, y **servidores reales** en los templates (`dns-backend.tmpl`, `dns-backend-api.tmpl`, `dns-backend-grpc.tmpl`, etc.). Los backends son solo los de `DNS_LIST` y `DNS_LIST_*`.

## Comandos Útiles

`make` o `make help` lista todos los objetivos. Ejemplos:

```bash
# Verificar configuración de Docker Compose
make config
# o: docker compose config

# Verificar configuración de HAProxy
make check

# Recargar configuración (regenera dns.d y aplica; en Docker puede provocar breve reinicio si HAProxy es PID 1)
make reload
# Alternativa: reinicio explícito (recomendado si cambiaste DNS_LIST o dns-configs)
docker compose restart haproxy

# Ver logs en tiempo real
docker compose logs -f haproxy

# Reiniciar servicio
docker compose restart haproxy

# Detener servicio
docker compose down

# Detener y eliminar volúmenes
docker compose down -v

# Ver estadísticas
curl -u admin:changeme http://localhost:8404/stats

# Ver información del contenedor
docker compose ps

# Inspeccionar el servicio
docker compose inspect haproxy

# Regenerar configuraciones DNS manualmente
docker compose exec haproxy /usr/local/bin/generate-dns-config.sh

# Ver configuraciones DNS generadas
ls -la dns-configs/

# Ver contenido de una configuración DNS específica
cat dns-configs/example_com.cfg

# SSL: generar o renovar certificados (mkcert / Let's Encrypt)
make setup-ssl

# Comprobar si los certificados son válidos
make check-ssl

# Renovar Let's Encrypt
make renew-cert
```

## Troubleshooting

### El servicio no inicia

1. Verifica la configuración de Docker Compose:
```bash
docker compose config
```

2. Verifica la configuración de HAProxy:
```bash
docker compose exec haproxy haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg
```

3. Revisa los logs:
```bash
docker compose logs haproxy
```

4. Verifica que los puertos no estén en uso:
```bash
sudo netstat -tulpn | grep -E ':(80|443|8404)'
```

### Certificados SSL

Comprueba validez con `make check-ssl`. Para formato y más opciones, ver [docs/HTTPS_SETUP.md](docs/HTTPS_SETUP.md). Comprobar PEM:
```bash
openssl x509 -in certs/haproxy-certs/*.pem -text -noout  # o certs/haproxy.pem (legacy)
```

### Health checks fallan

Asegúrate de que tus servidores backend respondan en `/health` con status 200.

## Seguridad

### Características de Seguridad Implementadas

- ✅ HAProxy corre con usuario no privilegiado
- ✅ Chroot habilitado
- ✅ Rate limiting multi-capa (DDoS protection)
- ✅ Headers de seguridad modernos (HSTS, CSP, Permissions-Policy, etc.)
- ✅ Capabilities limitadas en Docker
- ✅ **Read-only filesystem** (HAProxy 3.3+)
- ✅ **TLS 1.2+ solamente** (sin versiones antiguas inseguras)
- ✅ **Ciphers modernos** (TLS 1.3 compatible)
- ✅ Protección contra extensiones de archivos maliciosas
- ✅ **SNI automático** para mejor seguridad SSL
- ✅ **HTTP/2 con ALPN** para mejor rendimiento y seguridad
- ✅ Logging separado de errores para mejor monitoreo

### Configuración TLS/SSL

La configuración usa:
- TLS 1.2 y TLS 1.3 solamente
- Ciphers modernos (TLS_AES_128_GCM_SHA256, TLS_AES_256_GCM_SHA384, TLS_CHACHA20_POLY1305_SHA256)
- Sin SSLv3, TLS 1.0, TLS 1.1 (deshabilitados por seguridad)
- Preferencia por ciphers del cliente para mejor compatibilidad

## Recursos Adicionales

**Documentación del proyecto:** [docs/HTTPS_SETUP.md](docs/HTTPS_SETUP.md) · [docs/DNS_CONFIGURATION.md](docs/DNS_CONFIGURATION.md) · [docs/PRODUCTION.md](docs/PRODUCTION.md) · [docs/CHANGELOG.md](docs/CHANGELOG.md)

- [Documentación oficial de HAProxy 3.3](http://www.haproxy.org/#docs)
- [HAProxy Configuration Manual 3.3](http://cbonte.github.io/haproxy-dconv/3.3/configuration.html)
- [HAProxy 3.3 Release Notes](https://www.haproxy.com/blog/announcing-haproxy-3-3)
- [HAProxy Technologies Docker Images](https://hub.docker.com/r/haproxytech/haproxy-alpine)

## Changelog

Ver [docs/CHANGELOG.md](docs/CHANGELOG.md) para detalles de las actualizaciones y mejoras.

## Licencia

Este proyecto es de código abierto y está disponible para uso libre.
