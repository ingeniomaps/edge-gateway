# Producción - edge-gateway

## ¿Está 100% listo para producción?

**Casi.** La base (HAProxy, TLS, DNS dinámicos, SSL automático) está preparada, pero **hay que aplicar** los puntos del checklist. Sin ellos, no se considera listo para producción.

---

## Checklist antes de producción

### Obligatorios

- [ ] **Stats:** Cambiar `stats auth admin:changeme` en `haproxy.cfg` por una contraseña segura.
- [ ] **Stats:** Restringir por IP: descomentar en `haproxy.cfg` (frontend stats) las líneas de `acl allowed_ips` y `http-request deny unless allowed_ips` y ajustar las redes.
- [ ] **SSL:** En producción usar **Let's Encrypt** (`SSL_CERT_TYPE=letsencrypt`, `CERTBOT_EMAIL`, `CERTBOT_DOMAIN`/`DNS_LIST`). Programar `make renew-cert` en cron (p. ej. `0 3 * * *`).
- [ ] **Backends por DNS:** Los `backend_<dns>` se generan desde `templates/dns-backend.tmpl` o `DNS_TEMPLATE_<key>` (p. ej. `dns-backend-api.tmpl`). Sustituir por **servidores reales** (IP:puerto) en el template; los `dns-configs/*.cfg` se regeneran, no los edites.
- [ ] **DNS_LIST / DNS_LIST_* y DNS real:** Todos los `Host` que quieras servir deben estar en `DNS_LIST` o `DNS_LIST_*` y los dominios deben apuntar a la IP del servidor.

### Recomendados

- [ ] **Logs:** En producción, enviar logs a un agente (Fluentd, Promtail, etc.) o volumen persistente; el base usa `./logs` y stdout.
- [ ] **Recursos:** Ajustar `deploy.resources` en `docker-compose.yml` o `compose.production.yml` según carga.
- [ ] **Red:** Si el backend está en otra red Docker o en la host, revisar `networks` y que HAProxy pueda resolver y alcanzar las IP de los `server` en los backends.

---

## Sobre lo que se veía en Stats (3 api, 2 web, etc.)

Eran **backends de plantilla** con IPs de ejemplo (`192.168.1.10`, `192.168.1.20`, …) que no se usan en este proyecto:

- **api_backend:** 3 servidores (api1, api2, api3) en `192.168.1.10–12:8080`
- **web_backend:** 2 servidores (web1, web2) en `192.168.1.20–21:80`
- **http_backend:** los mismos 2 “web” por si se desactivaba la redirección 80→443
- **static_backend:** 1 servidor en `192.168.1.30:80`

En este proyecto **solo se usa el tráfico que entra por los DNS de `DNS_LIST`**. Esos backends de plantilla no reciben tráfico real y solo generaban ruido en Stats (servidores DOWN).

**Ahora:** Se han eliminado. En Stats solo verás:

- Los **backend_<dns>** inyectados desde `dns.d/*.cfg` (uno por cada DNS en `DNS_LIST` y `DNS_LIST_*`) con sus servidores reales.
- **unknown_host:** backend sin servidores para `Host` que no coincide con ningún DNS → responde 503.

---

## Cómo desplegar en producción

1. Aplicar el checklist anterior.
2. Usar overrides de producción:
   ```bash
   docker compose -f docker-compose.yml -f compose.production.yml up -d
   ```
   `compose.production.yml` solo ajusta `restart`, `deploy.resources`, `logging` y `labels`. **No cambia** `.env`, `dns-configs`, `certs` ni `logs`; siguen como en el `docker-compose.yml` base.
3. Si los certificados están en `/etc/ssl/haproxy` en el servidor, crea un override propio que monte, por ejemplo, `/etc/ssl/haproxy:/etc/ssl/certs:ro` sobre el volumen `certs` del servicio `haproxy`.

---

## Renovación Let's Encrypt en producción

Ejemplo de cron (diario a las 3:00):

```cron
0 3 * * * cd /ruta/edge-gateway && make renew-cert
```

O una tarea programada que ejecute `make renew-cert` (o `scripts/certbot.sh renew`) con la misma idea.

---

## Errores típicos

| Problema | Causa |
|----------|--------|
| 503 en el dominio | El `backend_<dns>` no tiene servidores válidos o el health check falla. Revisar el template asignado (`dns-backend.tmpl`, `dns-backend-api.tmpl`, etc.) y que las IP:puerto existan; si se usa `httpchk`, el backend debe responder `/health`. |
| Certificado no renovado | No hay cron/tarea para `make renew-cert` o `CERTBOT_EMAIL`/`CERTBOT_DOMAIN` mal configurados. |
| Stats accesible desde Internet | Hay que restringir por IP en el frontend `stats` (ver checklist). |
