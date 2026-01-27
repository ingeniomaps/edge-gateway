# Guía de Configuración Dinámica de DNS

## Descripción

El sistema de gestión dinámica de DNS permite configurar múltiples dominios en HAProxy simplemente listándolos en el archivo `.env`. Cada DNS obtiene automáticamente su propia configuración de frontend y backend.

## Cómo Funciona

1. **Lista de DNS en `.env`**: Define tus dominios en `DNS_LIST` o `DNS_LIST_<key>` (cada una puede usar un template distinto con `DNS_TEMPLATE` / `DNS_TEMPLATE_<key>`).
2. **Generación automática**: Al iniciar o recargar, se **regeneran siempre** los `.acl` y `.cfg` desde los templates asignados (template y listas son la fuente de verdad).
3. **Integración en HAProxy**: Los archivos se inyectan en `haproxy.cfg`.
4. **Sincronización**: Al añadir/quitar en la lista o cambiar de template, reinicia o `make reload`; si borras un DNS de las listas, se eliminan sus `.acl`/`.cfg`.

## Configuración Básica

### 1. Crear archivo .env

```bash
cp env.example .env
```

### 2. Editar .env

```bash
# Formato: DNS_LIST=domain1.com,domain2.com,domain3.com
DNS_LIST=example.com,api.example.com,www.example.com
```

### 3. Reiniciar contenedor

```bash
docker compose restart haproxy
```

## Estructura de Archivos Generados

Para cada DNS en la lista se generan dos archivos en `dns-configs/` (montado como `dns.d` en el contenedor):

```
dns-configs/
├── example_com.acl      # ACL + use_backend (se incluye dentro de https_frontend)
├── example_com.cfg      # Backend
├── api_example_com.acl
├── api_example_com.cfg
└── ...
```

- **`.acl`**: Reglas por `Host` que se inyectan en `https_frontend` **antes** de las reglas por path, para que el enrutado por dominio funcione.
- **`.cfg`**: Solo el backend (servidores, health check, etc.).

### Resolución DNS en desarrollo (mkcert / dominios locales)

Para que el navegador llegue a `https://nunzio.dev` (o el dominio que uses), el nombre debe resolverse a la máquina donde corre HAProxy. En local:

```bash
# Añade en /etc/hosts (Linux/macOS)
127.0.0.1   nunzio.dev
```

En producción, el dominio debe apuntar a la IP del servidor vía DNS real.

## Personalización

### Opción 1: Modificar el template de backend

Edita `templates/dns-backend.tmpl` para cambiar servidores y health check de todos los DNS. Variables: `${DNS_NAME}` (ej: `nunzio.dev`), `${DNS_NORMALIZED}` (ej: `nunzio_dev`). Por defecto incluye `server dev 127.0.0.1:8080`; sustituye por tus servicios.

### Opción 2: Usar listas y templates por tipo de servicio

Puedes definir `DNS_LIST_<key>=...` y `DNS_TEMPLATE_<key>=nombre.tmpl` para que ciertos dominios usen un template distinto (p. ej. `dns-backend-api.tmpl` para APIs, `dns-backend-grpc.tmpl` para gRPC). Ver `env.example`.

## Configurar servidores backend

Cada DNS genera un backend desde el template asignado (`dns-backend.tmpl` por defecto o `DNS_TEMPLATE_<key>`). Los `.cfg` y `.acl` se **regeneran en cada arranque o `make reload`** desde el template; para cambios permanentes, edita el template correspondiente en `templates/`.

## Ejemplos de Configuración

### Ejemplo 1: Múltiples Dominios

```bash
# .env
DNS_LIST=app.example.com,api.example.com,admin.example.com
```

Genera 3 configuraciones independientes.

### Ejemplo 2: Dominio con Subdominios

```bash
# .env
DNS_LIST=example.com,www.example.com,api.example.com,cdn.example.com
```

Cada uno tiene su propio frontend y backend.

### Ejemplo 3: Diferentes templates por lista

Usa `DNS_LIST_<key>` y `DNS_TEMPLATE_<key>` para que una lista use otro template:

```bash
# .env
DNS_LIST=www.example.com,app.example.com
DNS_LIST_api=api.example.com
DNS_TEMPLATE_api=dns-backend-api.tmpl
```

Crea `templates/dns-backend-api.tmpl` (o el nombre que pongas en `DNS_TEMPLATE_api`). Los `.cfg` se regeneran desde el template en cada arranque o `make reload`; no edites los generados en `dns-configs/`.

### Ejemplo 4: gRPC interno

Para servicios gRPC, usa el template `dns-backend-grpc.tmpl` que configura HTTP/2 (`proto h2`):

```bash
# .env
DNS_LIST_grpc=grpc.example.com
DNS_TEMPLATE_grpc=dns-backend-grpc.tmpl
```

El template `dns-backend-grpc.tmpl` incluye:
- `mode http` con `proto h2` en los servidores (gRPC usa HTTP/2)
- Health check TCP (o HTTP/2 si tu servicio lo soporta)
- Timeouts extendidos para streaming
- Ejemplo con `host.docker.internal:50051` (puerto estándar gRPC)

**Nota:** El frontend HTTPS (443) ya tiene ALPN h2 configurado, así que acepta conexiones HTTP/2/gRPC automáticamente.

