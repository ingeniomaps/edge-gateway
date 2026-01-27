# Changelog

## [Unreleased]

### DNS: varias listas por template
- **`DNS_LIST` y `DNS_LIST_<key>`** en `.env`: cada lista puede usar un template distinto vía `DNS_TEMPLATE` o `DNS_TEMPLATE_<key>`
- **`generate-dns-config.sh`**: parsea todas las listas, `generate_config(dns, template)`; `cleanup_orphaned` usa todos los dominios de `DNS_LIST` y `DNS_LIST_*`
- **`extract_domain` / `get_domain`**: si `DNS_LIST` está vacío, usan la primera `DNS_LIST_<key>` con contenido

### DNS: regenerar siempre desde templates
- Los `.acl` y `.cfg` se **regeneran en cada arranque o `make reload`** desde el template (ya no se preservan si existen)
- La fuente de verdad son los templates y las variables `DNS_LIST`/`DNS_TEMPLATE_*`

### Docker y plantillas
- **Dockerfile**: `COPY templates/` para incluir todos los `.tmpl` (p. ej. `dns-backend-api.tmpl`)
- **docker-compose**: montaje de `./templates` en el contenedor; **`extra_hosts: host.docker.internal:host-gateway`** para que la app en el host sea accesible

### Template `dns-backend-api.tmpl`
- Health check HTTP (`GET /health`) comentado; solo comprobación TCP
- Servidor por defecto: `host.docker.internal:3000` (apunta al host cuando la app corre en la máquina)

### `make reload` termina correctamente
- El nuevo HAProxy se lanza en segundo plano (`nohup ... &`) para que el script y `make reload` finalicen y no queden colgados

### Certificados: uno por dominio base
- **Un certificado por dominio base** (cada uno cubre el dominio y `*.dominio`); HAProxy usa **SNI** con el directorio `crt`
- **`certs/haproxy-certs/`**: un `.pem` por base (p. ej. `nunzio_dev.pem`, `ejemplo_com.pem`); `haproxy.cfg` usa `crt /etc/ssl/certs/haproxy-certs`
- **`common.sh`**: `extract_all_fqdns`, `extract_base_domain`, `extract_unique_bases`, `fqdns_for_base`
- **`setup-ssl-auto.sh`**: mkcert/letsencrypt generan un cert por base; salida en `haproxy-certs/`
- **`certbot.sh`**: `generate [base]` (sin arg = todos los bases de `.env`); `renew` reconstruye `haproxy-certs/` desde `conf/live/`
- **`ensure-ssl.sh`**: construye `haproxy-certs/` desde `conf/live/BASE/`; compatibilidad con `haproxy.pem` → `haproxy-certs/legacy.pem`
- **`check-ssl.sh`**: prioridad `haproxy-certs/*.pem` → `haproxy.pem` → `conf/live/`

### Otros
- **`.dockerignore`**: `dns-configs/`, `*.md`, `*.state`; comentarios por secciones
- **`.env` / `env.example`**: comentarios DNS y SSL actualizados (multi-lista, cert por dominio base)

---

## [2026] - Actualización a HAProxy 3.3 y Docker Compose V2

### Actualizado
- ✅ **HAProxy actualizado de 2.9 a 3.3-alpine** (última versión estable)
- ✅ Certificado SSL con RSA 4096 bits (antes 2048)
- ✅ Configuración TLS/SSL actualizada con mejores prácticas 2026
- ✅ Soporte HTTP/2 nativo con ALPN
- ✅ SNI automático (característica nueva en HAProxy 3.3)
- ✅ **Docker Compose actualizado a V2** (sin campo `version`, estándar 2026)

### Mejoras de Seguridad
- ✅ TLS 1.2+ solamente (sin SSLv3, TLS 1.0, TLS 1.1)
- ✅ Ciphers modernos (TLS 1.3 compatible)
- ✅ Rate limiting multi-capa (DDoS protection mejorado)
- ✅ Headers de seguridad adicionales (CSP, Permissions-Policy, Referrer-Policy)
- ✅ Protección contra extensiones de archivos maliciosas
- ✅ Read-only filesystem en Docker
- ✅ Health checks mejorados con `http-check send-state`

### Mejoras de Rendimiento
- ✅ `maxconn` aumentado a 10000 (antes 4096)
- ✅ Buffers optimizados (`tune.bufsize`, `tune.maxrewrite`)
- ✅ Timeouts optimizados para aplicaciones modernas
- ✅ Compresión HTTP mejorada con más tipos MIME

### Mejoras de Configuración
- ✅ Logging mejorado con `option log-separate-errors`
- ✅ Cookies de sesión con flags `httponly` y `secure`
- ✅ Configuración de recursos Docker actualizada (1GB memoria)
- ✅ Health check en docker-compose.yml
- ✅ Configuración de tmpfs para directorios necesarios

### Mejoras de Docker Compose (2026 Best Practices)
- ✅ **Eliminado campo `version`** - Compose V2 valida automáticamente
- ✅ **Labels para metadata** - Organización y monitoreo mejorado
- ✅ **Logging configurado** - Rotación automática (10MB, 3 archivos, compresión)
- ✅ **Ulimits optimizados** - 65536 file descriptors, 4096 procesos
- ✅ **Graceful shutdown** - `stop_grace_period: 10s` configurado
- ✅ **Health checks mejorados** - Con `start_period` configurado
- ✅ **Networks con labels y configuración IPAM** - Mejor organización
- ✅ **Volúmenes con bind options** - `create_host_path: true` para logs
- ✅ **Deploy resources avanzado** - Límites, reservas y restart policies
- ✅ **Separación desarrollo/producción** - `compose.production.yml` para overrides
- ✅ **Tags en build** - Múltiples tags para mejor gestión de imágenes
- ✅ **Security options mejorados** - AppArmor y Seccomp configurados
- ✅ **Tmpfs con opciones de seguridad** - `noexec`, `nosuid` y límites de tamaño

### Nuevas Características HAProxy 3.3
- ✅ SNI automático basado en header Host
- ✅ HTTP/2 push-preload
- ✅ Mejor soporte para TLS 1.3
- ✅ Configuraciones de seguridad mejoradas
