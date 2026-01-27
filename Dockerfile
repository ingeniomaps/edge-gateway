FROM haproxy:3.3-alpine

# sed ya en Alpine. openssl no se instala en imagen (fallos en algunos entornos).
# Para self-signed: use make setup-ssl (mkcert) o monte certs/haproxy.pem.

# Switch to root to create directories and copy files
USER root

# Create necessary directories
RUN mkdir -p /usr/local/etc/haproxy/dns.d \
    /usr/local/etc/haproxy/templates

# Copy configuration
COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg

# Copy scripts with executable permissions
COPY --chmod=755 scripts/generate-dns-config.sh /usr/local/bin/generate-dns-config.sh
COPY --chmod=755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=755 scripts/watch-dns-changes.sh /usr/local/bin/watch-dns-changes.sh
COPY --chmod=755 scripts/ensure-ssl.sh /usr/local/bin/ensure-ssl.sh
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
