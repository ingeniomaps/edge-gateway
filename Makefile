.PHONY: help build up down restart logs stats check config test clean
.PHONY: setup-ssl check-ssl generate-cert renew-cert reload setup

# Variables
COMPOSE = docker compose
SERVICE = haproxy

# ------------------------------------------------------------------------------
# Objetivo por defecto: listar comandos disponibles
# ------------------------------------------------------------------------------
help:
	@echo "Uso: make [objetivo]"
	@echo ""
	@echo "  build          Construir imagen Docker"
	@echo "  up             Arrancar (crea .env, setup-ssl si mkcert/letsencrypt)"
	@echo "  down           Parar servicios"
	@echo "  restart        Reiniciar haproxy"
	@echo "  logs           Ver logs (seguimiento)"
	@echo "  reload         Recargar config HAProxy (regenera dns.d, -sf)"
	@echo "  setup          build + up"
	@echo ""
	@echo "  setup-ssl      Comprobar/generar certs (mkcert o Let's Encrypt)"
	@echo "  check-ssl      Comprobar validez de certificados"
	@echo "  generate-cert  Generar cert Let's Encrypt (CERTBOT_DOMAIN opcional)"
	@echo "  renew-cert     Renovar Let's Encrypt"
	@echo ""
	@echo "  check          Validar haproxy.cfg (haproxy -c)"
	@echo "  config         Validar docker-compose.yml"
	@echo "  test           Prueba rápida HTTP/HTTPS a localhost"
	@echo "  stats          Recordatorio: URL y credenciales de /stats"
	@echo "  clean          down -v y eliminar imagen"

# ------------------------------------------------------------------------------
# Dependencia: .env (se crea desde env.example si no existe)
# ------------------------------------------------------------------------------
.env:
	@if [ ! -f .env ]; then \
		cp env.example .env; \
		echo "Created .env from env.example"; \
	fi

# ------------------------------------------------------------------------------
# Construcción y arranque
# ------------------------------------------------------------------------------
build:
	$(COMPOSE) build

# Arrancar: crea .env si falta; si SSL_CERT_TYPE=mkcert|letsencrypt, mkcert -install
# y make setup-ssl. Luego docker compose up -d.
up: .env
	@mkdir -p certs
	@SSL_CERT_TYPE=$$(grep -E '^SSL_CERT_TYPE=' .env 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs); \
	if [ "$$SSL_CERT_TYPE" = "mkcert" ] && command -v mkcert >/dev/null 2>&1; then \
		mkcert -install 2>/dev/null || echo "Tip: mkcert -install si el cert no se ve seguro"; \
	fi; \
	if [ -n "$$SSL_CERT_TYPE" ] && { [ "$$SSL_CERT_TYPE" = "mkcert" ] || [ "$$SSL_CERT_TYPE" = "letsencrypt" ]; }; then \
		$(MAKE) setup-ssl; \
	fi
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) restart $(SERVICE)

logs:
	$(COMPOSE) logs -f $(SERVICE)

# ------------------------------------------------------------------------------
# SSL
# ------------------------------------------------------------------------------
setup-ssl:
	@mkdir -p certs certs/conf
	@bash scripts/setup-ssl-auto.sh

check-ssl:
	@bash scripts/check-ssl.sh

generate-cert:
	@bash scripts/certbot.sh generate "$${CERTBOT_DOMAIN:-}"

renew-cert:
	@bash scripts/certbot.sh renew

# ------------------------------------------------------------------------------
# Validación y pruebas
# ------------------------------------------------------------------------------
check:
	$(COMPOSE) exec $(SERVICE) haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg

config:
	$(COMPOSE) config

stats:
	@echo "Accede a http://localhost:8404/stats"
	@echo "Usuario: admin"
	@echo "Contraseña: changeme (cámbiala en haproxy.cfg)"

test:
	@echo "Testing HTTP redirect..."
	@curl -sI http://localhost 2>/dev/null | head -1
	@echo "Testing HTTPS..."
	@curl -skI https://localhost 2>/dev/null | head -1

# ------------------------------------------------------------------------------
# Recargar HAProxy: regenera dns.d, reconstruye haproxy.cfg y aplica (-sf).
# Con HAProxy como PID 1, -sf puede terminar el contenedor; restart lo levanta.
# ------------------------------------------------------------------------------
reload:
	$(COMPOSE) exec $(SERVICE) /usr/local/bin/reload-config.sh

# ------------------------------------------------------------------------------
# Limpieza: parar, eliminar volúmenes e imagen
# ------------------------------------------------------------------------------
clean:
	$(COMPOSE) down -v
	-docker rmi haproxy-lb:latest edge-gateway-haproxy 2>/dev/null

# ------------------------------------------------------------------------------
# Setup completo: build + up
# ------------------------------------------------------------------------------
setup: build up
	@echo "HAProxy está corriendo!"
	@echo "Accede a las estadísticas en http://localhost:8404/stats"