### Ejemplo 5: WebSocket

Para aplicaciones WebSocket (chat, juegos, notificaciones en tiempo real):

```bash
# .env
DNS_LIST_ws=ws.example.com
DNS_TEMPLATE_ws=dns-backend-websocket.tmpl
```

El template `dns-backend-websocket.tmpl` incluye:
- `option http-server-close` (recomendado para WebSocket)
- `timeout tunnel 1h` (conexiones WebSocket inactivas)
- `timeout client/server 1h` (conexiones persistentes)
- HAProxy detecta automáticamente el upgrade a WebSocket

### Ejemplo 6: Streaming/SSE (Server-Sent Events)

Para streaming HTTP o Server-Sent Events (notificaciones push, actualizaciones en tiempo real):

```bash
# .env
DNS_LIST_stream=stream.example.com
DNS_TEMPLATE_stream=dns-backend-streaming.tmpl
```

El template `dns-backend-streaming.tmpl` incluye:
- `option http-keep-alive` (mantiene conexión abierta, opuesto a http-server-close)
- `timeout client/server 10m` (ajusta según frecuencia de pings/eventos)
- `timeout http-request 10m` (para requests de streaming)
- **Importante:** Si envías pings cada 5 min, usa al menos 6-10 min en timeouts

### Ejemplo 7: Respuestas largas (IA, procesamiento pesado)

Para servicios que generan respuestas largas (IA, procesamiento de imágenes/video, etc.):

```bash
# .env
DNS_LIST_ai=ai.example.com
DNS_TEMPLATE_ai=dns-backend-long-response.tmpl
```

El template `dns-backend-long-response.tmpl` incluye:
- `timeout client/server 30m` (ajusta según tu caso: 5m para IA rápida, 30m para video)
- `timeout http-request 30m` (tiempo máximo del request completo)
- Opcional: `balance leastconn` para distribuir carga de procesos largos

## Resumen de Templates Disponibles

| Template | Uso | Características |
|----------|-----|-----------------|
| `dns-backend.tmpl` | HTTP estándar (por defecto) | Health check HTTP, timeouts estándar (50s) |
| `dns-backend-api.tmpl` | API REST | Health check TCP, `host.docker.internal` |
| `dns-backend-grpc.tmpl` | gRPC | HTTP/2 (`proto h2`), timeouts 5m, streaming |
| `dns-backend-websocket.tmpl` | WebSocket | `http-server-close`, `timeout tunnel 1h`, conexiones persistentes |
| `dns-backend-streaming.tmpl` | SSE/Streaming HTTP | `http-keep-alive`, timeouts 10m, conexiones largas |
| `dns-backend-long-response.tmpl` | Respuestas largas (IA) | Timeouts 30m, `leastconn` opcional, buffers grandes |

**Nota sobre timeouts:** Los timeouts en `defaults` (50s client/server) son para HTTP estándar. Los templates especializados sobrescriben estos valores según necesidad.

## Comandos Útiles

```bash
# Regenerar configuraciones manualmente
docker compose exec haproxy /usr/local/bin/generate-dns-config.sh

# Ver configuraciones generadas
ls -la dns-configs/

# Ver contenido de una configuración
cat dns-configs/example_com.cfg

# Verificar configuración HAProxy
docker compose exec haproxy haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg

# Ver logs de generación
docker compose logs haproxy | grep -i dns
```

## Troubleshooting

### Los DNS no se generan

1. Verifica que `.env` existe y contiene `DNS_LIST` o `DNS_LIST_*`:
   ```bash
   cat .env | grep -E '^DNS_LIST'
   ```

2. Verifica que el contenedor puede leer `.env`:
   ```bash
   docker compose exec haproxy cat /usr/local/etc/haproxy/.env
   ```

3. Revisa los logs:
   ```bash
   docker compose logs haproxy
   ```

### Configuraciones no se actualizan

1. Reinicia el contenedor después de cambiar `.env`:
   ```bash
   docker compose restart haproxy
   ```

2. Verifica que los archivos se generaron:
   ```bash
   ls -la dns-configs/
   ```

### Error en validación de HAProxy

1. Verifica la sintaxis de los archivos generados:
   ```bash
   docker compose exec haproxy haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg
   ```

2. Revisa archivos específicos:
   ```bash
   docker compose exec haproxy haproxy -c -f /usr/local/etc/haproxy/dns.d/example_com.cfg
   ```

## Mejores Prácticas

1. **Usa templates**: Modifica el template en lugar de archivos generados
2. **Versiona .env.example**: Mantén un ejemplo actualizado
3. **Documenta configuraciones especiales**: Si modificas templates, documenta los cambios
4. **Backup de configuraciones**: Antes de cambios importantes, haz backup de `dns-configs/`
5. **Validación**: Siempre valida después de cambios con `haproxy -c`

## Sincronización Automática (Futuro)

El script `watch-dns-changes.sh` puede usarse para monitorear cambios automáticamente:

```bash
# Dentro del contenedor (requiere inotify-tools)
docker compose exec haproxy /usr/local/bin/watch-dns-changes.sh --watch
```

Actualmente, se requiere reiniciar el contenedor para aplicar cambios.
