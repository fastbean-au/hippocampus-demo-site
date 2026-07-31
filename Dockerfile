# Self-contained landing-page image: Caddy with the static site baked in. It carries no
# host-path or cross-repo dependencies, so it builds and runs anywhere. The showcase's front
# proxy reaches it over the shared network by service name (see docker-compose.yaml).
FROM caddy:2

COPY Caddyfile /etc/caddy/Caddyfile
COPY index.html /srv/site/index.html
COPY assets/ /srv/site/assets/
