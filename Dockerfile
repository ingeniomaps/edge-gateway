FROM haproxy:3.3-alpine

# sed ya en Alpine. openssl no se instala en imagen (fallos en algunos entornos).
# Para self-signed: use make setup-ssl (mkcert) o monte certs/haproxy.pem.

# OCI Labels for container metadata
LABEL org.opencontainers.image.title="Edge Gateway - HAProxy Load Balancer"
LABEL org.opencontainers.image.description="HAProxy 3.3 load balancer configured for production with HTTP/HTTPS support, dynamic DNS configuration, SSL/TLS termination, health checks, statistics, and security best practices. Features include SNI auto, rate limiting, modern security headers, and configurable templates."
LABEL org.opencontainers.image.url="https://github.com/ingeniomaps/edge-gateway"
LABEL org.opencontainers.image.source="https://github.com/ingeniomaps/edge-gateway"
LABEL org.opencontainers.image.version="3.3"
LABEL org.opencontainers.image.vendor="IngenioMaps"
LABEL org.opencontainers.image.licenses="MIT"

# Switch to root to create directories and copy files
USER root

# Install mkcert and certbot for automatic cert generation (SSL_CERT_TYPE=mkcert|letsencrypt)
RUN apk add --no-cache \
    --repository https://dl-cdn.alpinelinux.org/alpine/edge/testing mkcert \
    certbot

# Create necessary directories
RUN mkdir -p /usr/local/etc/haproxy/dns.d \
    /usr/local/etc/haproxy/templates \
    /usr/local/etc/haproxy/errors

# Copy configuration
COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg

# Copy scripts with executable permissions
COPY --chmod=755 scripts/generate-dns-config.sh /usr/local/bin/generate-dns-config.sh
COPY --chmod=755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=755 scripts/watch-dns-changes.sh /usr/local/bin/watch-dns-changes.sh
COPY --chmod=755 scripts/ensure-ssl.sh /usr/local/bin/ensure-ssl.sh
COPY --chmod=755 scripts/renew-ssl.sh /usr/local/bin/renew-ssl.sh
COPY --chmod=755 scripts/reload-config.sh /usr/local/bin/reload-config.sh

# Copy templates (todos los .tmpl; en desarrollo se suele montar ./templates por volumen)
COPY templates/ /usr/local/etc/haproxy/templates/

# Note: Certificate generation moved to entrypoint script
# This allows using mounted certificates in production without rebuilding

# Expose ports
EXPOSE 80 443 8404

# Health check
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg || exit 1

# Use entrypoint script
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Run HAProxy
CMD ["haproxy", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]
